import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class TursoService {
  static final TursoService _instance = TursoService._internal();
  factory TursoService() => _instance;
  TursoService._internal();

  static const String keyDbUrl   = 'turso_db_url';
  static const String keyDbToken = 'turso_db_token';

  static const Map<String, String> categoriaCores = {
    'Lubrificantes': '#2e7d4f',
    'Calçados':      '#2c5fb0',
    'Vestuário':     '#6b4a2b',
    'Chapéus':       '#d9b46a',
    'Lonas':         '#e87722',
    'Defensivos':    '#8b1a1a',
    'Sementes':      '#c8a000',
    'Ferramentas':   '#4a4a8a',
  };

  LibsqlClient? _client;
  bool _connected = false;

  bool get isConnected => _connected;

  Future<void> init() async {
    _connected = false;
    _client = null;

    final prefs = await SharedPreferences.getInstance();
    final url   = prefs.getString(keyDbUrl)   ?? '';
    final token = prefs.getString(keyDbToken) ?? '';

    if (url.isEmpty || token.isEmpty) return;

    try {
      final client = LibsqlClient.remote(url, authToken: token);
      await client.connect();
      await client.execute('''
        CREATE TABLE IF NOT EXISTS gondola_layout (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          gondola_num INTEGER NOT NULL,
          andar INTEGER NOT NULL,
          produto_codigo TEXT NOT NULL,
          produto_nome TEXT NOT NULL,
          pos_x REAL NOT NULL DEFAULT 0,
          pos_z REAL NOT NULL DEFAULT 0,
          cor_hex TEXT NOT NULL DEFAULT '#E87722',
          registrado_em TEXT NOT NULL
        )
      ''');
      await client.execute('''
        CREATE TABLE IF NOT EXISTS estante_layout (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          estante_num INTEGER NOT NULL,
          coluna INTEGER NOT NULL,
          nivel INTEGER NOT NULL,
          slot INTEGER NOT NULL,
          produto_codigo TEXT NOT NULL,
          produto_nome TEXT NOT NULL,
          cor_hex TEXT NOT NULL DEFAULT '#E87722',
          registrado_em TEXT NOT NULL
        )
      ''');
      _client    = client;
      _connected = true;
    } catch (_) {
      _connected = false;
      _client    = null;
    }
  }

  Future<List<Produto>> fetchProdutos() async {
    if (!_connected || _client == null) return [];
    try {
      // Use prepare() so the return type is consistent with fetchLayout.
      // The bare client.query() returns a different type in libsql_dart 0.9.x
      // and silently fails the cast, yielding an empty list.
      final stmt = await _client!.prepare(
        'SELECT codigo, produto, categoria FROM estoque_mestre ORDER BY produto LIMIT 5000',
      );
      final rows = await stmt.query();
      return (rows as List<dynamic>).map((dynamic row) {
        final r      = row as Map<String, dynamic>;
        final cat    = r['categoria'] as String? ?? '';
        final corHex = categoriaCores[cat] ?? '#888888';
        return Produto(
          codigo:    r['codigo']  as String? ?? '',
          nome:      r['produto'] as String? ?? '',
          categoria: cat,
          corHex:    corHex,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<CaixaLayout>> fetchLayout(int gondolaNum) async {
    if (!_connected || _client == null) return [];
    try {
      final stmt = await _client!.prepare(
        'SELECT gondola_num, andar, produto_codigo, produto_nome, pos_x, pos_z, cor_hex '
        'FROM gondola_layout WHERE gondola_num = ? ORDER BY id',
      );
      final rows = await stmt.query(positional: [gondolaNum]);
      return (rows as List<dynamic>).map((dynamic row) {
        final r = row as Map<String, dynamic>;
        return CaixaLayout(
          gondolaNum:    r['gondola_num']    as int?    ?? gondolaNum,
          andar:         r['andar']          as int?    ?? 0,
          produtoCodigo: r['produto_codigo'] as String? ?? '',
          produtoNome:   r['produto_nome']   as String? ?? '',
          posX:          (r['pos_x']  as num?)?.toDouble() ?? 0,
          posZ:          (r['pos_z']  as num?)?.toDouble() ?? 0,
          corHex:        r['cor_hex']        as String? ?? '#888888',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> salvarLayout(int gondolaNum, List<CaixaLayout> itens) async {
    if (!_connected || _client == null) return false;
    try {
      final stmtDel = await _client!.prepare(
        'DELETE FROM gondola_layout WHERE gondola_num = ?',
      );
      await stmtDel.query(positional: [gondolaNum]);

      if (itens.isNotEmpty) {
        final stmtIns = await _client!.prepare(
          'INSERT INTO gondola_layout '
          '(gondola_num, andar, produto_codigo, produto_nome, pos_x, pos_z, cor_hex, registrado_em) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        );
        final agora = DateTime.now().toIso8601String();
        for (final item in itens) {
          await stmtIns.query(positional: [
            item.gondolaNum,
            item.andar,
            item.produtoCodigo,
            item.produtoNome,
            item.posX,
            item.posZ,
            item.corHex,
            agora,
          ]);
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<CaixaLayoutEstante>> fetchLayoutEstante(int estanteNum) async {
    if (!_connected || _client == null) return [];
    try {
      final stmt = await _client!.prepare(
        'SELECT estante_num, coluna, nivel, slot, produto_codigo, produto_nome, cor_hex '
        'FROM estante_layout WHERE estante_num = ? ORDER BY id',
      );
      final rows = await stmt.query(positional: [estanteNum]);
      return (rows as List<dynamic>).map((dynamic row) {
        final r = row as Map<String, dynamic>;
        return CaixaLayoutEstante(
          estanteNum:    r['estante_num']    as int?    ?? estanteNum,
          coluna:        r['coluna']         as int?    ?? 0,
          nivel:         r['nivel']          as int?    ?? 0,
          slot:          r['slot']           as int?    ?? 0,
          produtoCodigo: r['produto_codigo'] as String? ?? '',
          produtoNome:   r['produto_nome']   as String? ?? '',
          corHex:        r['cor_hex']        as String? ?? '#888888',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> salvarLayoutEstante(
      int estanteNum, List<CaixaLayoutEstante> itens) async {
    if (!_connected || _client == null) return false;
    try {
      final stmtDel = await _client!.prepare(
        'DELETE FROM estante_layout WHERE estante_num = ?',
      );
      await stmtDel.query(positional: [estanteNum]);

      if (itens.isNotEmpty) {
        final stmtIns = await _client!.prepare(
          'INSERT INTO estante_layout '
          '(estante_num, coluna, nivel, slot, produto_codigo, produto_nome, cor_hex, registrado_em) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        );
        final agora = DateTime.now().toIso8601String();
        for (final item in itens) {
          await stmtIns.query(positional: [
            item.estanteNum,
            item.coluna,
            item.nivel,
            item.slot,
            item.produtoCodigo,
            item.produtoNome,
            item.corHex,
            agora,
          ]);
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<CaixaLayoutEstante?> buscarProdutoEstante(String produtoCodigo) async {
    if (!_connected || _client == null) return null;
    try {
      final stmt = await _client!.prepare(
        'SELECT estante_num, coluna, nivel, slot, produto_codigo, produto_nome, cor_hex '
        'FROM estante_layout WHERE produto_codigo = ? LIMIT 1',
      );
      final rows = await stmt.query(positional: [produtoCodigo]);
      final list = rows as List<dynamic>;
      if (list.isEmpty) return null;
      final r = list.first as Map<String, dynamic>;
      return CaixaLayoutEstante(
        estanteNum:    r['estante_num']    as int?    ?? 0,
        coluna:        r['coluna']         as int?    ?? 0,
        nivel:         r['nivel']          as int?    ?? 0,
        slot:          r['slot']           as int?    ?? 0,
        produtoCodigo: r['produto_codigo'] as String? ?? produtoCodigo,
        produtoNome:   r['produto_nome']   as String? ?? '',
        corHex:        r['cor_hex']        as String? ?? '#888888',
      );
    } catch (_) {
      return null;
    }
  }

  // Busca produto por nome (LIKE) em gôndola_layout E estante_layout,
  // retornando uma lista combinada ordenada por nome.
  Future<List<ProdutoEncontrado>> buscarProdutoGlobal(String termo) async {
    if (!_connected || _client == null) return [];
    final q = termo.trim();
    if (q.length < 2) return [];
    final like = '%$q%';
    final results = <ProdutoEncontrado>[];

    try {
      final stmt = await _client!.prepare(
        'SELECT DISTINCT produto_codigo, produto_nome, gondola_num, andar '
        'FROM gondola_layout WHERE produto_nome LIKE ? ORDER BY produto_nome LIMIT 20',
      );
      final rows = await stmt.query(positional: [like]);
      const andarNomes = ['Base', 'Meio', 'Topo'];
      for (final dynamic row in rows as List<dynamic>) {
        final r = row as Map<String, dynamic>;
        final a = ((r['andar'] as int?) ?? 0).clamp(0, 2);
        results.add(ProdutoEncontrado(
          nome:           r['produto_nome']   as String? ?? '',
          tipo:           'gondola',
          numero:         r['gondola_num']    as int?    ?? 0,
          nivelDescricao: 'Andar ${andarNomes[a]}',
          produtoCodigo:  r['produto_codigo'] as String? ?? '',
        ));
      }
    } catch (_) {}

    try {
      final stmt = await _client!.prepare(
        'SELECT DISTINCT produto_codigo, produto_nome, estante_num, nivel '
        'FROM estante_layout WHERE produto_nome LIKE ? ORDER BY produto_nome LIMIT 20',
      );
      final rows = await stmt.query(positional: [like]);
      const nivelNomes = ['Nível 1', 'Nível 2', 'Nível 3', 'Nível 4'];
      for (final dynamic row in rows as List<dynamic>) {
        final r = row as Map<String, dynamic>;
        final n = ((r['nivel'] as int?) ?? 0).clamp(0, 3);
        results.add(ProdutoEncontrado(
          nome:           r['produto_nome']  as String? ?? '',
          tipo:           'estante',
          numero:         r['estante_num']   as int?    ?? 0,
          nivelDescricao: nivelNomes[n],
          produtoCodigo:  r['produto_codigo'] as String? ?? '',
        ));
      }
    } catch (_) {}

    return results;
  }

  Future<CaixaLayout?> buscarProduto(String produtoCodigo) async {
    if (!_connected || _client == null) return null;
    try {
      final stmt = await _client!.prepare(
        'SELECT gondola_num, andar, produto_codigo, produto_nome, pos_x, pos_z, cor_hex '
        'FROM gondola_layout WHERE produto_codigo = ? LIMIT 1',
      );
      final rows = await stmt.query(positional: [produtoCodigo]);
      final list = rows as List<dynamic>;
      if (list.isEmpty) return null;
      final r = list.first as Map<String, dynamic>;
      return CaixaLayout(
        gondolaNum:    r['gondola_num']    as int?    ?? 0,
        andar:         r['andar']          as int?    ?? 0,
        produtoCodigo: r['produto_codigo'] as String? ?? produtoCodigo,
        produtoNome:   r['produto_nome']   as String? ?? '',
        posX:          (r['pos_x']  as num?)?.toDouble() ?? 0,
        posZ:          (r['pos_z']  as num?)?.toDouble() ?? 0,
        corHex:        r['cor_hex']        as String? ?? '#888888',
      );
    } catch (_) {
      return null;
    }
  }
}
