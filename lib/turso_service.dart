import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier;
import 'package:libsql_dart/libsql_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class TursoService {
  static final TursoService _instance = TursoService._internal();
  factory TursoService() => _instance;
  TursoService._internal();

  static const String keyDbUrl      = 'turso_db_url';
  static const String keyDbToken    = 'turso_db_token';
  static const String keyCacheLocal = 'turso_cache_local';
  static const String keyUltimaSync = 'turso_ultima_sync';

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

  // Cache local (embedded replica com offline writes): o banco vive num
  // arquivo do dispositivo — leituras e gravações são instantâneas e
  // funcionam sem internet; sincronizar() empurra/puxa as mudanças para o
  // Turso quando o usuário pedir. Indisponível no Flutter Web (sem
  // filesystem), onde o app segue conectando direto no remoto.
  bool      _modoLocal           = false;
  bool      _sincronizando       = false;
  DateTime? _ultimaSincronizacao;
  String?   _ultimoErroSync;

  // Credenciais/modo da conexão ativa. Enquanto não mudarem, init()
  // reaproveita a conexão (e o esquema já criado) em vez de reconectar e
  // reexecutar os CREATE TABLEs a cada abertura de página.
  String? _urlAtiva;
  String? _tokenAtivo;
  bool?   _cacheLocalAtivo;
  Future<void>? _initEmAndamento;

  // Cache do catálogo (estoque_mestre): evita repetir o SELECT de até 5000
  // linhas toda vez que uma página abre.
  List<Produto>? _produtosCache;
  DateTime?      _produtosCacheEm;
  static const Duration _produtosCacheTtl = Duration(minutes: 5);

  bool get isConnected => _connected;

  /// Incrementa a cada sincronização bem-sucedida (carga inicial em segundo
  /// plano ou botão Sincronizar). As páginas ouvem para recarregar a cena
  /// assim que dados novos chegam, sem travar a abertura.
  final ValueNotifier<int> dataRevision = ValueNotifier<int>(0);

  /// True quando a conexão ativa usa o cache local (arquivo no dispositivo).
  bool get modoLocal => _modoLocal;

  bool get sincronizando => _sincronizando;

  DateTime? get ultimaSincronizacao => _ultimaSincronizacao;

  /// Descrição curta (para o usuário) do motivo da última falha de
  /// sincronização, ou null se a última tentativa deu certo.
  String? get ultimoErroSync => _ultimoErroSync;

  // Acessor para serviços satélite (ex: EstoqueLocalizadoService) reaproveitarem
  // esta mesma conexão, em vez de abrir uma segunda.
  LibsqlClient? get client => _client;

  Future<bool> garantirConexao() => _garantirConexao();

  // Serializa os inits em vez de "pegar carona" no que está no ar: se um
  // init antigo ainda roda com preferências velhas (ex: usuário acabou de
  // desligar o cache local), o próximo espera e roda em seguida, aplicando
  // as novas. A checagem de reaproveitamento no _init torna repetições
  // baratas (early-return quando nada mudou).
  Future<void> init() {
    final anterior = _initEmAndamento ?? Future<void>.value();
    final novo = anterior.catchError((_) {}).then<void>((_) => _init());
    _initEmAndamento = novo;
    return novo;
  }

  Future<void> _init() async {
    final prefs      = await SharedPreferences.getInstance();
    final url        = prefs.getString(keyDbUrl)   ?? '';
    final token      = prefs.getString(keyDbToken) ?? '';
    final cacheLocal = !kIsWeb && (prefs.getBool(keyCacheLocal) ?? true);

    final ultimaSyncIso = prefs.getString(keyUltimaSync);
    _ultimaSincronizacao =
        ultimaSyncIso != null ? DateTime.tryParse(ultimaSyncIso) : null;

    if (_connected &&
        _client != null &&
        url == _urlAtiva &&
        token == _tokenAtivo &&
        cacheLocal == _cacheLocalAtivo) {
      return;
    }

    final clienteAntigo = _client;

    _connected       = false;
    _client          = null;
    _urlAtiva        = null;
    _tokenAtivo      = null;
    _cacheLocalAtivo = null;
    _modoLocal       = false;
    _produtosCache   = null;
    _produtosCacheEm = null;

    if (clienteAntigo != null) {
      // Solta a conexão anterior (troca de credenciais ou de modo) sem
      // segurar o init novo.
      unawaited(clienteAntigo.dispose().catchError((_) {}));
    }

    if (url.isEmpty || token.isEmpty) return;

    LibsqlClient? client;
    var conectouLocal = false;

    if (cacheLocal) {
      client        = await _conectarComCacheLocal(url, token);
      conectouLocal = client != null;
    }
    // Sem cache local (Web, preferência desligada ou falha ao abrir o
    // arquivo): conexão direta ao remoto, como antes.
    client ??= await _conectarRemoto(url, token);
    if (client == null) return;

    try {
      if (conectouLocal) {
        // Replica local recém-criada (arquivo ainda vazio): NÃO cria o esquema
        // localmente antes do primeiro sync — escrever numa replica nova antes
        // de estabelecer a base do remoto gera conflito de frame
        // (InvalidPushFrameConflict). Marca conectado já (leitura local
        // instantânea, sem depender da rede) e baixa a base em segundo plano;
        // quando chega, dataRevision recarrega a cena. Se o arquivo já tem
        // dados, aplica o esquema idempotente (inclui os índices) e a migração
        // normalmente.
        final vazio = await _bancoLocalVazio(client);
        if (!vazio) {
          await _criarEsquema(client);
          await _migrarEsquemaLabelsEstante3(client);
        }
        _client          = client;
        _connected       = true;
        _modoLocal       = true;
        _urlAtiva        = url;
        _tokenAtivo      = token;
        _cacheLocalAtivo = cacheLocal;
        if (vazio) unawaited(_bootstrapEmBackground());
      } else {
        // Modo remoto (Web ou falha ao abrir o arquivo local): cria o esquema
        // e conecta direto ao remoto, como antes.
        await _criarEsquema(client);
        await _migrarEsquemaLabelsEstante3(client);
        _client          = client;
        _connected       = true;
        _modoLocal       = false;
        _urlAtiva        = url;
        _tokenAtivo      = token;
        _cacheLocalAtivo = cacheLocal;
      }
    } catch (_) {
      _connected = false;
      _client    = null;
    }
  }

  // Limites de tempo: nenhuma etapa de conexão/sincronização pode segurar o
  // app indefinidamente — estourou, cai no fallback (remoto) ou falha o botão
  // de sincronizar com aviso, mantendo os dados locais intactos.
  static const Duration _timeoutConexao   = Duration(seconds: 20);
  static const Duration _timeoutBootstrap = Duration(seconds: 90);
  static const Duration _timeoutSync      = Duration(minutes: 3);

  Future<String> _caminhoCacheLocal() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/camda_gondolas_cache.db';
  }

  Future<LibsqlClient?> _conectarComCacheLocal(String url, String token) async {
    LibsqlClient? client;
    try {
      final path = await _caminhoCacheLocal();
      client = LibsqlClient.offline(path, syncUrl: url, authToken: token);
      await client.connect().timeout(_timeoutConexao);
      // Local-first: nunca bloqueia na rede aqui. Abrir o app usa só o arquivo
      // local (instantâneo). A carga inicial — quando o arquivo ainda está
      // vazio — é disparada em segundo plano por _init (via _bootstrapEm-
      // Background), e a rede volta a entrar só quando o usuário toca em
      // Sincronizar. Assim o app não trava esperando o sync e as leituras
      // funcionam mesmo com internet ruim, sem cair pro modo remoto.
      return client;
    } catch (_) {
      if (client != null) {
        unawaited(client.dispose().catchError((_) {}));
      }
      return null;
    }
  }

  // Carga inicial da replica local (primeira execução): estabelece a base a
  // partir do remoto SEM travar a abertura do app. Só depois que a base chega é
  // que o esquema idempotente (com os índices) e a migração são aplicados —
  // escrever antes do primeiro sync geraria conflito de frame. Ao concluir,
  // avisa a UI por dataRevision. Se falhar (sem internet), não cai pro modo
  // remoto nem trava: tenta de novo na próxima abertura.
  Future<void> _bootstrapEmBackground() async {
    final client = _client;
    if (client == null) return;
    try {
      await client.sync().timeout(_timeoutBootstrap);
      await _criarEsquema(client);
      await _migrarEsquemaLabelsEstante3(client);
      _produtosCache   = null;
      _produtosCacheEm = null;
      await _registrarSincronizacao();
      _ultimoErroSync  = null;
      dataRevision.value++;
    } catch (e) {
      _ultimoErroSync = _descreverErroSync(e);
    }
  }

  /// True se o arquivo local acabou de ser criado (nenhuma tabela ainda).
  Future<bool> _bancoLocalVazio(LibsqlClient client) async {
    try {
      final stmt = await client.prepare(
        "SELECT count(*) AS n FROM sqlite_master WHERE type = 'table'",
      );
      final rows = await stmt.query() as List<dynamic>;
      final n = (rows.first as Map<String, dynamic>)['n'] as int? ?? 0;
      return n == 0;
    } catch (_) {
      // Na dúvida, não força bootstrap — o esquema local é criado logo em
      // seguida e a carga completa acontece no primeiro Sincronizar.
      return false;
    }
  }

  Future<LibsqlClient?> _conectarRemoto(String url, String token) async {
    try {
      final client = LibsqlClient.remote(url, authToken: token);
      await client.connect().timeout(_timeoutConexao);
      return client;
    } catch (_) {
      return null;
    }
  }

  Future<void> _criarEsquema(LibsqlClient client) async {
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
    await client.execute('''
      CREATE TABLE IF NOT EXISTS app_migrations (
        nome TEXT PRIMARY KEY,
        aplicada_em TEXT NOT NULL
      )
    ''');
    // Quantidade de cada produto por endereço físico (gôndola ou estante).
    // Chave por endereço lógico — não referencia gondola_layout.id/estante_layout.id
    // porque salvarLayout/salvarLayoutEstante são destrutivos (DELETE + INSERT).
    await client.execute('''
      CREATE TABLE IF NOT EXISTS estoque_localizado (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        produto_codigo TEXT NOT NULL,
        local_tipo TEXT NOT NULL,
        local_num  INTEGER NOT NULL,
        face_ou_coluna INTEGER NOT NULL,
        andar_ou_nivel INTEGER NOT NULL,
        quantidade REAL NOT NULL DEFAULT 0,
        atualizado_em TEXT NOT NULL,
        UNIQUE(produto_codigo, local_tipo, local_num, face_ou_coluna, andar_ou_nivel)
      )
    ''');
    await client.execute('''
      CREATE TABLE IF NOT EXISTS contagens_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        produto_codigo TEXT NOT NULL,
        endereco TEXT NOT NULL,
        qtd_anterior REAL,
        qtd_nova REAL NOT NULL,
        origem TEXT NOT NULL DEFAULT 'gondolas_app',
        registrado_em TEXT NOT NULL
      )
    ''');
    // Índices das buscas mais quentes (só tabelas do próprio app): evitam full
    // scan em fetchLayout / fetchLayoutEstante / buscarProdutoEstante e na
    // busca global. IF NOT EXISTS torna idempotente; estoque_localizado já tem
    // o índice implícito do seu UNIQUE(produto_codigo, ...).
    await client.execute(
      'CREATE INDEX IF NOT EXISTS idx_gondola_layout_num '
      'ON gondola_layout (gondola_num)',
    );
    await client.execute(
      'CREATE INDEX IF NOT EXISTS idx_estante_layout_num '
      'ON estante_layout (estante_num)',
    );
    await client.execute(
      'CREATE INDEX IF NOT EXISTS idx_estante_layout_produto '
      'ON estante_layout (produto_codigo)',
    );
  }

  Future<void> _registrarSincronizacao() async {
    _ultimaSincronizacao = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        keyUltimaSync, _ultimaSincronizacao!.toIso8601String());
  }

  /// Sincroniza o cache local com o banco online: envia as gravações feitas
  /// no dispositivo e baixa as novidades do Turso. Retorna false quando não
  /// há conexão configurada ou a sincronização falhou (ex: sem internet) —
  /// nesse caso os dados locais ficam intactos e dá pra tentar de novo.
  /// No modo remoto (sem cache local) não há o que empurrar: só renova o
  /// cache do catálogo em memória.
  Future<bool> sincronizar() async {
    if (_sincronizando) {
      _ultimoErroSync = 'já existe uma sincronização em andamento';
      return false;
    }
    if (!await _garantirConexao()) {
      final prefs = await SharedPreferences.getInstance();
      final configurado = (prefs.getString(keyDbUrl) ?? '').isNotEmpty &&
          (prefs.getString(keyDbToken) ?? '').isNotEmpty;
      _ultimoErroSync = configurado
          ? 'sem conexão com o banco — verifique a internet'
          : 'configure URL e token do banco em ⚙️';
      return false;
    }
    _sincronizando = true;
    try {
      if (_modoLocal) await _client!.sync().timeout(_timeoutSync);
      _produtosCache   = null;
      _produtosCacheEm = null;
      await _registrarSincronizacao();
      _ultimoErroSync = null;
      dataRevision.value++;
      return true;
    } catch (e) {
      _ultimoErroSync = _descreverErroSync(e);
      return false;
    } finally {
      _sincronizando = false;
    }
  }

  /// Traduz a exceção do sync numa dica curta e acionável — a causa real
  /// (token expirado ≠ sem internet ≠ demora da rede) muda o que o usuário
  /// precisa fazer para resolver.
  String _descreverErroSync(Object e) {
    if (e is TimeoutException) {
      return 'a rede demorou demais para responder — tente novamente';
    }
    final msg   = e.toString().replaceAll('\n', ' ').trim();
    final lower = msg.toLowerCase();
    if (lower.contains('401') ||
        lower.contains('unauthorized') ||
        lower.contains('forbidden') ||
        lower.contains('auth')) {
      return 'token inválido ou expirado — confira em ⚙️';
    }
    if (lower.contains('dns') ||
        lower.contains('socket') ||
        lower.contains('network') ||
        lower.contains('connection refused') ||
        lower.contains('failed to connect') ||
        lower.contains('timed out')) {
      return 'sem conexão com o banco — verifique a internet';
    }
    return msg.length > 140 ? '${msg.substring(0, 140)}…' : msg;
  }

  /// Apaga o arquivo de cache local (embedded replica) e reseta a conexão,
  /// forçando o próximo init() a rebaixar tudo do zero do Turso. É a única
  /// saída quando o replica local diverge do remoto de um jeito que o push
  /// não consegue mais reconciliar sozinho (ex: InvalidPushFrameConflict) —
  /// gravações feitas offline e ainda não sincronizadas são perdidas.
  Future<bool> limparCacheLocal() async {
    final clienteAntigo = _client;

    _connected       = false;
    _client          = null;
    _urlAtiva        = null;
    _tokenAtivo      = null;
    _cacheLocalAtivo = null;
    _modoLocal       = false;
    _produtosCache   = null;
    _produtosCacheEm = null;
    _ultimoErroSync  = null;

    if (clienteAntigo != null) {
      try {
        await clienteAntigo.dispose();
      } catch (_) {}
    }

    try {
      final base = await _caminhoCacheLocal();
      for (final sufixo in ['', '-wal', '-shm', '-journal']) {
        final arquivo = File('$base$sufixo');
        if (await arquivo.exists()) await arquivo.delete();
      }
    } catch (_) {
      return false;
    }

    _ultimaSincronizacao = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyUltimaSync);

    return true;
  }

  // Garante que existe conexão antes de uma query: se o init() disparado na
  // abertura do app ainda não terminou (ou falhou), espera/tenta de novo em
  // vez de devolver resultado vazio silenciosamente.
  Future<bool> _garantirConexao() async {
    if (_connected && _client != null) return true;
    await init();
    return _connected && _client != null;
  }

  // Estante 3 ganhou um novo nível (o antigo topo virou o penúltimo nível, e
  // um novo nível de base foi adicionado), para comportar o novo esquema de
  // labels A-O (15 posições) em vez do antigo A-L (12 posições). Os produtos
  // já cadastrados precisam ter o `nivel` deslocado em +1 para continuarem
  // apontando para a mesma prateleira física — e, por consequência, para a
  // mesma letra de antes. Roda uma única vez, controlada por app_migrations.
  static const String _migracaoEstante3 =
      'estante3_esquema_labels_estendido_a_o';

  Future<void> _migrarEsquemaLabelsEstante3(LibsqlClient client) async {
    try {
      final stmtCheck = await client.prepare(
        'SELECT 1 FROM app_migrations WHERE nome = ? LIMIT 1',
      );
      final jaAplicada =
          (await stmtCheck.query(positional: [_migracaoEstante3]))
              as List<dynamic>;
      if (jaAplicada.isNotEmpty) return;

      final stmtUpdate = await client.prepare(
        'UPDATE estante_layout SET nivel = nivel + 1 WHERE estante_num = 3',
      );
      await stmtUpdate.query();

      final stmtInsert = await client.prepare(
        'INSERT INTO app_migrations (nome, aplicada_em) VALUES (?, ?)',
      );
      await stmtInsert.query(positional: [
        _migracaoEstante3,
        DateTime.now().toIso8601String(),
      ]);
    } catch (_) {
      // Se a migração falhar, não derruba a conexão — só tenta de novo no
      // próximo init().
    }
  }

  Future<List<Produto>> fetchProdutos({bool forceRefresh = false}) async {
    if (!await _garantirConexao()) return [];

    final cache = _produtosCache;
    final cacheEm = _produtosCacheEm;
    if (!forceRefresh &&
        cache != null &&
        cacheEm != null &&
        DateTime.now().difference(cacheEm) < _produtosCacheTtl) {
      return cache;
    }

    try {
      // Use prepare() so the return type is consistent with fetchLayout.
      // The bare client.query() returns a different type in libsql_dart 0.9.x
      // and silently fails the cast, yielding an empty list.
      final stmt = await _client!.prepare(
        'SELECT codigo, produto, categoria FROM estoque_mestre ORDER BY produto LIMIT 5000',
      );
      final rows = await stmt.query();
      final produtos = (rows as List<dynamic>).map((dynamic row) {
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
      _produtosCache   = produtos;
      _produtosCacheEm = DateTime.now();
      return produtos;
    } catch (_) {
      return cache ?? [];
    }
  }

  Future<List<CaixaLayout>> fetchLayout(int gondolaNum) async {
    if (!await _garantirConexao()) return [];
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

  // Máximo de linhas por INSERT multi-linha: 8 parâmetros por linha mantém o
  // statement bem abaixo do limite de variáveis do SQLite (999).
  static const int _maxLinhasPorInsert = 100;

  // Lista das estantes removidas (ex.: '3, 4') para cláusulas NOT IN — só
  // constantes inteiras de models.dart, nunca entrada do usuário.
  static final String _sqlEstantesRemovidas = estantesRemovidas.join(', ');

  // A base do Expositor Nellore (nível 0) saiu dos endereços — a estante
  // real não tem essa prateleira. Linhas antigas dela são ignoradas na
  // carga e nas buscas (só constantes de models.dart, nunca entrada do
  // usuário); um "Salvar layout" na estante 19 as apaga de vez.
  static final String _sqlSemBaseNellore =
      'NOT (estante_num = $expositorNelloreNum AND nivel = 0)';

  static bool _ehBaseNelloreRemovida(int estanteNum, int nivel) =>
      estanteNum == expositorNelloreNum && nivel == 0;

  Future<bool> salvarLayout(int gondolaNum, List<CaixaLayout> itens) async {
    if (!await _garantirConexao()) return false;
    try {
      final stmtDel = await _client!.prepare(
        'DELETE FROM gondola_layout WHERE gondola_num = ?',
      );
      await stmtDel.query(positional: [gondolaNum]);

      // INSERT multi-linha: uma ida ao servidor por lote em vez de uma por
      // caixa. Além de rápido, encurta a janela em que uma queda de rede
      // deixaria o layout salvo pela metade após o DELETE acima.
      final agora = DateTime.now().toIso8601String();
      for (var i = 0; i < itens.length; i += _maxLinhasPorInsert) {
        final fim = (i + _maxLinhasPorInsert < itens.length)
            ? i + _maxLinhasPorInsert
            : itens.length;
        final lote = itens.sublist(i, fim);
        final stmtIns = await _client!.prepare(
          'INSERT INTO gondola_layout '
          '(gondola_num, andar, produto_codigo, produto_nome, pos_x, pos_z, cor_hex, registrado_em) '
          'VALUES ${List.filled(lote.length, '(?, ?, ?, ?, ?, ?, ?, ?)').join(', ')}',
        );
        final params = <dynamic>[];
        for (final item in lote) {
          params.addAll([
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
        await stmtIns.query(positional: params);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<CaixaLayoutEstante>> fetchLayoutEstante(int estanteNum) async {
    if (!await _garantirConexao()) return [];
    try {
      final stmt = await _client!.prepare(
        'SELECT estante_num, coluna, nivel, slot, produto_codigo, produto_nome, cor_hex '
        'FROM estante_layout WHERE estante_num = ? ORDER BY id',
      );
      final rows = await stmt.query(positional: [estanteNum]);
      return (rows as List<dynamic>)
          .map((dynamic row) {
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
          })
          .where((c) => !_ehBaseNelloreRemovida(c.estanteNum, c.nivel))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> salvarLayoutEstante(
      int estanteNum, List<CaixaLayoutEstante> itens) async {
    if (!await _garantirConexao()) return false;
    try {
      final stmtDel = await _client!.prepare(
        'DELETE FROM estante_layout WHERE estante_num = ?',
      );
      await stmtDel.query(positional: [estanteNum]);

      final agora = DateTime.now().toIso8601String();
      for (var i = 0; i < itens.length; i += _maxLinhasPorInsert) {
        final fim = (i + _maxLinhasPorInsert < itens.length)
            ? i + _maxLinhasPorInsert
            : itens.length;
        final lote = itens.sublist(i, fim);
        final stmtIns = await _client!.prepare(
          'INSERT INTO estante_layout '
          '(estante_num, coluna, nivel, slot, produto_codigo, produto_nome, cor_hex, registrado_em) '
          'VALUES ${List.filled(lote.length, '(?, ?, ?, ?, ?, ?, ?, ?)').join(', ')}',
        );
        final params = <dynamic>[];
        for (final item in lote) {
          params.addAll([
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
        await stmtIns.query(positional: params);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<CaixaLayoutEstante?> buscarProdutoEstante(String produtoCodigo) async {
    if (!await _garantirConexao()) return null;
    try {
      final stmt = await _client!.prepare(
        'SELECT estante_num, coluna, nivel, slot, produto_codigo, produto_nome, cor_hex '
        'FROM estante_layout WHERE produto_codigo = ? '
        'AND estante_num NOT IN ($_sqlEstantesRemovidas) '
        'AND $_sqlSemBaseNellore LIMIT 1',
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
  // retornando uma lista combinada (gôndolas primeiro).
  Future<List<ProdutoEncontrado>> buscarProdutoGlobal(String termo) async {
    if (!await _garantirConexao()) return [];
    final q = termo.trim();
    if (q.length < 2) return [];
    final like = '%$q%';

    final resultados = await Future.wait([
      _buscarNasGondolas(like),
      _buscarNasEstantes(like),
    ]);
    return _anexarQuantidades([...resultados[0], ...resultados[1]]);
  }

  /// Anexa a cada resultado a quantidade contada (estoque_localizado) no seu
  /// local: gôndola casa pelo endereço exato (face + andar); estante soma as
  /// colunas do nível, já que a busca agrupa por estante + nível.
  Future<List<ProdutoEncontrado>> _anexarQuantidades(
      List<ProdutoEncontrado> encontrados) async {
    if (encontrados.isEmpty) return encontrados;
    final codigos = encontrados
        .map((p) => p.produtoCodigo)
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();
    if (codigos.isEmpty) return encontrados;
    try {
      final placeholders = List.filled(codigos.length, '?').join(',');
      final stmt = await _client!.prepare(
        'SELECT produto_codigo, local_tipo, local_num, face_ou_coluna, andar_ou_nivel, quantidade '
        'FROM estoque_localizado WHERE produto_codigo IN ($placeholders)',
      );
      final rows = await stmt.query(positional: codigos);

      // gôndola: 'g|codigo|num|face|andar' · estante: 'e|codigo|num|nivel'
      final somas = <String, double>{};
      for (final dynamic row in rows as List<dynamic>) {
        final r        = row as Map<String, dynamic>;
        final codigo   = r['produto_codigo'] as String? ?? '';
        final tipo     = r['local_tipo']     as String? ?? '';
        final localNum = r['local_num']      as int?    ?? 0;
        final fc       = r['face_ou_coluna'] as int?    ?? 0;
        final an       = r['andar_ou_nivel'] as int?    ?? 0;
        final qtd      = (r['quantidade'] as num?)?.toDouble() ?? 0;
        // Estante: mesmo clamp de nível usado em _buscarNasEstantes, pra
        // chave casar com o resultado exibido.
        final chave = tipo == 'gondola'
            ? 'g|$codigo|$localNum|$fc|$an'
            : 'e|$codigo|$localNum|${an.clamp(0, niveisProdutoPara(localNum) - 1)}';
        somas[chave] = (somas[chave] ?? 0) + qtd;
      }

      return encontrados.map((p) {
        final chave = p.tipo == 'gondola'
            ? 'g|${p.produtoCodigo}|${p.numero}|${p.face}|${p.andar}'
            : 'e|${p.produtoCodigo}|${p.numero}|${p.nivel}';
        return p.comQuantidade(somas[chave]);
      }).toList();
    } catch (_) {
      return encontrados; // sem quantidade não é motivo pra falhar a busca
    }
  }

  Future<List<ProdutoEncontrado>> _buscarNasGondolas(String like) async {
    try {
      final stmt = await _client!.prepare(
        'SELECT DISTINCT produto_codigo, produto_nome, gondola_num, andar, pos_x, pos_z '
        'FROM gondola_layout WHERE produto_nome LIKE ? OR produto_codigo LIKE ? '
        'ORDER BY produto_nome LIMIT 20',
      );
      final rows = await stmt.query(positional: [like, like]);
      const andarNomes = ['Base', 'Meio', 'Topo'];
      // A face é derivada de pos_x/pos_z (sem coluna no banco); caixas do
      // mesmo produto no mesmo endereço G·F·A viram um resultado só.
      final vistos     = <String>{};
      final encontrados = <ProdutoEncontrado>[];
      for (final dynamic row in rows as List<dynamic>) {
        final r    = row as Map<String, dynamic>;
        final a    = ((r['andar'] as int?) ?? 0).clamp(0, 2);
        final posX = (r['pos_x'] as num?)?.toDouble() ?? 0;
        final posZ = (r['pos_z'] as num?)?.toDouble() ?? 0;
        final face = faceFromPos(posX, posZ);
        final codigo  = r['produto_codigo'] as String? ?? '';
        final gondola = r['gondola_num']    as int?    ?? 0;
        if (!vistos.add('$codigo|$gondola|$a|$face')) continue;
        encontrados.add(ProdutoEncontrado(
          nome:           r['produto_nome'] as String? ?? '',
          tipo:           'gondola',
          numero:         gondola,
          nivelDescricao: 'Face $face · Andar ${andarNomes[a]}',
          produtoCodigo:  codigo,
          face:           face,
          andar:          a,
        ));
      }
      return encontrados;
    } catch (_) {
      return [];
    }
  }

  Future<List<ProdutoEncontrado>> _buscarNasEstantes(String like) async {
    try {
      final stmt = await _client!.prepare(
        'SELECT DISTINCT produto_codigo, produto_nome, estante_num, nivel '
        'FROM estante_layout WHERE (produto_nome LIKE ? OR produto_codigo LIKE ?) '
        'AND estante_num NOT IN ($_sqlEstantesRemovidas) '
        'AND $_sqlSemBaseNellore '
        'ORDER BY produto_nome LIMIT 20',
      );
      final rows = await stmt.query(positional: [like, like]);
      return (rows as List<dynamic>).map((dynamic row) {
        final r          = row as Map<String, dynamic>;
        final estanteNum = r['estante_num'] as int? ?? 0;
        final nivProduto = niveisProdutoPara(estanteNum);
        final n = ((r['nivel'] as int?) ?? 0).clamp(0, nivProduto - 1);
        return ProdutoEncontrado(
          nome:           r['produto_nome']   as String? ?? '',
          tipo:           'estante',
          numero:         estanteNum,
          nivelDescricao: 'Nível ${n + 1}',
          produtoCodigo:  r['produto_codigo'] as String? ?? '',
          nivel:          n,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<CaixaLayout?> buscarProduto(String produtoCodigo) async {
    if (!await _garantirConexao()) return null;
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
