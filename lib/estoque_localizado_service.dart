import 'dart:async';

import 'package:libsql_dart/libsql_dart.dart';

import 'badges_estoque.dart';
import 'gravacao_lote.dart';
import 'models.dart';
import 'turso_service.dart';
import 'outbox.dart';
import 'replica_coordinator.dart';

/// Uma linha de estoque_localizado: quantidade de um produto num endereço
/// físico (gôndola, estante ou galpão).
class EnderecoLocalizado {
  final String? rackUuid;
  final int? id; // null enquanto não gravado em estoque_localizado
  final String produtoCodigo;
  final String localTipo; // 'gondola' | 'estante'
  final int localNum;
  final int faceOuColuna; // gôndola: face 1-6 | estante: coluna
  final int andarOuNivel; // gôndola: andar 0-2 | estante: nível
  final double quantidade;
  final String? atualizadoEm;

  const EnderecoLocalizado({
    this.rackUuid,
    this.id,
    required this.produtoCodigo,
    required this.localTipo,
    required this.localNum,
    required this.faceOuColuna,
    required this.andarOuNivel,
    required this.quantidade,
    this.atualizadoEm,
  });

  bool get ehGondola => localTipo == 'gondola';
  bool get ehGalpao => localTipo == localTipoGalpao;

  /// Código compacto usado no log e na observação do inventário cíclico,
  /// ex: 'G9·F3·A2' (gôndola), 'E3·H' (estante) ou 'GALPAO·52·N3'.
  ///
  /// No galpão o nível vai junto por ser um REGISTRO HISTÓRICO — o que estava
  /// naquele endereço no instante da contagem —, não uma referência a ser
  /// resolvida depois. Endereço do galpão que se pretende reabrir é sempre
  /// (posição, ordem) lido da tabela, nunca este texto: a ordem muda sozinha
  /// quando um rack abaixo sai.
  String get enderecoCompacto => ehGondola
      ? 'G$localNum·F$faceOuColuna·A${andarOuNivel + 1}'
      : ehGalpao
      ? 'GALPAO·$localNum·N$andarOuNivel'
      : 'E$localNum·${letraEstanteCelula(localNum, faceOuColuna, andarOuNivel)}';

  bool mesmoEndereco(EnderecoLocalizado o) =>
      localTipo == o.localTipo &&
      localNum == o.localNum &&
      faceOuColuna == o.faceOuColuna &&
      andarOuNivel == o.andarOuNivel;
}

/// Dados do estoque_mestre relevantes pra tela de contagem.
class InfoEstoqueMestre {
  final String produtoNome;
  final String categoria;
  final double qtdSistema;

  const InfoEstoqueMestre({
    required this.produtoNome,
    required this.categoria,
    required this.qtdSistema,
  });
}

/// Um endereço cujo atualizado_em é anterior à última contagem confirmada do
/// produto (inventário cíclico ou contagem diária do dashboard) — indica que
/// a distribuição gravada pode não refletir mais a realidade.
class EnderecoDesatualizado {
  final String produtoCodigo;
  final String localTipo;
  final int localNum;
  final int faceOuColuna;
  final int andarOuNivel;
  final String atualizadoEm; // do endereço em estoque_localizado
  final String ultimaContagemEm; // MAX(contado_em, confirmado_em) do produto

  const EnderecoDesatualizado({
    required this.produtoCodigo,
    required this.localTipo,
    required this.localNum,
    required this.faceOuColuna,
    required this.andarOuNivel,
    required this.atualizadoEm,
    required this.ultimaContagemEm,
  });

  String get chave => chaveEnderecoEstoque(
    produtoCodigo: produtoCodigo,
    localTipo: localTipo,
    localNum: localNum,
    faceOuColuna: faceOuColuna,
    andarOuNivel: andarOuNivel,
  );
}

/// Resultado de concluirContagem: o que foi sincronizado com o cíclico.
class ResultadoContagem {
  final double total;
  final double qtdSistema;
  final double divergencia;
  final String status; // 'ok' | 'divergencia'

  const ResultadoContagem({
    required this.total,
    required this.qtdSistema,
    required this.divergencia,
    required this.status,
  });
}

class EstoqueLocalizadoService {
  /// Chave LÓGICA de um endereço. É ela — e não o `id` autoincrementado, que
  /// diverge entre réplicas offline — que permite reler a mesma linha no
  /// remoto depois de uma reconstrução.
  static Map<String, Object?> chaveDoEndereco({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
    required int faceOuColuna,
    required int andarOuNivel,
  }) => {
    'produto_codigo': produtoCodigo,
    'local_tipo': localTipo,
    'local_num': localNum,
    'face_ou_coluna': faceOuColuna,
    'andar_ou_nivel': andarOuNivel,
  };

  static final EstoqueLocalizadoService _instance =
      EstoqueLocalizadoService._internal();
  factory EstoqueLocalizadoService() => _instance;
  EstoqueLocalizadoService._internal();

  Future<LibsqlClient?> _conexao() async {
    if (!await TursoService().garantirConexao()) return null;
    return TursoService().client;
  }

  // Selos calculados da última vez (ver fetchEnderecosDesatualizados e
  // fetchEnderecosDivergentes). Ficam em memória para o painter das cenas e o
  // diálogo consultarem sem ida ao banco.
  Map<String, EnderecoDesatualizado> _desatualizadosCache = {};
  Set<String> _divergentesCache = {};
  // Subconjunto de _divergentesCache cuja divergência é POSITIVA (quantidade
  // contada maior que a do sistema): as cenas pintam de azul escuro em vez de
  // vermelho.
  Set<String> _divergentesPositivasCache = {};

  /// Os endereços cujo atualizado_em é anterior à última contagem confirmada
  /// do produto (inventário cíclico ou app de contagem). Atualiza o cache em
  /// memória e devolve o conjunto de chaves (ver [chaveEnderecoEstoque]).
  ///
  /// Calculado em Dart ([calcularDesatualizados]) a partir de três cópias de
  /// leitura: as quantidades e a última contagem de cada produto em cada
  /// fonte. Antes era um JOIN que varria inventario_cicli, contagem_itens e
  /// estoque_localizado inteiros, forçado a cada dataRevision e a cada linha
  /// salva — o maior consumo de rows read da loja. Agora recalcular é de
  /// graça, e cada cópia volta ao banco só quando passa da própria janela.
  /// Uma gravação deste aparelho já corrige as cópias na hora.
  ///
  /// Sem alguma das cópias (e sem rede para buscá-la), devolve o último
  /// cálculo — como antes, quando a consulta falhava.
  ///
  /// [atualizarSeVencida]: espera a releitura das contagens que passaram da
  /// janela (a tela que volta do bloqueio; as cópias de contagem não avisam
  /// quando mudam, então releitura por trás não repintaria os selos).
  Future<Set<String>> fetchEnderecosDesatualizados({
    bool forceRefresh = false,
    bool atualizarSeVencida = false,
  }) async {
    try {
      final turso = TursoService();
      final resultados = await Future.wait([
        turso.consultarQuantidades(falharSemCache: true),
        turso.consultarUltimasContagensCiclico(
          forceRefresh: forceRefresh,
          atualizarSeVencida: atualizarSeVencida,
        ),
        turso.consultarUltimasContagensItens(
          forceRefresh: forceRefresh,
          atualizarSeVencida: atualizarSeVencida,
        ),
      ]);
      final novo = <String, EnderecoDesatualizado>{};
      for (final a in calcularDesatualizados(
        enderecos: resultados[0],
        ultimasContagens: [...resultados[1], ...resultados[2]],
      )) {
        final r = a.endereco;
        final item = EnderecoDesatualizado(
          produtoCodigo: r['produto_codigo'] as String? ?? '',
          localTipo: r['local_tipo'] as String? ?? 'gondola',
          localNum: r['local_num'] as int? ?? 0,
          faceOuColuna: r['face_ou_coluna'] as int? ?? 0,
          andarOuNivel: r['andar_ou_nivel'] as int? ?? 0,
          atualizadoEm: r['atualizado_em'] as String? ?? '',
          ultimaContagemEm: a.ultima,
        );
        novo[item.chave] = item;
      }
      _desatualizadosCache = novo;
    } catch (_) {
      // Sem cópia e sem rede: fica o último cálculo.
    }
    return _desatualizadosCache.keys.toSet();
  }

  /// Subconjunto das divergências (ver [fetchEnderecosDivergentes]) cuja
  /// diferença é positiva — contou-se mais do que o sistema tinha. Lido do
  /// cache preenchido pela última chamada de fetchEnderecosDivergentes, sem
  /// ida ao banco; deve ser consultado depois dela.
  Set<String> get divergentesPositivas => _divergentesPositivasCache;

  /// Os endereços cujo produto está com divergência no ciclo
  /// (estoque_mestre.status_ciclo = 'divergencia', gravado por
  /// [concluirContagem] e pelos apps irmãos). Como a divergência é do
  /// produto, todos os endereços dele entram. Atualiza o cache em memória e
  /// devolve o conjunto de chaves.
  ///
  /// Calculado em Dart ([calcularDivergentes]) a partir da cópia das
  /// quantidades e da cópia dos produtos divergentes — que, pelo índice de
  /// status_ciclo, lê só os divergentes.
  Future<Set<String>> fetchEnderecosDivergentes({
    bool forceRefresh = false,
    bool atualizarSeVencida = false,
  }) async {
    try {
      final turso = TursoService();
      final resultados = await Future.wait([
        turso.consultarQuantidades(falharSemCache: true),
        turso.consultarDivergentesCiclo(
          forceRefresh: forceRefresh,
          atualizarSeVencida: atualizarSeVencida,
        ),
      ]);
      final calculo = calcularDivergentes(
        enderecos: resultados[0],
        divergentesCiclo: resultados[1],
      );
      String chave(Map<String, dynamic> r) => chaveEnderecoEstoque(
        produtoCodigo: r['produto_codigo'] as String? ?? '',
        localTipo: r['local_tipo'] as String? ?? 'gondola',
        localNum: r['local_num'] as int? ?? 0,
        faceOuColuna: r['face_ou_coluna'] as int? ?? 0,
        andarOuNivel: r['andar_ou_nivel'] as int? ?? 0,
      );
      _divergentesCache = calculo.divergentes.map(chave).toSet();
      _divergentesPositivasCache = calculo.positivas.map(chave).toSet();
    } catch (_) {
      // Sem cópia e sem rede: fica o último cálculo.
    }
    return _divergentesCache;
  }

  /// Consulta o cache em memória (sem ida ao banco) — usado pelo painter das
  /// cenas 3D para decidir se desenha o badge de endereço desatualizado.
  bool isDesatualizado({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
    required int faceOuColuna,
    required int andarOuNivel,
  }) => _desatualizadosCache.containsKey(
    chaveEnderecoEstoque(
      produtoCodigo: produtoCodigo,
      localTipo: localTipo,
      localNum: localNum,
      faceOuColuna: faceOuColuna,
      andarOuNivel: andarOuNivel,
    ),
  );

  /// Detalhe (datas) do aviso de endereço desatualizado, ou null se o
  /// endereço estiver em dia. Usado pelo dialog de quantidade.
  EnderecoDesatualizado? infoDesatualizado(EnderecoLocalizado endereco) =>
      _desatualizadosCache[chaveEnderecoEstoque(
        produtoCodigo: endereco.produtoCodigo,
        localTipo: endereco.localTipo,
        localNum: endereco.localNum,
        faceOuColuna: endereco.faceOuColuna,
        andarOuNivel: endereco.andarOuNivel,
      )];

  Future<List<EnderecoLocalizado>> fetchEnderecosProduto(
    String produtoCodigo, {
    bool usarCache = false,
  }) async {
    if (usarCache) {
      final rows = await TursoService().consultarQuantidades(
        falharSemCache: true,
      );
      return rows
          .where((r) => r['produto_codigo'] == produtoCodigo)
          .map(_enderecoDaLinha)
          .toList();
    }
    final client = await _conexao();
    if (client == null) return [];
    try {
      final stmt = await client.prepare(
        'SELECT id, produto_codigo, local_tipo, local_num, face_ou_coluna, andar_ou_nivel, '
        'quantidade, atualizado_em FROM estoque_localizado '
        'WHERE produto_codigo = ? ORDER BY local_tipo, local_num, face_ou_coluna, andar_ou_nivel',
      );
      final rows = await stmt.query(positional: [produtoCodigo]);
      TursoService().contarLeitura(
        'enderecos_produto',
        (rows as List<dynamic>).length,
      );
      return rows.map((dynamic row) {
        final r = row as Map<String, dynamic>;
        return _enderecoDaLinha(r);
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static EnderecoLocalizado _enderecoDaLinha(Map<String, dynamic> r) {
    return EnderecoLocalizado(
      id: r['id'] as int?,
      produtoCodigo: r['produto_codigo'] as String? ?? '',
      localTipo: r['local_tipo'] as String? ?? 'gondola',
      localNum: r['local_num'] as int? ?? 0,
      faceOuColuna: r['face_ou_coluna'] as int? ?? 0,
      andarOuNivel: r['andar_ou_nivel'] as int? ?? 0,
      quantidade: (r['quantidade'] as num?)?.toDouble() ?? 0,
      atualizadoEm: r['atualizado_em'] as String?,
    );
  }

  Future<double> totalProduto(String produtoCodigo) async {
    final enderecos = await fetchEnderecosProduto(produtoCodigo);
    return enderecos.fold<double>(0, (soma, e) => soma + e.quantidade);
  }

  Future<InfoEstoqueMestre?> buscarInfoMestre(
    String produtoCodigo, {
    bool usarCache = false,
  }) async {
    if (usarCache) {
      final rows = await TursoService().consultarSaldos();
      final encontrados = rows.where((r) => r['codigo'] == produtoCodigo);
      if (encontrados.isEmpty) return null;
      final r = encontrados.first;
      return InfoEstoqueMestre(
        produtoNome: r['produto'] as String? ?? '',
        categoria: r['categoria'] as String? ?? '',
        qtdSistema: (r['qtd_sistema'] as num?)?.toDouble() ?? 0,
      );
    }
    final client = await _conexao();
    if (client == null) return null;
    try {
      final stmt = await client.prepare(
        'SELECT produto, categoria, qtd_sistema FROM estoque_mestre WHERE codigo = ? LIMIT 1',
      );
      final rows = await stmt.query(positional: [produtoCodigo]);
      final list = rows as List<dynamic>;
      TursoService().contarLeitura('info_mestre', list.length);
      if (list.isEmpty) return null;
      final r = list.first as Map<String, dynamic>;
      return InfoEstoqueMestre(
        produtoNome: r['produto'] as String? ?? '',
        categoria: r['categoria'] as String? ?? '',
        qtdSistema: (r['qtd_sistema'] as num?)?.toDouble() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Upsert de uma quantidade (via UNIQUE de estoque_localizado) + registro
  /// no log. Não mexe em inventario_cicli nem em estoque_mestre.
  ///
  /// [origem] é o que fica gravado em contagens_log. O padrão é a gravação
  /// feita à mão na tela; a baixa automática passa a sua (ver
  /// BaixaPorContagemService.origemLog), e é por ela que se separa depois o
  /// que uma pessoa digitou do que o app deduziu sozinho.
  Future<bool> upsertQuantidade({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
    required int faceOuColuna,
    required int andarOuNivel,
    required double quantidade,
    String origem = 'gondolas_app',
    bool avisar = true,
  }) async {
    final turso = TursoService();
    final uuid = gerarUuidV4();
    final agora = DateTime.now().toIso8601String();
    final endereco = EnderecoLocalizado(
      produtoCodigo: produtoCodigo,
      localTipo: localTipo,
      localNum: localNum,
      faceOuColuna: faceOuColuna,
      andarOuNivel: andarOuNivel,
      quantidade: quantidade,
    );
    final codigo = sqlTexto(produtoCodigo);
    final tipo = sqlTexto(localTipo);
    final onde =
        'produto_codigo = $codigo AND local_tipo = $tipo AND '
        'local_num = ${sqlNumero(localNum)} AND '
        'face_ou_coluna = ${sqlNumero(faceOuColuna)} AND '
        'andar_ou_nivel = ${sqlNumero(andarOuNivel)}';
    // UMA requisição (ver gravacao_lote.dart). Eram ~9 idas e voltas em fila
    // — leitura do anterior, upsert, log, carimbo, releitura —, todas dentro
    // de uma transação aberta no servidor. O log vem antes do upsert porque é
    // a linha ainda intacta que dá a quantidade anterior.
    try {
      await turso.executarLote([
        'INSERT INTO contagens_log '
            '(produto_codigo, endereco, qtd_anterior, qtd_nova, origem, '
            'registrado_em) VALUES ($codigo, '
            '${sqlTexto(endereco.enderecoCompacto)}, '
            '(SELECT quantidade FROM estoque_localizado WHERE $onde LIMIT 1), '
            '${sqlNumero(quantidade)}, ${sqlTexto(origem)}, '
            '${sqlTexto(agora)})',
        'INSERT INTO estoque_localizado (produto_codigo, local_tipo, '
            'local_num, face_ou_coluna, andar_ou_nivel, quantidade, '
            'atualizado_em) VALUES ($codigo, $tipo, ${sqlNumero(localNum)}, '
            '${sqlNumero(faceOuColuna)}, ${sqlNumero(andarOuNivel)}, '
            '${sqlNumero(quantidade)}, ${sqlTexto(agora)}) '
            'ON CONFLICT(produto_codigo, local_tipo, local_num, '
            'face_ou_coluna, andar_ou_nivel) DO UPDATE SET '
            'quantidade = excluded.quantidade, '
            'atualizado_em = excluded.atualizado_em',
        comandoCarimbo(
          uuid: uuid,
          operacao: 'estoqueLocalizado.upsertQuantidade',
          aplicadaEm: agora,
          dispositivo: await turso.dispositivo(),
        ),
      ]);
    } on FalhaGravacao catch (falha) {
      // Resposta perdida não prova que não gravou: o carimbo no servidor diz.
      if (!falha.transitoria || !await turso.confirmadoNoServidor(uuid)) {
        return false;
      }
    } catch (_) {
      return false;
    }
    // A cópia das quantidades não expira: o produto é relido logo abaixo
    // (pelo UNIQUE com produto_codigo na frente), e expirar mandaria reler o
    // estoque_localizado inteiro a cada caixa salva.
    await turso.marcarGravacaoLocal(expirarQuantidades: false);
    // A cópia do produto é relida por trás: quem gravou já tem o número na
    // tela, e esperar essa leitura era mais uma ida ao banco segurando o
    // "salvando". Os selos se recalculam dela quando o aviso chega.
    //
    // Sem aviso (a baixa grava em série e avisa uma vez no fim), a releitura
    // é esperada: o aviso do fim tem que chegar com a cópia já corrigida,
    // senão as telas recalculavam do número antigo e ninguém avisava de novo.
    if (avisar) {
      unawaited(_atualizarCopiaDoProduto(produtoCodigo));
    } else {
      await _atualizarCopiaDoProduto(produtoCodigo, avisar: false);
    }
    return true;
  }

  /// Relê do servidor as linhas de UM produto e corrige a cópia das
  /// quantidades. Corrige ou expira: sem a releitura, a cópia ficaria sem a
  /// gravação até a janela vencer.
  Future<void> _atualizarCopiaDoProduto(
    String produtoCodigo, {
    bool avisar = true,
  }) async {
    try {
      final client = await _conexao();
      if (client == null) {
        _expirarCopia(avisar);
        return;
      }
      final rows = await client.query(
        'SELECT id, produto_codigo, local_tipo, local_num, face_ou_coluna, '
        'andar_ou_nivel, quantidade, atualizado_em FROM estoque_localizado '
        'WHERE produto_codigo = ?',
        positional: [produtoCodigo],
      );
      TursoService().contarLeitura('quantidades_produto', rows.length);
      await TursoService().guardarQuantidadesProduto(
        produtoCodigo,
        rows.map((r) => Map<String, dynamic>.from(r)).toList(),
        avisar: avisar,
      );
    } catch (_) {
      _expirarCopia(avisar);
    }
  }

  /// A cópia ficou sem a gravação. Expirar só manda a PRÓXIMA leitura ao
  /// banco — e a tela que já recalculou os selos ao fechar o diálogo não lê
  /// de novo. Então a releitura sai já, por trás: quando ela trouxer a
  /// gravação, o aviso de dados novos recalcula as telas. (Quem grava sem
  /// aviso avisa no fim, e esse aviso faz as telas lerem a cópia expirada.)
  void _expirarCopia(bool avisar) {
    final turso = TursoService();
    turso.expirarQuantidades();
    if (avisar) {
      unawaited(turso.consultarQuantidades().then<void>((_) {}, onError: (_) {}));
    }
  }

  /// Exclui um endereço de estoque_localizado (pela chave lógica — ids podem
  /// divergir entre réplicas offline) e registra a exclusão no log.
  Future<bool> deleteEndereco({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
    required int faceOuColuna,
    required int andarOuNivel,
  }) async {
    try {
      return await TursoService().garantirReplicaProntaParaEscrita(
        () => _deleteEndereco(
          produtoCodigo: produtoCodigo,
          localTipo: localTipo,
          localNum: localNum,
          faceOuColuna: faceOuColuna,
          andarOuNivel: andarOuNivel,
        ),
      );
    } on ReplicaNaoProntaParaEscrita {
      return false;
    }
  }

  Future<bool> _deleteEndereco({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
    required int faceOuColuna,
    required int andarOuNivel,
  }) async {
    final client = await _conexao();
    if (client == null) return false;
    final tx = await client.transaction();
    MutacaoOutbox? mutacao;
    final chaveEndereco = chaveDoEndereco(
      produtoCodigo: produtoCodigo,
      localTipo: localTipo,
      localNum: localNum,
      faceOuColuna: faceOuColuna,
      andarOuNivel: andarOuNivel,
    );
    try {
      final rowsAnterior = await tx.query(
        'SELECT quantidade FROM estoque_localizado WHERE produto_codigo = ? AND '
        'local_tipo = ? AND local_num = ? AND face_ou_coluna = ? AND andar_ou_nivel = ? LIMIT 1',
        positional: [
          produtoCodigo,
          localTipo,
          localNum,
          faceOuColuna,
          andarOuNivel,
        ],
      );
      final qtdAnterior = rowsAnterior.isEmpty
          ? null
          : rowsAnterior.first['quantidade'] as num?;

      await tx.execute(
        'DELETE FROM estoque_localizado WHERE produto_codigo = ? AND '
        'local_tipo = ? AND local_num = ? AND face_ou_coluna = ? AND andar_ou_nivel = ?',
        positional: [
          produtoCodigo,
          localTipo,
          localNum,
          faceOuColuna,
          andarOuNivel,
        ],
      );

      final endereco = EnderecoLocalizado(
        produtoCodigo: produtoCodigo,
        localTipo: localTipo,
        localNum: localNum,
        faceOuColuna: faceOuColuna,
        andarOuNivel: andarOuNivel,
        quantidade: 0,
      );
      await tx.execute(
        'INSERT INTO contagens_log '
        '(produto_codigo, endereco, qtd_anterior, qtd_nova, origem, registrado_em) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        positional: [
          produtoCodigo,
          endereco.enderecoCompacto,
          qtdAnterior,
          0,
          'gondolas_app_exclusao',
          DateTime.now().toIso8601String(),
        ],
      );
      mutacao = await TursoService().abrirMutacao(
        operacao: 'estoqueLocalizado.deleteEndereco',
        auditoria: {
          'produto_codigo': produtoCodigo,
          'endereco': endereco.enderecoCompacto,
          'qtd_anterior': qtdAnterior,
          'qtd_nova': 0,
          'origem': 'gondolas_app_exclusao',
          'registrado_em': DateTime.now().toIso8601String(),
        },
        tabela: 'estoque_localizado',
        chave: chaveEndereco,
        estadoAnterior: {'quantidade': qtdAnterior},
        estadoFinal: null, // o endereço deixa de existir
        produtoCodigo: produtoCodigo,
        posicao: localNum,
        quantidadeAnterior: qtdAnterior?.toDouble(),
        quantidadePretendida: 0,
      );
      await TursoService().carimbarMutacao(tx, mutacao);
      final quantidadesConfirmadas = await tx.query(
        'SELECT id, produto_codigo, local_tipo, local_num, face_ou_coluna, '
        'andar_ou_nivel, quantidade, atualizado_em FROM estoque_localizado '
        'WHERE produto_codigo = ?',
        positional: [produtoCodigo],
      );
      await tx.commit();
      // A cópia das quantidades é corrigida logo abaixo com as linhas do
      // produto lidas na própria transação.
      await TursoService().marcarGravacaoLocal(expirarQuantidades: false);
      await TursoService().guardarQuantidadesProduto(
        produtoCodigo,
        quantidadesConfirmadas
            .map((r) => Map<String, dynamic>.from(r))
            .toList(),
      );
      return true;
    } catch (_) {
      await tx.rollback();
      if (mutacao != null) await TursoService().abortarMutacao(mutacao);
      return false;
    }
  }

  /// Exclui os endereços ZERADOS de um produto num local (gôndola/estante).
  /// Usado pela limpeza automática ao salvar um layout de onde o produto foi
  /// removido — quantidades > 0 são estoque contado e nunca somem sozinhas.
  Future<bool> deleteEnderecosZerados({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
  }) async {
    try {
      return await TursoService().garantirReplicaProntaParaEscrita(
        () => _deleteEnderecosZerados(
          produtoCodigo: produtoCodigo,
          localTipo: localTipo,
          localNum: localNum,
        ),
      );
    } on ReplicaNaoProntaParaEscrita {
      return false;
    }
  }

  Future<bool> _deleteEnderecosZerados({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
  }) async {
    final client = await _conexao();
    if (client == null) return false;
    // Virou transação para que o carimbo do UUID entre junto com o DELETE: um
    // reconhecimento que pudesse viajar sem a mutação (ou vice-versa) não
    // reconheceria coisa nenhuma.
    final tx = await client.transaction();
    MutacaoOutbox? mutacao;
    try {
      await tx.execute(
        'DELETE FROM estoque_localizado WHERE produto_codigo = ? AND '
        'local_tipo = ? AND local_num = ? AND quantidade = 0',
        positional: [produtoCodigo, localTipo, localNum],
      );
      // Sem estado declarado: só apaga linha ZERADA, e apagar de novo o que já
      // não está lá não muda nada. Ver decidirReaplicacao.
      mutacao = await TursoService().abrirMutacao(
        operacao: 'estoqueLocalizado.deleteEnderecosZerados',
        tabela: 'estoque_localizado',
        chave: {
          'produto_codigo': produtoCodigo,
          'local_tipo': localTipo,
          'local_num': localNum,
          'quantidade': 0,
        },
        estadoAnterior: null,
        estadoFinal: null,
        produtoCodigo: produtoCodigo,
        posicao: localNum,
      );
      await TursoService().carimbarMutacao(tx, mutacao);
      final quantidadesConfirmadas = await tx.query(
        'SELECT id, produto_codigo, local_tipo, local_num, face_ou_coluna, '
        'andar_ou_nivel, quantidade, atualizado_em FROM estoque_localizado '
        'WHERE produto_codigo = ?',
        positional: [produtoCodigo],
      );
      await tx.commit();
      // A cópia das quantidades é corrigida logo abaixo com as linhas do
      // produto lidas na própria transação.
      await TursoService().marcarGravacaoLocal(expirarQuantidades: false);
      await TursoService().guardarQuantidadesProduto(
        produtoCodigo,
        quantidadesConfirmadas
            .map((r) => Map<String, dynamic>.from(r))
            .toList(),
      );
      return true;
    } catch (_) {
      await tx.rollback();
      if (mutacao != null) await TursoService().abortarMutacao(mutacao);
      return false;
    }
  }

  /// Grava os endereços informados e sincroniza o total com o inventário
  /// cíclico, no contrato exato usado pelo dashboard e pelo inventariocamda.
  Future<ResultadoContagem?> concluirContagem(String produtoCodigo) async {
    try {
      return await TursoService().garantirReplicaProntaParaEscrita(
        () => _concluirContagem(produtoCodigo),
      );
    } on ReplicaNaoProntaParaEscrita {
      return null;
    }
  }

  Future<ResultadoContagem?> _concluirContagem(String produtoCodigo) async {
    final client = await _conexao();
    if (client == null) return null;

    final info = await buscarInfoMestre(produtoCodigo);
    if (info == null) return null;

    final enderecos = await fetchEnderecosProduto(produtoCodigo);
    final total = enderecos.fold<double>(0, (soma, e) => soma + e.quantidade);
    final divergencia = total - info.qtdSistema;
    final status = divergencia == 0 ? 'ok' : 'divergencia';

    final agora = DateTime.now();
    final agoraIso = agora.toIso8601String();
    final hoje =
        '${agora.year.toString().padLeft(4, '0')}-'
        '${agora.month.toString().padLeft(2, '0')}-'
        '${agora.day.toString().padLeft(2, '0')}';
    final categoriaCor =
        TursoService.categoriaCores[info.categoria] ?? '#888888';
    final observacao = enderecos
        .map((e) => '${e.enderecoCompacto} (${_fmtQtd(e.quantidade)})')
        .join(' + ');

    final tx = await client.transaction();
    MutacaoOutbox? mutacao;
    try {
      // Traz os valores, não só o `1`: são eles o estado anterior que a outbox
      // precisa para decidir, depois de uma reconstrução, se o remoto ainda
      // está onde estava quando esta contagem foi fechada.
      final existe = await tx.query(
        'SELECT qtd_contada, divergencia FROM inventario_cicli '
        'WHERE data_contagem = ? AND produto_id = ? LIMIT 1',
        positional: [hoje, produtoCodigo],
      );

      if (existe.isEmpty) {
        await tx.execute(
          'INSERT INTO inventario_cicli '
          '(data_contagem, produto_id, produto_nome, categoria_id, categoria_label, categoria_cor, '
          'qtd_sistema, qtd_contada, divergencia, contado_em, observacao) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          positional: [
            hoje,
            produtoCodigo,
            info.produtoNome,
            info.categoria,
            info.categoria,
            categoriaCor,
            info.qtdSistema,
            total,
            divergencia,
            agoraIso,
            observacao,
          ],
        );
      } else {
        await tx.execute(
          'UPDATE inventario_cicli SET qtd_contada = ?, divergencia = ?, contado_em = ?, '
          'observacao = ?, produto_nome = ?, qtd_sistema = ? '
          'WHERE data_contagem = ? AND produto_id = ?',
          positional: [
            total,
            divergencia,
            agoraIso,
            observacao,
            info.produtoNome,
            info.qtdSistema,
            hoje,
            produtoCodigo,
          ],
        );
      }

      await tx.execute(
        'UPDATE estoque_mestre SET status_ciclo = ?, qtd_contada_ciclo = ?, '
        'qtd_sistema_na_contagem = ?, contado_ciclo_em = ? WHERE codigo = ?',
        positional: [
          status,
          total.round(),
          info.qtdSistema.round(),
          agoraIso,
          produtoCodigo,
        ],
      );
      // Chave (data, produto) é estável: reaplicável automaticamente.
      mutacao = await TursoService().abrirMutacao(
        operacao: 'estoqueLocalizado.concluirContagem',
        tabela: 'inventario_cicli',
        chave: {'data_contagem': hoje, 'produto_id': produtoCodigo},
        estadoAnterior: existe.isEmpty
            ? null
            : {
                'qtd_contada': (existe.first['qtd_contada'] as num?)
                    ?.toDouble(),
                'divergencia': (existe.first['divergencia'] as num?)
                    ?.toDouble(),
              },
        estadoFinal: {'qtd_contada': total, 'divergencia': divergencia},
        produtoCodigo: produtoCodigo,
        produtoNome: info.produtoNome,
        quantidadeAnterior: existe.isEmpty
            ? null
            : (existe.first['qtd_contada'] as num?)?.toDouble(),
        quantidadePretendida: total,
      );
      await TursoService().carimbarMutacao(tx, mutacao);
      await tx.commit();

      // A contagem não grava estoque_localizado: a cópia das quantidades
      // segue valendo. As cópias dos selos ganham a contagem nova na hora —
      // relidas só no produto, sem varrer inventario_cicli nem
      // estoque_mestre inteiros.
      await TursoService().marcarGravacaoLocal(expirarQuantidades: false);
      await TursoService().registrarContagemConcluida(produtoCodigo);
      return ResultadoContagem(
        total: total,
        qtdSistema: info.qtdSistema,
        divergencia: divergencia,
        status: status,
      );
    } catch (_) {
      await tx.rollback();
      if (mutacao != null) await TursoService().abortarMutacao(mutacao);
      return null;
    }
  }

  String _fmtQtd(double q) =>
      q == q.roundToDouble() ? q.round().toString() : q.toString();
}
