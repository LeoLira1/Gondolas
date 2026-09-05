import 'package:flutter/foundation.dart';
import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'baixa_por_contagem.dart';
import 'codigos_vinculados.dart';
import 'estoque_localizado_service.dart';
import 'galpao_service.dart';
import 'models.dart' show localTipoGalpao;
import 'turso_service.dart';

/// Lê o banco, monta a baixa de cada produto ([planejarBaixa]) e grava.
///
/// A REGRA está toda em baixa_por_contagem.dart, de propósito: aqui só vive o
/// SQL e a ordem das gravações, que é o que não dá para testar sem banco.
///
/// São cinco leituras, todas agregadas ou pequenas, uma vez por passada: os
/// endereços, o estoque_mestre (nome e qtd_sistema), o vínculo de códigos do
/// mapa, as divergências abertas e a última contagem confirmada de cada
/// produto. Nenhuma roda durante o paint.
class BaixaPorContagemService {
  static final BaixaPorContagemService _instance =
      BaixaPorContagemService._internal();
  factory BaixaPorContagemService() => _instance;
  BaixaPorContagemService._internal();

  /// Preferência do usuário: a baixa roda sozinha ao abrir o app e ao abrir o
  /// galpão. Ligada por padrão — o ponto do recurso é justamente não ter de
  /// pedir.
  static const String keyBaixaAutomatica = 'baixa_automatica_contagem';
  static const bool padraoBaixaAutomatica = true;

  /// Origem gravada em contagens_log. É por ela que se acha, depois, tudo o
  /// que o automático mexeu — e é o que torna a baixa auditável em vez de
  /// mágica.
  static const String origemLog = 'gondolas_app_baixa_contagem';

  /// O resultado da última passada, para as telas mostrarem sem consultar
  /// nada. Null enquanto a baixa nunca rodou nesta sessão.
  final ValueNotifier<ResumoBaixa?> ultimoResumo = ValueNotifier<ResumoBaixa?>(
    null,
  );

  /// Intervalo mínimo entre duas passadas AUTOMÁTICAS.
  ///
  /// A abertura do app e a abertura do galpão chamam a baixa cada uma por si,
  /// e o galpão é reaberto dezenas de vezes num turno. Cada passada lê o
  /// estoque_localizado inteiro, o catálogo e as duas tabelas do mapa — e a
  /// baixa é idempotente por contagem, então repetir tudo isso um minuto
  /// depois nunca acha nada de novo. Só uma contagem NOVA muda o resultado, e
  /// contagem não é confirmada de dez em dez segundos.
  static const Duration intervaloMinimoAutomatica = Duration(minutes: 10);

  DateTime? _ultimaAutomaticaEm;

  bool _rodando = false;

  /// True enquanto uma passada está em andamento — as telas chamam de mais de
  /// um lugar (abertura do app e abertura do galpão) e duas passadas
  /// simultâneas disputariam os mesmos racks.
  bool get rodando => _rodando;

  static Future<bool> lerAutomatica() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyBaixaAutomatica) ?? padraoBaixaAutomatica;
  }

  static Future<void> salvarAutomatica(bool ligada) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyBaixaAutomatica, ligada);
  }

  Future<LibsqlClient?> _conexao() async {
    if (!await TursoService().garantirConexao()) return null;
    return TursoService().client;
  }

  /// Roda a baixa automática, se ela estiver ligada nas preferências e se a
  /// última passada não foi agora há pouco. É o ponto de entrada das telas:
  /// não decide nada além de respeitar o interruptor e o
  /// [intervaloMinimoAutomatica].
  ///
  /// Dentro da janela devolve o resumo da última passada em vez de vazio: o
  /// que ela baixou continua sendo a explicação do mapa que o usuário está
  /// abrindo agora.
  Future<ResumoBaixa> rodarSeAutomatica() async {
    if (!await lerAutomatica()) return ResumoBaixa.vazio;
    final ultima = _ultimaAutomaticaEm;
    if (ultima != null &&
        DateTime.now().difference(ultima) < intervaloMinimoAutomatica) {
      return ultimoResumo.value ?? ResumoBaixa.vazio;
    }
    _ultimaAutomaticaEm = DateTime.now();
    return executar();
  }

  /// Esquece a última passada automática, para a próxima chamada de
  /// [rodarSeAutomatica] ler o banco de novo. É o que o interruptor da
  /// configuração usa ao ser religado: pedido explícito não espera a janela
  /// de quem não pediu nada.
  void esquecerJanela() => _ultimaAutomaticaEm = null;

  /// Uma passada completa: planeja e (se [aplicar]) grava.
  ///
  /// Com `aplicar: false` nada é escrito — é a prévia, usada pelo botão
  /// "conferir antes" e pelo desenvolvimento.
  Future<ResumoBaixa> executar({bool aplicar = true}) async {
    if (_rodando) return ResumoBaixa.vazio;
    _rodando = true;
    try {
      final planos = await planejar();
      if (planos.isEmpty) {
        final resumo = ResumoBaixa.vazio;
        ultimoResumo.value = resumo;
        return resumo;
      }

      final aplicaveis = planos.where((p) => p.aplicavel).toList();
      final ignorados = planos.where((p) => !p.aplicavel).toList();

      if (!aplicar) {
        final resumo = ResumoBaixa(
          aplicados: const [],
          ignorados: [...ignorados, ...aplicaveis],
        );
        ultimoResumo.value = resumo;
        return resumo;
      }

      final aplicados = <PlanoBaixa>[];
      final falhados = <PlanoBaixa>[];
      for (final plano in aplicaveis) {
        if (await _aplicar(plano)) {
          aplicados.add(plano);
        } else {
          falhados.add(plano);
        }
      }

      final resumo = ResumoBaixa(
        aplicados: aplicados,
        falhados: falhados,
        ignorados: ignorados,
      );
      ultimoResumo.value = resumo;
      // Só avisa as outras telas quando algo mudou de verdade: um
      // dataRevision a cada abertura de mapa recarregaria o app inteiro sem
      // motivo.
      if (aplicados.isNotEmpty) TursoService().dataRevision.value++;
      return resumo;
    } catch (_) {
      return ResumoBaixa.vazio;
    } finally {
      _rodando = false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Leitura
  // ───────────────────────────────────────────────────────────────────────────

  /// Monta o plano de cada produto que tem endereço, sem gravar nada.
  Future<List<PlanoBaixa>> planejar() async {
    final client = await _conexao();
    if (client == null) return const [];

    try {
      final enderecos = await _lerEnderecos(client);
      if (enderecos.isEmpty) return const [];

      final mestre = await _lerMestre(client);
      final grupos = gruposDeCodigos(
        codigos: enderecos.keys,
        produtoIdPorCodigo: await _lerVinculosDoMapa(client),
        nomePorCodigo: {for (final e in mestre.entries) e.key: e.value.nome},
      );
      final divergencias = await _lerDivergencias(client);
      final contagens = await _lerContagens(client);

      final planos = <PlanoBaixa>[];
      final gruposVistos = <String>{};
      for (final codigo in enderecos.keys) {
        final grupo = (grupos[codigo] ?? {codigo}).toList()..sort();
        // Um produto, um plano: o irmão do grupo já foi planejado junto com
        // ele, e planejar de novo baixaria a mesma venda duas vezes.
        if (!gruposVistos.add(grupo.join('|'))) continue;

        // Produto fora do estoque_mestre não tem qtd_sistema, e sem ela não
        // existe alvo — chutar zero esvaziaria o rack de tudo que ainda não
        // foi cadastrado.
        if (!grupo.any(mestre.containsKey)) continue;

        var qtdSistema = 0.0, delta = 0.0;
        DateTime? confirmada;
        final doGrupo = <EnderecoLocalizado>[];
        var nome = '';
        for (final c in grupo) {
          qtdSistema += mestre[c]?.qtdSistema ?? 0;
          delta += divergencias[c] ?? 0;
          doGrupo.addAll(enderecos[c] ?? const []);
          if (nome.isEmpty) nome = mestre[c]?.nome ?? '';
          final dt = contagens[c];
          if (dt != null && (confirmada == null || dt.isAfter(confirmada))) {
            confirmada = dt;
          }
        }

        planos.add(
          planejarBaixa(
            contagem: ContagemDoProduto(
              codigos: grupo,
              nome: nome,
              qtdSistema: qtdSistema,
              deltaDivergencias: delta,
              confirmadaEm: confirmada,
            ),
            enderecos: doGrupo,
          ),
        );
      }
      return planos;
    } catch (_) {
      return const [];
    }
  }

  /// Todos os endereços gravados, indexados pelo código NORMALIZADO — é por
  /// ele que o grupo de códigos irmãos cruza. O código original fica dentro
  /// do [EnderecoLocalizado], porque é ele que volta para o UPDATE.
  Future<Map<String, List<EnderecoLocalizado>>> _lerEnderecos(
    LibsqlClient client,
  ) async {
    final stmt = await client.prepare(
      'SELECT e.*, r.rack_uuid FROM estoque_localizado e '
      'LEFT JOIN galpao_racks r ON e.local_tipo = \'galpao\' '
      'AND r.posicao = e.local_num AND r.ordem = e.andar_ou_nivel '
      'AND r.produto_codigo = e.produto_codigo',
    );
    final rows = await stmt.query() as List<dynamic>;
    final porCodigo = <String, List<EnderecoLocalizado>>{};
    for (final dynamic row in rows) {
      final r = row as Map<String, dynamic>;
      final bruto = r['produto_codigo'] as String? ?? '';
      final codigo = normalizarCodigo(bruto);
      if (codigo == null) continue;
      porCodigo
          .putIfAbsent(codigo, () => <EnderecoLocalizado>[])
          .add(
            EnderecoLocalizado(
              rackUuid: r['rack_uuid'] as String?,
              id: r['id'] as int?,
              produtoCodigo: bruto,
              localTipo: r['local_tipo'] as String? ?? 'gondola',
              localNum: r['local_num'] as int? ?? 0,
              faceOuColuna: r['face_ou_coluna'] as int? ?? 0,
              andarOuNivel: r['andar_ou_nivel'] as int? ?? 0,
              quantidade: (r['quantidade'] as num?)?.toDouble() ?? 0,
              atualizadoEm: r['atualizado_em'] as String?,
            ),
          );
    }
    return porCodigo;
  }

  /// Nome e qtd_sistema por código. A tabela inteira, com o mesmo teto do
  /// catálogo: o irmão de um código fora do mapa só é achável pelo NOME (ver
  /// codigos_vinculados.dart).
  Future<Map<String, ({String nome, double qtdSistema})>> _lerMestre(
    LibsqlClient client,
  ) async {
    final stmt = await client.prepare(
      'SELECT codigo, produto, qtd_sistema FROM estoque_mestre LIMIT 5000',
    );
    final rows = await stmt.query() as List<dynamic>;
    final mestre = <String, ({String nome, double qtdSistema})>{};
    for (final dynamic row in rows) {
      final r = row as Map<String, dynamic>;
      final codigo = normalizarCodigo(r['codigo'] as String?);
      if (codigo == null) continue;
      mestre[codigo] = (
        nome: r['produto'] as String? ?? '',
        qtdSistema: (r['qtd_sistema'] as num?)?.toDouble() ?? 0,
      );
    }
    return mestre;
  }

  /// Código → produto_id do mapa de produtos. As tabelas são do dashboard e
  /// podem não existir; sem elas resta o nome.
  Future<Map<String, String>> _lerVinculosDoMapa(LibsqlClient client) async {
    final vinculos = <String, String>{};
    for (final tabela in const ['mapa_produtos', 'mapa_produtos_codigos']) {
      try {
        final stmt = await client.prepare(
          'SELECT produto_id, codigo FROM $tabela WHERE codigo IS NOT NULL',
        );
        final rows = await stmt.query() as List<dynamic>;
        for (final dynamic row in rows) {
          final r = row as Map<String, dynamic>;
          final codigo = normalizarCodigo(r['codigo'] as String?);
          final produtoId = (r['produto_id']?.toString() ?? '').trim();
          if (codigo == null || produtoId.isEmpty) continue;
          vinculos[codigo] = produtoId;
        }
      } catch (_) {
        // Tabela ausente: segue sem ela.
      }
    }
    return vinculos;
  }

  /// Soma dos deltas das divergências ABERTAS, por código.
  ///
  /// É a ponte com o app de divergências (`LeoLira1/Planilha-`): o que está
  /// lançado para um cooperado não é venda, e sem esta soma a baixa tiraria
  /// dos racks uma quantidade que o inventário já explicou de outro jeito.
  /// Divergência resolvida some da tabela, e o alvo volta ao qtd_sistema
  /// sozinho — nenhum estado a manter dos dois lados.
  Future<Map<String, double>> _lerDivergencias(LibsqlClient client) async {
    try {
      final stmt = await client.prepare(
        'SELECT codigo, SUM(delta) AS total FROM divergencias GROUP BY codigo',
      );
      final rows = await stmt.query() as List<dynamic>;
      final por = <String, double>{};
      for (final dynamic row in rows) {
        final r = row as Map<String, dynamic>;
        final codigo = normalizarCodigo(r['codigo'] as String?);
        if (codigo == null) continue;
        por[codigo] = (r['total'] as num?)?.toDouble() ?? 0;
      }
      return por;
    } catch (_) {
      // Banco sem a tabela de divergências: o alvo vira o qtd_sistema puro,
      // que é o comportamento correto quando não há divergência nenhuma.
      return const {};
    }
  }

  /// Última contagem CONFIRMADA de cada produto, em `contagem_itens` — a
  /// tabela que o app Contagem CAMDA grava quando alguém confere a pilha na
  /// frente da prateleira.
  ///
  /// `inventario_cicli` fica DE FORA, ao contrário do que
  /// [EstoqueLocalizadoService.fetchEnderecosDesatualizados] faz para o badge
  /// de endereço velho. O motivo é o sentido da conta: o cíclico é gravado
  /// por [EstoqueLocalizadoService.concluirContagem], que soma os PRÓPRIOS
  /// endereços — usá-lo aqui seria a baixa contradizer a pessoa que acabou de
  /// contar o rack na mão. Quem conta no app das gôndolas está afirmando que
  /// o endereço está certo e o sistema é que está atrasado; a baixa existe
  /// para o caso contrário, e só a contagem física de fora pode afirmá-lo.
  ///
  /// `confirmado_em` é coluna de migração do dashboard e pode não existir;
  /// nesse caso vale `registrado_em`, o mesmo fallback do resto do app.
  Future<Map<String, DateTime>> _lerContagens(LibsqlClient client) async {
    for (final coluna in const ['confirmado_em', 'registrado_em']) {
      try {
        final stmt = await client.prepare('''
          SELECT codigo AS produto_codigo, MAX($coluna) AS ultima
          FROM contagem_itens
          WHERE status != 'pendente' AND $coluna IS NOT NULL
          GROUP BY codigo
        ''');
        final rows = await stmt.query() as List<dynamic>;
        final por = <String, DateTime>{};
        for (final dynamic row in rows) {
          final r = row as Map<String, dynamic>;
          final codigo = normalizarCodigo(r['produto_codigo'] as String?);
          final texto = r['ultima'] as String?;
          if (codigo == null || texto == null) continue;
          final dt = _parseData(texto);
          if (dt != null) por[codigo] = dt;
        }
        return por;
      } catch (_) {
        // Coluna inexistente neste ambiente: tenta a próxima.
      }
    }
    return const {};
  }

  /// Data do banco em DateTime. O dashboard grava 'YYYY-MM-DD HH:MM:SS' (hora
  /// de Brasília) e o app grava ISO-8601 — [DateTime.tryParse] lê os dois,
  /// mas o ISO com sufixo Z volta em UTC e compararia três horas fora do
  /// lugar. Aqui tudo vira hora local do mesmo relógio.
  static DateTime? _parseData(String texto) {
    final dt = DateTime.tryParse(texto.trim());
    return dt == null ? null : (dt.isUtc ? dt.toLocal() : dt);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Gravação
  // ───────────────────────────────────────────────────────────────────────────

  /// Grava a baixa de um produto. Devolve false ao primeiro ajuste que
  /// falhar — os já gravados ficam (são reduções corretas, só incompletas), e
  /// o produto entra em [ResumoBaixa.falhados] para o usuário saber que
  /// aquele ficou pela metade.
  Future<bool> _aplicar(PlanoBaixa plano) async {
    // Galpão primeiro, na ordem que a renumeração da pilha exige — ver
    // [ordenarGravacaoGalpao], que é onde essa regra está explicada e travada
    // em teste.
    for (final a in ordenarGravacaoGalpao(plano.ajustes)) {
      if (a.endereco.rackUuid == null) return false;
      final ok = a.esvazia
          ? await GalpaoService().esvaziar(
                  rackUuid: a.endereco.rackUuid,
                  posicao: a.endereco.localNum,
                  ordem: a.endereco.andarOuNivel,
                  origem: origemLog,
                ) !=
                null
          : await GalpaoService().ajustarQuantidade(
                  rackUuid: a.endereco.rackUuid,
                  posicao: a.endereco.localNum,
                  ordem: a.endereco.andarOuNivel,
                  quantidade: a.qtdNova,
                  origem: origemLog,
                ) !=
                null;
      if (!ok) return false;
    }

    // Gôndola e estante: a linha fica, zerada. O produto continua morando
    // ali (é o planograma), e apagar o endereço faria a prateleira sumir do
    // mapa por ter vendido tudo.
    for (final a in plano.ajustes) {
      if (a.endereco.localTipo == localTipoGalpao) continue;
      final ok = await EstoqueLocalizadoService().upsertQuantidade(
        produtoCodigo: a.endereco.produtoCodigo,
        localTipo: a.endereco.localTipo,
        localNum: a.endereco.localNum,
        faceOuColuna: a.endereco.faceOuColuna,
        andarOuNivel: a.endereco.andarOuNivel,
        quantidade: a.qtdNova,
        origem: origemLog,
      );
      if (!ok) return false;
    }
    return true;
  }
}
