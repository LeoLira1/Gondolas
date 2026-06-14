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
      final rows = await _client!.query(
        'SELECT codigo, produto, categoria FROM estoque_mestre ORDER BY produto LIMIT 300',
      );
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
