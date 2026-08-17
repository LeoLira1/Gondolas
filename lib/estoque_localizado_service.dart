import 'package:libsql_dart/libsql_dart.dart';
import 'models.dart';
import 'turso_service.dart';

/// Valor de `local_tipo` dos endereços do galpão em estoque_localizado.
///
/// A tabela é COMPARTILHADA com os apps irmãos (dashboard, inventariocamda,
/// camda-estoque): é dela que saem o total do inventário cíclico e o Modo
/// Conferência. O galpão entra nela como um terceiro tipo, ao lado de
/// 'gondola' e 'estante', para que o estoque de lá conte nos mesmos totais —
/// com local_num = número da posição (1–78), face_ou_coluna = 0 (o galpão não
/// tem face nem coluna) e andar_ou_nivel = ordem na pilha.
const String localTipoGalpao = 'galpao';

/// Uma linha de estoque_localizado: quantidade de um produto num endereço
/// físico (gôndola, estante ou galpão).
class EnderecoLocalizado {
  final int?    id; // null enquanto não gravado em estoque_localizado
  final String  produtoCodigo;
  final String  localTipo; // 'gondola' | 'estante'
  final int     localNum;
  final int     faceOuColuna; // gôndola: face 1-6 | estante: coluna
  final int     andarOuNivel; // gôndola: andar 0-2 | estante: nível
  final double  quantidade;
  final String? atualizadoEm;

  const EnderecoLocalizado({
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
  bool get ehGalpao  => localTipo == localTipoGalpao;

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
  final int    localNum;
  final int    faceOuColuna;
  final int    andarOuNivel;
  final String atualizadoEm;      // do endereço em estoque_localizado
  final String ultimaContagemEm;  // MAX(contado_em, confirmado_em) do produto

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
        localTipo:     localTipo,
        localNum:      localNum,
        faceOuColuna:  faceOuColuna,
        andarOuNivel:  andarOuNivel,
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
  static final EstoqueLocalizadoService _instance =
      EstoqueLocalizadoService._internal();
  factory EstoqueLocalizadoService() => _instance;
  EstoqueLocalizadoService._internal();

  Future<LibsqlClient?> _conexao() async {
    if (!await TursoService().garantirConexao()) return null;
    return TursoService().client;
  }

  // Cache em memória dos endereços desatualizados, carregado uma vez ao abrir
  // cada cena (e recarregado após salvar no dialog de quantidade) — nunca
  // consultado durante o paint.
  Map<String, EnderecoDesatualizado> _desatualizadosCache = {};

  // Cache em memória dos endereços com divergência de contagem, no mesmo
  // esquema de chave dos desatualizados. Carregado junto e nunca consultado
  // durante o paint.
  Set<String> _divergentesCache = {};

  // Subconjunto de _divergentesCache cuja divergência é POSITIVA (quantidade
  // contada maior que a do sistema). Preenchido pela mesma query, para as
  // cenas pintarem essas caixas de azul escuro em vez de vermelho.
  Set<String> _divergentesPositivasCache = {};

  // Validade dos dois caches acima entre aberturas de cena. As queries que os
  // preenchem têm JOIN/GROUP BY caros (varrem inventario_cicli, contagem_itens
  // e estoque_mestre inteiras) e antes rodavam a CADA abertura. Com um TTL
  // curto, reabrir uma cena reaproveita o resultado em memória; uma gravação
  // (upsert/delete/contagem) ou uma sincronização (forceRefresh) invalidam na
  // hora.
  DateTime? _desatualizadosCacheEm;
  DateTime? _divergentesCacheEm;
  static const Duration _cacheTtl = Duration(minutes: 2);

  // Qual coluna de contagem_itens existe neste ambiente (ver
  // fetchEnderecosDesatualizados). Descoberto na primeira consulta e reusado
  // dali em diante: sem isso, num banco sem `confirmado_em`, a query mais cara
  // do app rodava DUAS vezes a cada chamada — a tentativa e o fallback. Volta a
  // null se a coluna memorizada falhar, então o app se corrige sozinho caso o
  // dashboard irmão adicione a coluna depois.
  String? _colunaConfirmacao;

  // Invalida os caches de badges após uma gravação, para a próxima leitura
  // refletir o novo atualizado_em / status_ciclo sem esperar o TTL.
  void _invalidarCachesBadges() {
    _desatualizadosCacheEm = null;
    _divergentesCacheEm    = null;
  }

  /// Busca, numa única query (JOIN com subquery de MAX das duas fontes de
  /// contagem confirmada), todos os endereços cujo atualizado_em é anterior
  /// à última contagem confirmada do produto. Atualiza o cache em memória e
  /// devolve o conjunto de chaves (ver [chaveEnderecoEstoque]).
  ///
  /// contagem_itens.confirmado_em é uma coluna adicionada por migração no
  /// dashboard e pode não existir em todos os ambientes: se a query falhar
  /// por isso, refaz usando registrado_em como fallback.
  Future<Set<String>> fetchEnderecosDesatualizados(
      {bool forceRefresh = false}) async {
    final em = _desatualizadosCacheEm;
    if (!forceRefresh &&
        em != null &&
        DateTime.now().difference(em) < _cacheTtl) {
      return _desatualizadosCache.keys.toSet();
    }

    final client = await _conexao();
    if (client == null) return _desatualizadosCache.keys.toSet();

    // Ordem de tentativa: a coluna que já funcionou antes primeiro; só se ela
    // falhar (ou na primeira vez) é que se tenta a outra.
    final preferida = _colunaConfirmacao ?? 'confirmado_em';
    final alternativa =
        preferida == 'confirmado_em' ? 'registrado_em' : 'confirmado_em';

    List<dynamic> rows;
    try {
      rows = await _queryDesatualizados(client, colunaConfirmacao: preferida);
      _colunaConfirmacao = preferida;
    } catch (_) {
      try {
        rows =
            await _queryDesatualizados(client, colunaConfirmacao: alternativa);
        _colunaConfirmacao = alternativa;
      } catch (_) {
        _colunaConfirmacao = null;
        return _desatualizadosCache.keys.toSet();
      }
    }

    final novoCache = <String, EnderecoDesatualizado>{};
    for (final dynamic row in rows) {
      final r      = row as Map<String, dynamic>;
      final ultima = r['ultima']        as String?;
      final atual  = r['atualizado_em'] as String?;
      if (ultima == null || atual == null) continue;

      final dtUltima = DateTime.tryParse(ultima);
      final dtAtual  = DateTime.tryParse(atual);
      if (dtUltima == null || dtAtual == null) continue; // formato inválido: ignora
      if (!dtAtual.isBefore(dtUltima)) continue;

      final item = EnderecoDesatualizado(
        produtoCodigo: r['produto_codigo']  as String? ?? '',
        localTipo:     r['local_tipo']      as String? ?? 'gondola',
        localNum:      r['local_num']       as int?    ?? 0,
        faceOuColuna:  r['face_ou_coluna']  as int?    ?? 0,
        andarOuNivel:  r['andar_ou_nivel']  as int?    ?? 0,
        atualizadoEm:  atual,
        ultimaContagemEm: ultima,
      );
      novoCache[item.chave] = item;
    }
    _desatualizadosCache   = novoCache;
    _desatualizadosCacheEm = DateTime.now();
    return novoCache.keys.toSet();
  }

  Future<List<dynamic>> _queryDesatualizados(
    LibsqlClient client, {
    required String colunaConfirmacao,
  }) async {
    final stmt = await client.prepare('''
      SELECT el.produto_codigo, el.local_tipo, el.local_num, el.face_ou_coluna,
             el.andar_ou_nivel, el.atualizado_em, uc.ultima
      FROM estoque_localizado el
      JOIN (
        SELECT produto_codigo, MAX(dt) AS ultima FROM (
          SELECT produto_id AS produto_codigo, contado_em AS dt
          FROM inventario_cicli WHERE contado_em IS NOT NULL
          UNION ALL
          SELECT codigo AS produto_codigo, $colunaConfirmacao AS dt
          FROM contagem_itens WHERE status != 'pendente' AND $colunaConfirmacao IS NOT NULL
        )
        GROUP BY produto_codigo
      ) uc ON uc.produto_codigo = el.produto_codigo
    ''');
    return (await stmt.query()) as List<dynamic>;
  }

  /// Busca os endereços cujo produto está marcado com divergência de contagem
  /// no ciclo — estoque_mestre.status_ciclo = 'divergencia', gravado por
  /// [concluirContagem] quando o total contado difere de qtd_sistema. Como a
  /// divergência é do produto (qtd_sistema não existe por endereço), todos os
  /// endereços do produto divergente entram no conjunto, no mesmo formato de
  /// chave ([chaveEnderecoEstoque]) usado pelos desatualizados. Atualiza o
  /// cache em memória e devolve o conjunto de chaves.
  /// Subconjunto das divergências (ver [fetchEnderecosDivergentes]) cuja
  /// diferença é positiva — contou-se mais do que o sistema tinha. Lido do
  /// cache preenchido pela última chamada de fetchEnderecosDivergentes, sem
  /// ida ao banco; deve ser consultado depois dela.
  Set<String> get divergentesPositivas => _divergentesPositivasCache;

  Future<Set<String>> fetchEnderecosDivergentes(
      {bool forceRefresh = false}) async {
    final em = _divergentesCacheEm;
    if (!forceRefresh &&
        em != null &&
        DateTime.now().difference(em) < _cacheTtl) {
      return _divergentesCache;
    }

    final client = await _conexao();
    if (client == null) return _divergentesCache;

    try {
      final stmt = await client.prepare('''
        SELECT el.produto_codigo, el.local_tipo, el.local_num,
               el.face_ou_coluna, el.andar_ou_nivel,
               em.qtd_contada_ciclo, em.qtd_sistema_na_contagem
        FROM estoque_localizado el
        JOIN estoque_mestre em ON em.codigo = el.produto_codigo
        WHERE em.status_ciclo = 'divergencia'
      ''');
      final rows = (await stmt.query()) as List<dynamic>;
      final novo = <String>{};
      final novoPositivas = <String>{};
      for (final dynamic row in rows) {
        final r = row as Map<String, dynamic>;
        final chave = chaveEnderecoEstoque(
          produtoCodigo: r['produto_codigo'] as String? ?? '',
          localTipo:     r['local_tipo']     as String? ?? 'gondola',
          localNum:      r['local_num']      as int?    ?? 0,
          faceOuColuna:  r['face_ou_coluna'] as int?    ?? 0,
          andarOuNivel:  r['andar_ou_nivel'] as int?    ?? 0,
        );
        novo.add(chave);
        // Divergência positiva: contou-se mais do que o sistema registrava.
        final contada = (r['qtd_contada_ciclo']       as num?)?.toDouble();
        final sistema = (r['qtd_sistema_na_contagem'] as num?)?.toDouble();
        if (contada != null && sistema != null && contada > sistema) {
          novoPositivas.add(chave);
        }
      }
      _divergentesCache          = novo;
      _divergentesPositivasCache = novoPositivas;
      _divergentesCacheEm        = DateTime.now();
      return novo;
    } catch (_) {
      return _divergentesCache;
    }
  }

  /// Consulta o cache em memória (sem ida ao banco) — usado pelo painter das
  /// cenas 3D para decidir se desenha o badge de endereço desatualizado.
  bool isDesatualizado({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
    required int faceOuColuna,
    required int andarOuNivel,
  }) =>
      _desatualizadosCache.containsKey(chaveEnderecoEstoque(
        produtoCodigo: produtoCodigo,
        localTipo:     localTipo,
        localNum:      localNum,
        faceOuColuna:  faceOuColuna,
        andarOuNivel:  andarOuNivel,
      ));

  /// Detalhe (datas) do aviso de endereço desatualizado, ou null se o
  /// endereço estiver em dia. Usado pelo dialog de quantidade.
  EnderecoDesatualizado? infoDesatualizado(EnderecoLocalizado endereco) =>
      _desatualizadosCache[chaveEnderecoEstoque(
        produtoCodigo: endereco.produtoCodigo,
        localTipo:     endereco.localTipo,
        localNum:      endereco.localNum,
        faceOuColuna:  endereco.faceOuColuna,
        andarOuNivel:  endereco.andarOuNivel,
      )];

  Future<List<EnderecoLocalizado>> fetchEnderecosProduto(
      String produtoCodigo) async {
    final client = await _conexao();
    if (client == null) return [];
    try {
      final stmt = await client.prepare(
        'SELECT id, produto_codigo, local_tipo, local_num, face_ou_coluna, andar_ou_nivel, '
        'quantidade, atualizado_em FROM estoque_localizado '
        'WHERE produto_codigo = ? ORDER BY local_tipo, local_num, face_ou_coluna, andar_ou_nivel',
      );
      final rows = await stmt.query(positional: [produtoCodigo]);
      return (rows as List<dynamic>).map((dynamic row) {
        final r = row as Map<String, dynamic>;
        return EnderecoLocalizado(
          id:            r['id']             as int?,
          produtoCodigo: r['produto_codigo']  as String? ?? produtoCodigo,
          localTipo:     r['local_tipo']      as String? ?? 'gondola',
          localNum:      r['local_num']       as int?    ?? 0,
          faceOuColuna:  r['face_ou_coluna']  as int?    ?? 0,
          andarOuNivel:  r['andar_ou_nivel']  as int?    ?? 0,
          quantidade:    (r['quantidade'] as num?)?.toDouble() ?? 0,
          atualizadoEm:  r['atualizado_em']   as String?,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<double> totalProduto(String produtoCodigo) async {
    final enderecos = await fetchEnderecosProduto(produtoCodigo);
    return enderecos.fold<double>(0, (soma, e) => soma + e.quantidade);
  }

  Future<InfoEstoqueMestre?> buscarInfoMestre(String produtoCodigo) async {
    final client = await _conexao();
    if (client == null) return null;
    try {
      final stmt = await client.prepare(
        'SELECT produto, categoria, qtd_sistema FROM estoque_mestre WHERE codigo = ? LIMIT 1',
      );
      final rows = await stmt.query(positional: [produtoCodigo]);
      final list = rows as List<dynamic>;
      if (list.isEmpty) return null;
      final r = list.first as Map<String, dynamic>;
      return InfoEstoqueMestre(
        produtoNome: r['produto']   as String? ?? '',
        categoria:   r['categoria'] as String? ?? '',
        qtdSistema:  (r['qtd_sistema'] as num?)?.toDouble() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Upsert de uma quantidade (via UNIQUE de estoque_localizado) + registro
  /// no log. Não mexe em inventario_cicli nem em estoque_mestre.
  Future<bool> upsertQuantidade({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
    required int faceOuColuna,
    required int andarOuNivel,
    required double quantidade,
  }) async {
    final client = await _conexao();
    if (client == null) return false;
    try {
      final stmtAnterior = await client.prepare(
        'SELECT quantidade FROM estoque_localizado WHERE produto_codigo = ? AND '
        'local_tipo = ? AND local_num = ? AND face_ou_coluna = ? AND andar_ou_nivel = ? LIMIT 1',
      );
      final rowsAnterior = (await stmtAnterior.query(positional: [
        produtoCodigo,
        localTipo,
        localNum,
        faceOuColuna,
        andarOuNivel,
      ])) as List<dynamic>;
      final qtdAnterior = rowsAnterior.isEmpty
          ? null
          : (rowsAnterior.first as Map<String, dynamic>)['quantidade'] as num?;

      final agora = DateTime.now().toIso8601String();
      final stmtUpsert = await client.prepare(
        'INSERT INTO estoque_localizado '
        '(produto_codigo, local_tipo, local_num, face_ou_coluna, andar_ou_nivel, quantidade, atualizado_em) '
        'VALUES (?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(produto_codigo, local_tipo, local_num, face_ou_coluna, andar_ou_nivel) '
        'DO UPDATE SET quantidade = excluded.quantidade, atualizado_em = excluded.atualizado_em',
      );
      await stmtUpsert.query(positional: [
        produtoCodigo,
        localTipo,
        localNum,
        faceOuColuna,
        andarOuNivel,
        quantidade,
        agora,
      ]);

      final endereco = EnderecoLocalizado(
        produtoCodigo: produtoCodigo,
        localTipo:     localTipo,
        localNum:      localNum,
        faceOuColuna:  faceOuColuna,
        andarOuNivel:  andarOuNivel,
        quantidade:    quantidade,
      );
      final stmtLog = await client.prepare(
        'INSERT INTO contagens_log '
        '(produto_codigo, endereco, qtd_anterior, qtd_nova, origem, registrado_em) '
        'VALUES (?, ?, ?, ?, ?, ?)',
      );
      await stmtLog.query(positional: [
        produtoCodigo,
        endereco.enderecoCompacto,
        qtdAnterior,
        quantidade,
        'gondolas_app',
        agora,
      ]);
      _invalidarCachesBadges();
      return true;
    } catch (_) {
      return false;
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
    final client = await _conexao();
    if (client == null) return false;
    try {
      final stmtAnterior = await client.prepare(
        'SELECT quantidade FROM estoque_localizado WHERE produto_codigo = ? AND '
        'local_tipo = ? AND local_num = ? AND face_ou_coluna = ? AND andar_ou_nivel = ? LIMIT 1',
      );
      final rowsAnterior = (await stmtAnterior.query(positional: [
        produtoCodigo,
        localTipo,
        localNum,
        faceOuColuna,
        andarOuNivel,
      ])) as List<dynamic>;
      final qtdAnterior = rowsAnterior.isEmpty
          ? null
          : (rowsAnterior.first as Map<String, dynamic>)['quantidade'] as num?;

      final stmtDelete = await client.prepare(
        'DELETE FROM estoque_localizado WHERE produto_codigo = ? AND '
        'local_tipo = ? AND local_num = ? AND face_ou_coluna = ? AND andar_ou_nivel = ?',
      );
      await stmtDelete.query(positional: [
        produtoCodigo,
        localTipo,
        localNum,
        faceOuColuna,
        andarOuNivel,
      ]);

      final endereco = EnderecoLocalizado(
        produtoCodigo: produtoCodigo,
        localTipo:     localTipo,
        localNum:      localNum,
        faceOuColuna:  faceOuColuna,
        andarOuNivel:  andarOuNivel,
        quantidade:    0,
      );
      final stmtLog = await client.prepare(
        'INSERT INTO contagens_log '
        '(produto_codigo, endereco, qtd_anterior, qtd_nova, origem, registrado_em) '
        'VALUES (?, ?, ?, ?, ?, ?)',
      );
      await stmtLog.query(positional: [
        produtoCodigo,
        endereco.enderecoCompacto,
        qtdAnterior,
        0,
        'gondolas_app_exclusao',
        DateTime.now().toIso8601String(),
      ]);
      _invalidarCachesBadges();
      return true;
    } catch (_) {
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
    final client = await _conexao();
    if (client == null) return false;
    try {
      final stmt = await client.prepare(
        'DELETE FROM estoque_localizado WHERE produto_codigo = ? AND '
        'local_tipo = ? AND local_num = ? AND quantidade = 0',
      );
      await stmt.query(positional: [produtoCodigo, localTipo, localNum]);
      _invalidarCachesBadges();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Grava os endereços informados e sincroniza o total com o inventário
  /// cíclico, no contrato exato usado pelo dashboard e pelo inventariocamda.
  Future<ResultadoContagem?> concluirContagem(String produtoCodigo) async {
    final client = await _conexao();
    if (client == null) return null;

    final info = await buscarInfoMestre(produtoCodigo);
    if (info == null) return null;

    final enderecos = await fetchEnderecosProduto(produtoCodigo);
    final total = enderecos.fold<double>(0, (soma, e) => soma + e.quantidade);
    final divergencia = total - info.qtdSistema;
    final status = divergencia == 0 ? 'ok' : 'divergencia';

    final agora    = DateTime.now();
    final agoraIso = agora.toIso8601String();
    final hoje     = '${agora.year.toString().padLeft(4, '0')}-'
        '${agora.month.toString().padLeft(2, '0')}-'
        '${agora.day.toString().padLeft(2, '0')}';
    final categoriaCor =
        TursoService.categoriaCores[info.categoria] ?? '#888888';
    final observacao = enderecos
        .map((e) => '${e.enderecoCompacto} (${_fmtQtd(e.quantidade)})')
        .join(' + ');

    try {
      final stmtCheck = await client.prepare(
        'SELECT 1 FROM inventario_cicli WHERE data_contagem = ? AND produto_id = ? LIMIT 1',
      );
      final existe = (await stmtCheck.query(positional: [hoje, produtoCodigo]))
          as List<dynamic>;

      if (existe.isEmpty) {
        final stmtIns = await client.prepare(
          'INSERT INTO inventario_cicli '
          '(data_contagem, produto_id, produto_nome, categoria_id, categoria_label, categoria_cor, '
          'qtd_sistema, qtd_contada, divergencia, contado_em, observacao) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        );
        await stmtIns.query(positional: [
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
        ]);
      } else {
        final stmtUpd = await client.prepare(
          'UPDATE inventario_cicli SET qtd_contada = ?, divergencia = ?, contado_em = ?, '
          'observacao = ?, produto_nome = ?, qtd_sistema = ? '
          'WHERE data_contagem = ? AND produto_id = ?',
        );
        await stmtUpd.query(positional: [
          total,
          divergencia,
          agoraIso,
          observacao,
          info.produtoNome,
          info.qtdSistema,
          hoje,
          produtoCodigo,
        ]);
      }

      final stmtMestre = await client.prepare(
        'UPDATE estoque_mestre SET status_ciclo = ?, qtd_contada_ciclo = ?, '
        'qtd_sistema_na_contagem = ?, contado_ciclo_em = ? WHERE codigo = ?',
      );
      await stmtMestre.query(positional: [
        status,
        total.round(),
        info.qtdSistema.round(),
        agoraIso,
        produtoCodigo,
      ]);

      _invalidarCachesBadges();
      return ResultadoContagem(
        total:       total,
        qtdSistema:  info.qtdSistema,
        divergencia: divergencia,
        status:      status,
      );
    } catch (_) {
      return null;
    }
  }

  String _fmtQtd(double q) =>
      q == q.roundToDouble() ? q.round().toString() : q.toString();
}
