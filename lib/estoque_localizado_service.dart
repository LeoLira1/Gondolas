import 'package:libsql_dart/libsql_dart.dart';
import 'models.dart';
import 'turso_service.dart';

/// Uma linha de estoque_localizado: quantidade de um produto num endereço
/// físico (gôndola ou estante).
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

  /// Código compacto usado no log e na observação do inventário cíclico,
  /// ex: 'G9·F3·A2' (gôndola) ou 'E3·H' (estante).
  String get enderecoCompacto => ehGondola
      ? 'G$localNum·F$faceOuColuna·A${andarOuNivel + 1}'
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
