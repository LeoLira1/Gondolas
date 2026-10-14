import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'baixa_por_contagem.dart';
import 'codigos_vinculados.dart';
import 'estoque_localizado_service.dart';
import 'galpao_saldo.dart' show mestrePorCodigo;
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
  /// e o galpão é reaberto dezenas de vezes num turno. A baixa é idempotente
  /// por contagem, então repetir a passada pouco depois nunca acha nada de
  /// novo: só uma contagem NOVA muda o resultado. Meia hora é o atraso que o
  /// Leo aceitou entre a contagem confirmada e o rack baixar (era 10 min);
  /// religar o interruptor em ⚙️ zera a janela.
  static const Duration intervaloMinimoAutomatica = Duration(minutes: 30);

  DateTime? _ultimaAutomaticaEm;

  /// Onde a hora da última passada automática fica guardada, por banco. Só
  /// em memória, cada vez que o Android matava o app a janela zerava e a
  /// abertura seguinte relia tudo de novo.
  static String chaveUltimaPassada(String banco) =>
      'baixa_automatica_ultima_$banco';

  String? get _chaveUltimaPassada {
    final banco = TursoService().identidadeAtiva;
    return banco == null ? null : chaveUltimaPassada(banco);
  }

  Future<DateTime?> _ultimaPassadaGravada() async {
    final chave = _chaveUltimaPassada;
    if (chave == null) return null;
    try {
      final texto = (await SharedPreferences.getInstance()).getString(chave);
      return texto == null ? null : DateTime.tryParse(texto);
    } catch (_) {
      return null;
    }
  }

  Future<void> _gravarUltimaPassada(DateTime? quando) async {
    final chave = _chaveUltimaPassada;
    if (chave == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (quando == null) {
        await prefs.remove(chave);
      } else {
        await prefs.setString(chave, quando.toIso8601String());
      }
    } catch (_) {
      // Sem a marca, a próxima abertura só roda a passada de novo.
    }
  }

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
    final gravada = _ultimaAutomaticaEm ?? await _ultimaPassadaGravada();
    // A memória de novo depois do await: outra tela pode ter começado uma
    // passada enquanto o disco era lido.
    final ultima = _ultimaAutomaticaEm ?? gravada;
    if (ultima != null &&
        DateTime.now().difference(ultima) < intervaloMinimoAutomatica) {
      return ultimoResumo.value ?? ResumoBaixa.vazio;
    }
    final agora = DateTime.now();
    _ultimaAutomaticaEm = agora;
    unawaited(_gravarUltimaPassada(agora));
    return executar();
  }

  /// Esquece a última passada automática, para a próxima chamada de
  /// [rodarSeAutomatica] ler o banco de novo. É o que o interruptor da
  /// configuração usa ao ser religado: pedido explícito não espera a janela
  /// de quem não pediu nada.
  void esquecerJanela() {
    _ultimaAutomaticaEm = null;
    unawaited(_gravarUltimaPassada(null));
  }

  /// Uma passada completa: planeja e (se [aplicar]) grava.
  ///
  /// Com `aplicar: false` nada é escrito — é a prévia, usada pelo botão
  /// "conferir antes" e pelo desenvolvimento.
  ///
  /// A passada automática tem duas fases. A primeira planeja com as cópias
  /// que o app já guarda (quantidades, saldos, vínculos e contagens, cada uma
  /// relida só se passou da própria janela) e as divergências frescas. No
  /// caso comum — toda contagem já baixada —, nenhum plano sai aplicável e a
  /// passada termina aí, sem reler o estoque_localizado, o estoque_mestre e o
  /// mapa inteiros. Só quando há o que gravar a segunda fase relê tudo fresco
  /// e planeja do zero: a gravação nunca se baseia na cópia.
  Future<ResumoBaixa> executar({bool aplicar = true}) async {
    if (_rodando) return ResumoBaixa.vazio;
    _rodando = true;
    try {
      _Insumos? daCopia;
      if (aplicar) {
        daCopia = await _insumosDasCopias();
        if (daCopia != null) {
          final planos = _montarPlanos(daCopia);
          if (!planos.any((p) => p.aplicavel)) {
            final resumo = planos.isEmpty
                ? ResumoBaixa.vazio
                : ResumoBaixa(ignorados: planos);
            ultimoResumo.value = resumo;
            return resumo;
          }
        }
      }

      final planos = await planejar(reaproveitar: daCopia);
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
      final tocados = [...aplicados, ...falhados];
      // A cópia do galpão não sabe das gravações da baixa (a fila corrige só
      // a das quantidades): sem reler, o rack esvaziado continuava na tela.
      if (tocados.any(
        (p) => p.ajustes.any((a) => a.endereco.localTipo == localTipoGalpao),
      )) {
        await GalpaoService().recarregarPilhas();
      }
      // Um aviso só, no fim, e só quando algo foi gravado — inclusive num
      // plano que falhou no meio. As gravações saem com o aviso desligado:
      // um dataRevision por endereço recarregava cada tela aberta N vezes.
      if (tocados.isNotEmpty) TursoService().dataRevision.value++;
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

  /// Monta o plano de cada produto que tem endereço, sem gravar nada, com
  /// leitura FRESCA do que a gravação usa: os endereços (com o rack_uuid), o
  /// estoque_mestre e o mapa de produtos. As divergências e as contagens de
  /// [reaproveitar] (a fase das cópias da mesma passada) são usadas como
  /// vieram — contagem um pouco mais velha só deixa a baixa mais
  /// conservadora (mais endereços "mexidos depois da contagem").
  Future<List<PlanoBaixa>> planejar({_Insumos? reaproveitar}) async {
    final client = await _conexao();
    if (client == null) return const [];

    try {
      final enderecos = await _lerEnderecos(client);
      if (enderecos.isEmpty) return const [];

      // Leitura fresca de propósito (a baixa GRAVA com base nela), mas pela
      // cópia compartilhada: o galpão aberto logo depois usa estas mesmas
      // linhas para o saldo em vez de reler a tabela.
      final mestre = mestrePorCodigo(
        await TursoService().consultarSaldos(forceRefresh: true),
      );
      return _montarPlanos(
        _Insumos(
          enderecos: enderecos,
          mestre: mestre,
          // Falha fechada: sem um vínculo que existe, o código secundário
          // seria planejado sozinho, com alvo no próprio qtd_sistema, e os
          // endereços dele esvaziados.
          vinculos: await TursoService().vinculosDoMapa(
            forceRefresh: true,
            falharFechado: true,
          ),
          divergencias:
              reaproveitar?.divergencias ?? await _lerDivergencias(client),
          contagens:
              reaproveitar?.contagens ?? await _lerContagens(forcar: true),
        ),
      );
    } catch (_) {
      return const [];
    }
  }

  /// Os insumos da fase das cópias, ou null quando falta alguma cópia (e a
  /// rede para buscá-la) — aí a passada vai direto à leitura fresca.
  Future<_Insumos?> _insumosDasCopias() async {
    final client = await _conexao();
    if (client == null) return null;
    try {
      final turso = TursoService();
      final linhas = await turso.consultarQuantidades(
        falharSemCache: true,
        atualizarSeVencida: true,
      );
      final enderecos = <String, List<EnderecoLocalizado>>{};
      for (final r in linhas) {
        final bruto = r['produto_codigo'] as String? ?? '';
        final codigo = normalizarCodigo(bruto);
        if (codigo == null) continue;
        enderecos.putIfAbsent(codigo, () => []).add(_enderecoDaLinha(r));
      }
      return _Insumos(
        enderecos: enderecos,
        mestre: mestrePorCodigo(
          await turso.consultarSaldos(atualizarSeVencida: true),
        ),
        vinculos: await turso.vinculosDoMapa(atualizarSeVencida: true),
        // Fresca e pequena (só as abertas): é ela que transforma uma falta
        // em excesso, e um valor velho faria a baixa tirar o que não devia.
        divergencias: await _lerDivergencias(client),
        contagens: await _lerContagens(),
      );
    } catch (_) {
      return null;
    }
  }

  /// O plano de cada produto (grupo de códigos irmãos) que tem endereço.
  List<PlanoBaixa> _montarPlanos(_Insumos insumos) {
    final enderecos = insumos.enderecos;
    if (enderecos.isEmpty) return const [];
    final mestre = insumos.mestre;
    final divergencias = insumos.divergencias;
    final contagens = insumos.contagens;
    final grupos = gruposDeCodigos(
      codigos: enderecos.keys,
      produtoIdPorCodigo: insumos.vinculos,
      nomePorCodigo: {for (final e in mestre.entries) e.key: e.value.nome},
    );

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
  }

  static EnderecoLocalizado _enderecoDaLinha(
    Map<String, dynamic> r, {
    String? rackUuid,
  }) => EnderecoLocalizado(
    rackUuid: rackUuid,
    id: r['id'] as int?,
    produtoCodigo: r['produto_codigo'] as String? ?? '',
    localTipo: r['local_tipo'] as String? ?? 'gondola',
    localNum: r['local_num'] as int? ?? 0,
    faceOuColuna: r['face_ou_coluna'] as int? ?? 0,
    andarOuNivel: r['andar_ou_nivel'] as int? ?? 0,
    quantidade: (r['quantidade'] as num?)?.toDouble() ?? 0,
    atualizadoEm: r['atualizado_em'] as String?,
  );

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
          .add(_enderecoDaLinha(r, rackUuid: r['rack_uuid'] as String?));
    }
    return porCodigo;
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
    } catch (e) {
      // Banco sem a tabela de divergências: o alvo vira o qtd_sistema puro,
      // que é o comportamento correto quando não há divergência nenhuma.
      if (TursoService.erroDeTabelaAusente(e)) return const {};
      // Qualquer outra falha (rede) aborta a passada: "sem divergência" por
      // engano deixa o alvo errado, e a baixa tiraria dos racks o que um
      // cooperado já explicava.
      rethrow;
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
  /// Vem da cópia compartilhada com o selo âmbar das prateleiras
  /// ([TursoService.consultarUltimasContagensItens]): uma varredura de
  /// contagem_itens para os dois, relida só quando passou da janela — ou na
  /// hora, com [forcar]. A coluna de confirmação (`confirmado_em` ou, sem
  /// ela, `registrado_em`) é descoberta e lembrada lá.
  Future<Map<String, DateTime>> _lerContagens({bool forcar = false}) async {
    final rows = await TursoService().consultarUltimasContagensItens(
      forceRefresh: forcar,
      atualizarSeVencida: true,
    );
    final por = <String, DateTime>{};
    for (final r in rows) {
      final bruto = r['produto_codigo'];
      final texto = r['ultima'];
      if (bruto is! String || texto is! String) continue;
      final codigo = normalizarCodigo(bruto);
      if (codigo == null) continue;
      final dt = _parseData(texto);
      if (dt != null) por[codigo] = dt;
    }
    return por;
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
            )
          : await GalpaoService().ajustarQuantidade(
              rackUuid: a.endereco.rackUuid,
              posicao: a.endereco.localNum,
              ordem: a.endereco.andarOuNivel,
              quantidade: a.qtdNova,
              origem: origemLog,
            );
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
        // Um aviso só, no fim da passada (ver executar).
        avisar: false,
      );
      if (!ok) return false;
    }
    return true;
  }
}

/// O que uma passada precisa para planejar.
class _Insumos {
  final Map<String, List<EnderecoLocalizado>> enderecos;
  final Map<String, ({String nome, double qtdSistema})> mestre;
  final Map<String, String> vinculos;
  final Map<String, double> divergencias;
  final Map<String, DateTime> contagens;

  const _Insumos({
    required this.enderecos,
    required this.mestre,
    required this.vinculos,
    required this.divergencias,
    required this.contagens,
  });
}
