import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, ValueNotifier, debugPrint;
import 'package:libsql_dart/libsql_dart.dart';
// `Transaction` não é reexportado pelo libsql_dart.dart, e carimbarMutacao
// precisa nomear o tipo: o carimbo do UUID tem de entrar na MESMA transação da
// mutação, então ele recebe a transação de quem está gravando. Caminho interno,
// versão fixada no pubspec.lock.
import 'package:libsql_dart/src/transaction.dart' show Transaction;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'barracao_layout_migration.dart';
import 'galpao_config.dart';
import 'galpao_migracao_unidades.dart';
import 'gravacao_lote.dart';
import 'layouts_copia.dart';
import 'leituras_turso.dart';
import 'consulta_cache.dart';
import 'badges_estoque.dart';
import 'busca_local.dart';
import 'codigos_vinculados.dart' show normalizarCodigo;
import 'models.dart';
import 'palete_registry.dart';
import 'replica_local.dart';
import 'replica_coordinator.dart';
import 'outbox.dart';
import 'rack_identity.dart';
import 'outbox_store.dart';

/// Cronometra uma etapa de banco e imprime o tempo no log, só em debug.
///
/// As otimizações de carregamento (cache de layout, catálogo fora do caminho
/// crítico, prewarm) só dá para conferir com número na mão — "parece mais
/// rápido" foi exatamente o que não se conseguiu afirmar do cache local.
/// Em release o `if (kDebugMode)` é constante e o compilador remove o ramo.
Future<T> cronometrar<T>(String etiqueta, Future<T> Function() acao) async {
  if (!kDebugMode) return acao();
  final relogio = Stopwatch()..start();
  try {
    return await acao();
  } finally {
    relogio.stop();
    debugPrint('[turso] $etiqueta: ${relogio.elapsedMilliseconds}ms');
  }
}

class TursoService {
  static final TursoService _instance = TursoService._internal();
  factory TursoService() => _instance;
  TursoService._internal();

  static const String keyDbUrl = 'turso_db_url';
  static const String keyDbToken = 'turso_db_token';
  /// A antiga chave "Cache de consulta" de ⚙️ (removida): desligada, cada
  /// toque relia tabelas inteiras. Só fica o nome, para apagar a preferência
  /// dos aparelhos que a tinham.
  static const String keyCacheLocal = 'turso_cache_local';
  static const String keyUltimaSync = 'turso_ultima_sync';
  // Marca que a replica local ATUAL já puxou a base do remoto. Some junto com
  // os arquivos da replica (ver _apagarArquivosDaReplica), então nunca fica
  // valendo para um arquivo novo.
  static const String keyBaseLocalOk = 'turso_base_local_ok';
  // Quantas gravações locais já foram confirmadas no arquivo da replica e
  // ainda não subiram para o Turso. Persistida porque o app pode ser fechado
  // entre a gravação e o Sincronizar — e é ela que distingue "não havia
  // novidade" de "o envio não saiu" quando o sync volta calado (ver
  // avaliarSync em replica_local.dart).
  static const String keyGravacoesPendentes = 'turso_gravacoes_pendentes';
  // Marca que a replica local DESTE banco divergiu do servidor e só volta a
  // aceitar gravação depois de uma recuperação explícita. Persistida porque a
  // divergência não se cura sozinha: o servidor recusa os frames locais para
  // sempre, então reabrir o app não pode ser o bastante para o portão de
  // escrita reabrir. Sai só em _apagarArquivosDaReplica — quando o arquivo
  // divergente deixa de existir, não há mais o que recuperar.
  static const String keyRecuperacaoNecessaria = 'turso_recuperacao_necessaria';
  // Identidade (hash da URL) do banco cujas chaves acima estão em uso.
  static const String keyIdentidadeAtiva = 'turso_identidade_ativa';
  // Identificador sorteado deste aparelho. Serve para a revisão manual dizer de
  // onde veio a mutação em conflito; não identifica pessoa nenhuma.
  static const String keyDispositivo = 'turso_dispositivo';

  static const Map<String, String> categoriaCores = {
    'Lubrificantes': '#2e7d4f',
    'Calçados': '#2c5fb0',
    'Vestuário': '#6b4a2b',
    'Chapéus': '#d9b46a',
    'Lonas': '#e87722',
    'Defensivos': '#8b1a1a',
    'Sementes': '#c8a000',
    'Ferramentas': '#4a4a8a',
  };

  LibsqlClient? _client;
  bool _connected = false;
  // Conexão direta ao remoto usada só para saber se há rede (ver
  // _remotoAlcancavel). Nunca serve leitura nem escrita do app.
  LibsqlClient? _sonda;

  // Cache local (embedded replica com offline writes): o banco vive num
  // arquivo do dispositivo — leituras e gravações são instantâneas e
  // funcionam sem internet; sincronizar() empurra/puxa as mudanças para o
  // Turso quando o usuário pedir. Indisponível no Flutter Web (sem
  // filesystem), onde o app segue conectando direto no remoto.
  bool _modoLocal = false;
  bool _sincronizando = false;
  // True enquanto a replica local ainda não puxou (pull) os frames que o
  // servidor já tem. Nesse estado NADA pode ser escrito no arquivo local: os
  // frames locais sairiam na frente dos do servidor e o push passaria a falhar
  // para sempre com InvalidPushFrameConflict. Ver _estabelecerBaseLocal.
  bool _basePendente = false;
  DateTime? _ultimaSincronizacao;
  String? _ultimoErroSync;
  String? _ultimoAvisoSync;
  int _gravacoesPendentes = 0;
  int _enviadasNoUltimoSync = 0;
  final CoordenadorReplica _coordenador = CoordenadorReplica();
  String? _identidadeAtiva;
  // Sync nativo do libsql em andamento. Existe porque `Future.timeout` NÃO
  // cancela nada: quando o prazo do chamador estoura, o controle volta mas o
  // sync continua falando com o servidor a partir do mesmo arquivo — e o
  // mutex do coordenador já foi liberado. Toda chamada ao sync nativo e toda
  // escrita admitida passam por aqui para nunca rodar por baixo dele.
  Future<void>? _syncNativoEmAndamento;
  final OutboxStore _outbox = OutboxStore();
  // Identificador deste aparelho, para a tela de revisão dizer de ONDE veio a
  // mutação em conflito. Sorteado uma vez e guardado; não identifica pessoa.
  String? _dispositivo;

  String _chavePorBanco(String base) =>
      _identidadeAtiva == null ? base : '${base}_${_identidadeAtiva!}';

  // Credenciais/modo da conexão ativa. Enquanto não mudarem, init()
  // reaproveita a conexão (e o esquema já criado) em vez de reconectar e
  // reexecutar os CREATE TABLEs a cada abertura de página.
  String? _urlAtiva;
  String? _tokenAtivo;
  Future<void>? _initEmAndamento;
  bool _forcarReconexao = false;

  // Cache do catálogo (estoque_mestre): evita repetir o SELECT de até 5000
  // linhas toda vez que uma página abre. No modo local o TTL é ignorado (ver
  // fetchProdutos): a base do dispositivo só muda em sincronizar() /
  // _estabelecerBaseLocal, e os dois já zeram este cache — o relógio ali só
  // garantia uma reconsulta inútil em toda sessão longa. O TTL continua valendo
  // no modo remoto, onde um app irmão pode mexer no estoque_mestre por fora.
  List<Produto>? _produtosCache;
  DateTime? _produtosCacheEm;
  static const Duration _produtosCacheTtl = Duration(minutes: 30);
  // Leitura do catálogo em andamento, para que chamadas simultâneas dividam a
  // mesma consulta em vez de disparar uma cada (ver fetchProdutos).
  Future<List<Produto>>? _catalogoEmAndamento;
  // True depois que o catálogo veio do BANCO nesta sessão. É o que impede a
  // cópia em disco de ser servida no lugar de dados recém-sincronizados —
  // ver _lerCatalogo.
  bool _catalogoLidoDoBanco = false;
  // URL configurada em ⚙️, guardada mesmo quando a conexão falha. Carimba o
  // catálogo em disco: sem ela, o fallback offline (onde _urlAtiva é null por
  // não ter conectado) nunca reconheceria a própria cópia.
  String? _urlConfigurada;
  // Formato do arquivo do catálogo em disco. Sobe se as colunas mudarem: uma
  // cópia de formato antigo é ignorada em vez de mal interpretada.
  static const int _versaoCatalogoEmDisco = 1;

  // Os layouts por estrutura, servidos da cópia completa de cada tabela (ver
  // layouts_copia.dart): a busca, o prewarm e a cena leem a mesma cópia, e
  // abrir uma estrutura relê só ela, pelo índice do número.
  late final LayoutsDaCopia _layoutsGondola = _layoutsDe(
    chave: chaveLayoutsGondola,
    coluna: 'gondola_num',
    sqlEstrutura:
        'SELECT $_colunasLayoutGondola FROM gondola_layout '
        'WHERE gondola_num = ? ORDER BY id',
  );
  late final LayoutsDaCopia _layoutsEstante = _layoutsDe(
    chave: chaveLayoutsEstante,
    coluna: 'estante_num',
    sqlEstrutura:
        'SELECT $_colunasLayoutEstante FROM estante_layout '
        'WHERE estante_num = ? ORDER BY id',
  );

  LayoutsDaCopia _layoutsDe({
    required String chave,
    required String coluna,
    required String sqlEstrutura,
  }) => LayoutsDaCopia(
    coluna: coluna,
    janelaEstrutura: ConsultaCache.janelaPadrao,
    lerEstrutura: (numero) async {
      // Sem banco configurado (dados de exemplo): estrutura vazia e editável,
      // como sempre foi — não é "sem rede".
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString(keyDbUrl) ?? '').isEmpty) return [];
      return consultarDireto(
        sqlEstrutura,
        parametros: [numero],
        tipo: 'layout_estrutura',
      );
    },
    corrigirCopia: (pertence, novas, {required deGravacao}) =>
        corrigirConsulta(chave, pertence, novas, descartarNoAr: deGravacao),
    copiaEmMemoria: () {
      final completa = _chaveCompleta(chave);
      return completa == null ? null : _consultaCache.emMemoria(completa);
    },
    carregarCopia: () async {
      final completa = _chaveCompleta(chave);
      return completa != null && await _consultaCache.carregar(completa);
    },
    copiaVencida: (janela) => consultaVencida(chave, janela),
  );

  late final ConsultaCache _consultaCache = ConsultaCache(
    lerDisco: (key) async =>
        (await SharedPreferences.getInstance()).getString(key),
    gravarDisco: (key, value) async {
      if (!await (await SharedPreferences.getInstance()).setString(
        key,
        value,
      )) {
        throw StateError('Cache não foi persistido');
      }
    },
    aoAtualizar: _avisarEmBreve,
  );

  // Releituras em segundo plano que trouxeram dado novo avisam as telas por
  // dataRevision. Uma volta ao app ou um Sincronizar relê várias consultas de
  // uma vez, e cada uma que mudou avisava por conta própria: k avisos, k
  // recargas de cada tela aberta. Um respiro curto junta a rajada num aviso.
  Timer? _avisoPendente;
  static const Duration _respiroDoAviso = Duration(milliseconds: 300);

  void _avisarEmBreve() {
    _avisoPendente?.cancel();
    _avisoPendente = Timer(_respiroDoAviso, () {
      _avisoPendente = null;
      dataRevision.value++;
    });
  }

  Future<List<Map<String, dynamic>>> consultarComCache(
    String chave,
    String sql, {
    List<dynamic> parametros = const [],
    bool forceRefresh = false,
    bool falharSemCache = false,
    Duration janela = ConsultaCache.janelaPadrao,
    bool somenteLeitura = false,
    bool avisar = true,
    bool atualizarSeVencida = false,
    bool releNaVolta = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(keyDbUrl) ?? '';
    if (url.isEmpty) {
      if (falharSemCache) throw StateError('Banco não configurado');
      return [];
    }
    final completa = 'consulta_v1_${idBanco(url)}_$chave';
    // Quem decide com o dado (catálogo, baixa) espera a rede quando a cópia
    // passou da janela desde o último SUCESSO; dentro dela, a cópia basta.
    if (atualizarSeVencida && !forceRefresh) {
      forceRefresh = await _consultaCache.vencida(completa, janela);
    }
    return _consultaCache.ler(
      completa,
      () async {
        if (!await _garantirConexao() || _urlAtiva != url) {
          throw StateError('Sem conexão com o banco');
        }
        consultasEmitidas++;
        final cliente = _client!;
        var enviada = false;
        try {
          final stmt = await cliente.prepare(sql).timeout(_timeoutConexao);
          enviada = true;
          final rows =
              await stmt
                      .query(positional: parametros)
                      .timeout(_timeoutLeitura)
                  as List<dynamic>;
          contarLeitura(chave, rows.length);
          return rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
        } catch (e) {
          if (enviada && e is TimeoutException) {
            _contarSemResposta(_consultaCache.emMemoria(completa)?.length ?? 0);
          }
          // Tabela ou coluna que não existe neste banco: a consulta sai das
          // conhecidas, senão o Sincronizar a relia, falhava sempre e dava o
          // banco inteiro como fora do ar. Quem pediu decide o que fazer.
          if (erroDeTabelaAusente(e) || erroDeColunaAusente(e)) {
            _consultaCache.esquecer(completa);
            rethrow;
          }
          _renovarClienteDeLeitura(cliente);
          rethrow;
        }
      },
      forceRefresh: forceRefresh,
      falharSemCache: falharSemCache,
      janela: janela,
      somenteLeitura: somenteLeitura,
      avisar: avisar,
      releNaVolta: releNaVolta,
    );
  }

  /// Cópia da ocupação do galpão: a tela, o saldo, a busca do mapa e a
  /// conferência leem a mesma (e o mesmo SQL, senão cada um registraria a
  /// sua consulta para a chave).
  static const String chaveGalpao = 'galpao';
  ///
  /// Inclui os itens dos racks mistos (sqlProdutosGalpao): cada rack vem na
  /// sua linha, com item_uuid NULL, seguida das linhas dos itens dele.
  static const String sqlGalpao =
      'SELECT rack_uuid, item_uuid, posicao, ordem, produto_codigo, '
      'produto_nome, quantidade, seq FROM $sqlProdutosGalpao '
      'ORDER BY posicao, ordem, seq';

  /// Cópia dos endereços do barracão, no mesmo esquema da do galpão.
  static const String chaveBarracao = 'barracao';
  static const String sqlBarracao =
      'SELECT id, rotulo, pos_x, pos_z, produto_codigo, produto_nome, '
      'quantidade FROM barracao_enderecos ORDER BY rotulo';

  /// Chave completa (com o banco) de uma consulta guardada, ou null sem banco
  /// ativo.
  String? _chaveCompleta(String chave) {
    final banco = _identidadeAtiva;
    return banco == null ? null : 'consulta_v1_${banco}_$chave';
  }

  /// True quando a cópia de [chave] não teve leitura bem-sucedida dentro de
  /// [janela] — mesmo que ela tenha vindo do disco de uma sessão anterior.
  /// É o que decide se quem precisa de dado recente (catálogo, baixa) espera
  /// a rede ou usa a cópia.
  Future<bool> consultaVencida(String chave, Duration janela) async {
    final completa = _chaveCompleta(chave);
    if (completa == null) return true;
    return _consultaCache.vencida(completa, janela);
  }

  /// Janela das cópias de contagem (última contagem por produto): o app de
  /// contagem confirma itens o dia todo, e o selo âmbar das prateleiras
  /// aguenta esse atraso.
  static const Duration janelaContagem = Duration(minutes: 10);

  /// Janela das consultas que varrem tabela inteira e grande
  /// (estoque_localizado, layouts para a busca, materiais_terceiros). O que
  /// ESTE aparelho grava já corrige a cópia na hora; a janela só limita quanto
  /// demora para aparecer o que OUTRO aparelho ou app mudou.
  static const Duration janelaTabelaGrande = Duration(minutes: 5);

  /// Janela do estoque_mestre e do mapa de produtos: o primeiro só muda quando
  /// a planilha do ERP sobe (uma vez por dia), o segundo pelo dashboard. É a
  /// mesma validade que o catálogo já tinha no modo remoto.
  static const Duration janelaCadastro = _produtosCacheTtl;

  /// Troca a conexão de leitura por uma nova depois de uma falha.
  ///
  /// Pelo mesmo motivo da de escrita (ver [_clienteEscrita]): o libsql guarda
  /// o "baton" da conversa no stream da conexão, e uma consulta cortada no
  /// meio pode deixá-lo vencido — dali em diante toda leitura falhava até
  /// reabrir o app, e o galpão ficava preso na cópia antiga. A conexão nova
  /// não toca no esquema (já está criado nesta sessão) e não sai à rede para
  /// nascer. A velha não é fechada: quem ainda a usa termina com ela.
  void _renovarClienteDeLeitura(LibsqlClient falhou) {
    final url = _urlAtiva;
    final token = _tokenAtivo;
    if (!identical(_client, falhou) || _modoLocal || url == null) return;
    final novo = LibsqlClient.remote(url, authToken: token);
    unawaited(
      novo.connect().timeout(_timeoutConexao).then((_) {
        if (identical(_client, falhou) && _urlAtiva == url) _client = novo;
      }, onError: (_) {}),
    );
  }

  Future<void> guardarConsulta(
    String chave,
    List<Map<String, dynamic>> linhas,
  ) async {
    final url = _urlAtiva;
    if (url == null) return;
    // A busca do galpão e a do barracão saem destas mesmas cópias (ver
    // _buscarNoGalpao). Os layouts de gôndola e estante não passam por aqui:
    // ver _layoutsGondola.
    await _consultaCache.confirmar(
      'consulta_v1_${idBanco(url)}_$chave',
      linhas,
    );
  }

  /// Corrige na cópia das quantidades as linhas de UM produto, relidas do
  /// servidor depois de uma gravação deste aparelho. [avisar] falso é para
  /// quem grava em série (a baixa) e avisa uma vez só no fim.
  Future<void> guardarQuantidadesProduto(
    String codigo,
    List<Map<String, dynamic>> linhas, {
    bool avisar = true,
  }) async {
    final url = _urlAtiva;
    if (url == null) return;
    await _consultaCache.atualizarParte(
      'consulta_v1_${idBanco(url)}_quantidades_detalhes_v2',
      (r) => r['produto_codigo'] == codigo,
      linhas,
    );
    if (avisar) dataRevision.value++;
  }

  /// Uma leitura avulsa, sem cópia: para quem relê só um pedaço de uma cópia
  /// (pelo índice) e a corrige com [corrigirConsulta]. Com prazo, e renovando
  /// a conexão de leitura depois de uma falha, como [consultarComCache].
  ///
  /// [tipo] é como a leitura aparece no diagnóstico de leituras.
  Future<List<Map<String, dynamic>>> consultarDireto(
    String sql, {
    List<Object?> parametros = const [],
    String tipo = 'leitura_avulsa',
  }) async {
    if (!await _garantirConexao()) {
      throw StateError('Sem conexão com o banco');
    }
    final cliente = _client!;
    var enviada = false;
    try {
      consultasEmitidas++;
      final stmt = await cliente.prepare(sql).timeout(_timeoutConexao);
      enviada = true;
      final rows =
          await stmt.query(positional: parametros).timeout(_timeoutLeitura)
              as List<dynamic>;
      contarLeitura(tipo, rows.length);
      return rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
    } catch (e) {
      if (enviada && e is TimeoutException) _contarSemResposta(0);
      // Tabela ou coluna que não existe é resposta do banco, não conexão
      // quebrada (a medição das tabelas pergunta por tabelas opcionais).
      if (!erroDeTabelaAusente(e) && !erroDeColunaAusente(e)) {
        _renovarClienteDeLeitura(cliente);
      }
      rethrow;
    }
  }

  /// Troca na cópia de [chave] (nome curto) as linhas que [pertence] aceita
  /// por [novas]. Devolve a cópia inteira corrigida, ou null sem cópia — aí
  /// quem chamou relê a consulta inteira.
  Future<List<Map<String, dynamic>>?> corrigirConsulta(
    String chave,
    bool Function(Map<String, dynamic>) pertence,
    List<Map<String, dynamic>> novas, {
    int Function(Map<String, dynamic>, Map<String, dynamic>)? ordenar,
    bool descartarNoAr = true,
  }) async {
    final completa = _chaveCompleta(chave);
    if (completa == null) return null;
    return _consultaCache.atualizarParte(
      completa,
      pertence,
      novas,
      ordenar: ordenar,
      descartarNoAr: descartarNoAr,
    );
  }

  /// Faz a próxima leitura das quantidades ir ao banco — para quem gravou em
  /// estoque_localizado e não conseguiu corrigir a cópia.
  void expirarQuantidades() {
    final chave = _chaveCompleta(_chaveQuantidades);
    if (chave != null) _consultaCache.expirar(chave);
  }

  /// Volta ao app que não relê nada se a anterior foi há menos que isto.
  ///
  /// No galpão a tela bloqueia e desbloqueia a cada palete, e cada volta relia
  /// as ~30 consultas guardadas — o estoque_mestre e o estoque_localizado
  /// inteiros, toda vez. O Sincronizar continua relendo tudo na hora.
  static const Duration intervaloVoltaAoApp = Duration(minutes: 5);
  DateTime? _ultimaVoltaAoApp;

  /// Na volta do aplicativo a consulta acontece atrás da cena já visível, e
  /// só para as consultas cuja janela já passou e que alguém usou nesta
  /// sessão. O prewarm lê ~35 layouts e as buscas na abertura, e reler tudo
  /// isso a cada desbloqueio no galpão — onde ninguém abre gôndola — era o
  /// grosso do custo da volta.
  Future<void> atualizarConsultas() async {
    if (_consultaCache.atualizando) return;
    final ultima = _ultimaVoltaAoApp;
    if (ultima != null &&
        DateTime.now().difference(ultima) < intervaloVoltaAoApp) {
      return;
    }
    _ultimaVoltaAoApp = DateTime.now();
    try {
      await _consultaCache.atualizar(soVencidas: true, soUsadas: true);
    } catch (_) {
      _ultimoErroSync =
          'Não foi possível atualizar. Os dados anteriores continuam visíveis.';
    }
  }

  /// Consultas efetivamente enviadas ao banco desde a abertura do app. Serve
  /// para conferir, no log de debug, que reabrir uma cena já visitada não
  /// emite consulta nenhuma.
  int consultasEmitidas = 0;

  /// Quanto este aparelho leu do Turso, por dia e por tipo de consulta (ver
  /// leituras_turso.dart e ⚙️ → Leituras deste aparelho).
  late final ContadorDeLeituras leituras = ContadorDeLeituras(
    carregarDisco: () async =>
        (await SharedPreferences.getInstance()).getString(_chaveLeituras),
    gravarDisco: (texto) async =>
        (await SharedPreferences.getInstance()).setString(_chaveLeituras, texto),
  );
  static const String _chaveLeituras = 'leituras_turso_v1';

  /// Anota [linhas] lidas por [consultas] consultas de [tipo] (ver
  /// [leituras]).
  void contarLeitura(String tipo, int linhas, {int consultas = 1}) =>
      leituras.registrar(tipo, linhas, consultas: consultas);

  /// Leitura que estourou o prazo depois de enviada: o banco já a executou (e
  /// o Turso cobrou), só a resposta não chegou. [linhas] é a estimativa — o
  /// tamanho da cópia que ela renovaria, quando há.
  void _contarSemResposta(int linhas) => contarLeitura('sem_resposta', linhas);

  static const String _chaveTamanhos = 'tamanho_tabelas_v1';

  /// As tabelas que as consultas agrupam ou filtram sem índice: é o tamanho
  /// delas que dá a estimativa das linhas varridas (ver [tabelaVarridaPor]).
  /// As lidas inteiras já aparecem com o número exato no próprio contador.
  static const List<String> tabelasMedidas = tabelasVarridas;

  /// O último tamanho medido de cada tabela ([medirTabelas]), e quando.
  Future<({Map<String, int> tamanhos, DateTime? em})> tamanhosDasTabelas()
      async {
    try {
      final texto = (await SharedPreferences.getInstance()).getString(
        _chaveTamanhos,
      );
      if (texto == null) return (tamanhos: <String, int>{}, em: null);
      final json = jsonDecode(texto) as Map<String, dynamic>;
      // Medida de uma versão que media mais tabelas: só as que ainda contam.
      return (
        tamanhos: {
          for (final e in (json['tabelas'] as Map<String, dynamic>).entries)
            if (tabelasMedidas.contains(e.key)) e.key: (e.value as num).toInt(),
        },
        em: DateTime.tryParse(json['em'] as String? ?? ''),
      );
    } catch (_) {
      return (tamanhos: <String, int>{}, em: null);
    }
  }

  /// Conta as linhas de cada uma das [tabelasMedidas] (COUNT(*), que no
  /// Turso custa a tabela inteira — é sob pedido, em ⚙️) e guarda. Tabela
  /// que não existe neste banco fica de fora. Uma medição em andamento é
  /// compartilhada: sair e voltar à tela não paga as tabelas de novo.
  Future<Map<String, int>> medirTabelas() =>
      _medicao ??= _medirTabelas().whenComplete(() => _medicao = null);
  Future<Map<String, int>>? _medicao;

  /// True enquanto uma medição está no ar (a tela volta mostrando-a).
  bool get medindoTabelas => _medicao != null;

  Future<Map<String, int>> _medirTabelas() async {
    final medidas = <String, int>{};
    Object? falha;
    for (final tabela in tabelasMedidas) {
      try {
        final rows = await consultarDireto(
          'SELECT COUNT(*) AS n FROM $tabela',
          tipo: 'medicao_tabelas',
        );
        final n = (rows.first['n'] as num?)?.toInt() ?? 0;
        medidas[tabela] = n;
        // O COUNT varre a tabela: o que conta é ela, não a linha devolvida
        // (a consulta em si já foi anotada por consultarDireto).
        contarLeitura('medicao_tabelas', n - 1, consultas: 0);
      } catch (e) {
        // Uma tabela que falhou não joga fora as já medidas (e já pagas).
        if (!erroDeTabelaAusente(e)) falha ??= e;
      }
    }
    final tamanhos = juntarMedidas(
      (await tamanhosDasTabelas()).tamanhos,
      medidas,
    );
    if (medidas.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _chaveTamanhos,
        jsonEncode({
          'em': DateTime.now().toIso8601String(),
          'tabelas': tamanhos,
        }),
      );
    }
    if (falha != null) throw falha;
    return tamanhos;
  }

  /// A medida anterior com a nova por cima, só das [tabelasMedidas] (as que
  /// saíram da lista não pesam mais na tela).
  static Map<String, int> juntarMedidas(
    Map<String, int> anteriores,
    Map<String, int> novas,
  ) => {
    for (final t in tabelasMedidas)
      if (novas[t] ?? anteriores[t] case final n?) t: n,
  };

  bool get isConnected => _connected;

  /// Incrementa a cada sincronização bem-sucedida (carga inicial em segundo
  /// plano ou botão Sincronizar). As páginas ouvem para recarregar a cena
  /// assim que dados novos chegam, sem travar a abertura.
  final ValueNotifier<int> dataRevision = ValueNotifier<int>(0);

  /// True quando a conexão ativa usa o cache local (arquivo no dispositivo).
  bool get modoLocal => _modoLocal;

  bool get sincronizando => _sincronizando;

  EstadoReplica get estadoReplica => _coordenador.estado;

  /// Porta única de toda mutação. A reserva síncrona impede corrida com sync.
  ///
  /// A conexão vem antes do portão de propósito: quem define o estado do
  /// coordenador é o `init()`, que o app dispara sem esperar na abertura
  /// (ver main.dart). Consultar o estado primeiro recusaria a gravação feita
  /// nos segundos iniciais — enquanto o init ainda roda, o estado é
  /// `conectando` — mesmo com a replica local inteira. Garantir a conexão
  /// aqui é o que o caminho de escrita já fazia antes do coordenador existir.
  Future<T> garantirReplicaProntaParaEscrita<T>(
    Future<T> Function() acao,
  ) async {
    await _garantirConexao();
    try {
      return await _coordenador.executarEscrita(() async {
        // Dentro do mutex, mas ainda não é hora de escrever: um sync nativo
        // cujo prazo estourou continua vivo (ver _syncNativoEmAndamento) e o
        // mutex não o segura. A recusa por estado já aconteceu acima, então
        // esta espera só atrasa gravação que vai mesmo acontecer.
        await _aguardarSyncNativo();
        return acao();
      });
    } on ReplicaNaoProntaParaEscrita catch (e) {
      _ultimoErroSync = e.toString();
      rethrow;
    }
  }

  /// Roda o `sync()` do libsql serializado com os outros: um sync nativo que
  /// ainda está no ar (porque o `.timeout` de quem o chamou desistiu sem
  /// cancelá-lo) é aguardado antes de começar o próximo. Sem isto, dois syncs
  /// nativos podiam disputar o mesmo arquivo de replica.
  Future<void> _syncNativo(LibsqlClient client) async {
    await _aguardarSyncNativo();
    final futuro = client.sync();
    _syncNativoEmAndamento = futuro;
    try {
      await futuro;
    } finally {
      if (identical(_syncNativoEmAndamento, futuro)) {
        _syncNativoEmAndamento = null;
      }
    }
  }

  /// Espera o sync nativo em andamento terminar, se houver. A falha dele não
  /// é problema de quem espera — quem chamou já a recebeu.
  Future<void> _aguardarSyncNativo() async {
    while (_syncNativoEmAndamento != null) {
      await _syncNativoEmAndamento!.then<void>((_) {}, onError: (_) {});
    }
  }

  // ── Outbox de mutações ────────────────────────────────────────────────────
  // O diário do que este aparelho gravou e o servidor ainda não confirmou. Vive
  // num arquivo à parte da réplica de propósito: a recuperação APAGA a réplica,
  // e o que serve para reconstruir não pode morrer junto com o que se perdeu.

  Future<String> _caminhoOutbox() async {
    final dir = await getApplicationSupportDirectory();
    final id = _identidadeAtiva ?? 'sem_banco';
    return '${dir.path}/camda_gondolas_outbox_$id.db';
  }

  Future<void> _abrirOutbox() async {
    try {
      await _outbox.abrir(await _caminhoOutbox());
    } catch (_) {
      _ultimoErroSync =
          'A proteção das gravações está indisponível. '
          'As consultas continuam disponíveis; tente novamente antes de gravar.';
      throw StateError(_ultimoErroSync!);
    }
  }

  /// Identificador deste aparelho, resolvido uma vez por sessão.
  ///
  /// NUNCA lança, e isso é requisito, não zelo: quem chama é o `abrirMutacao`,
  /// que roda DENTRO da transação da gravação. Uma exceção aqui — preferências
  /// indisponíveis, `Platform` inexistente na Web — derrubaria por rollback um
  /// lançamento que estava perfeitamente bom. Sem identidade, a mutação ainda
  /// vale; ela só chega à conferência sem dizer de qual aparelho veio.
  Future<String> _dispositivoAtual() async {
    final emMemoria = _dispositivo;
    if (emMemoria != null) return emMemoria;
    // `Platform` vem do dart:io e não existe na Web, onde o app roda em modo
    // remoto — e é justamente ali que toda gravação passaria por aqui.
    final plataforma = kIsWeb ? 'web' : Platform.operatingSystem;
    var id = '$plataforma-${gerarUuidV4().substring(0, 8)}';
    try {
      final prefs = await SharedPreferences.getInstance();
      final guardado = prefs.getString(keyDispositivo);
      if (guardado != null) {
        id = guardado;
      } else {
        await prefs.setString(keyDispositivo, id);
      }
    } catch (_) {
      // Fica o sorteado desta sessão. Um nome de aparelho instável é menos
      // grave do que uma gravação recusada.
    }
    _dispositivo = id;
    return id;
  }

  /// Registra a INTENÇÃO de uma mutação antes de ela ser commitada.
  ///
  /// [estadoAnterior] é a linha como ela está agora (null se não existe) e
  /// [estadoFinal] é onde ela deve chegar (null para um DELETE). São esses dois
  /// que tornam a reaplicação segura depois de uma reconstrução: sem o
  /// anterior, não há como saber se o remoto ainda está onde estava quando o
  /// usuário agiu — e reaplicar por cima do trabalho de outra pessoa é
  /// exatamente o que não se pode fazer.
  ///
  /// Só as colunas que interessam entram nos estados. Carimbo de
  /// `atualizado_em` fica de fora: ele muda sempre, e faria toda comparação
  /// terminar em conflito.
  Future<MutacaoOutbox> abrirMutacao({
    required String operacao,
    String? uuid,
    required String tabela,
    required Map<String, Object?> chave,
    required Map<String, Object?>? estadoAnterior,
    required Map<String, Object?>? estadoFinal,

    /// Colunas NOT NULL necessárias para RECRIAR a linha, que não entram na
    /// comparação de estado (`atualizado_em`, `criado_em`).
    Map<String, Object?> extrasParaInsercao = const {},
    Map<String, Object?>? auditoria,
    String? produtoCodigo,
    String? produtoNome,
    int? posicao,
    int? ordem,
    double? quantidadeAnterior,
    double? quantidadePretendida,
  }) async {
    final mutacao = MutacaoOutbox(
      uuid: uuid ?? gerarUuidV4(),
      auditoria: auditoria,
      operacao: operacao,
      alvo: AlvoMutacao(tabela: tabela, chave: chave),
      estadoAnterior: estadoAnterior,
      estadoFinal: estadoFinal,
      extrasParaInsercao: extrasParaInsercao,
      criadoEm: DateTime.now(),
      dispositivo: await _dispositivoAtual(),
      produtoCodigo: produtoCodigo,
      produtoNome: produtoNome,
      posicao: posicao,
      ordem: ordem,
      quantidadeAnterior: quantidadeAnterior,
      quantidadePretendida: quantidadePretendida,
    );
    // Sempre, não só quando fechada: se a URL do banco mudou nesta sessão, o
    // caminho mudou junto e a store precisa rotacionar. Uma outbox presa no
    // banco anterior gravaria as mutações novas no arquivo errado — e julgaria
    // as antigas contra o servidor errado.
    // Escritas remotas já são transacionadas no servidor. Na Web não existe
    // arquivo local; a outbox é obrigatória para commits na réplica.
    if (_modoLocal) {
      await _abrirOutbox();
      try {
        await _outbox.registrar(mutacao);
      } catch (_) {
        _ultimoErroSync =
            'Não foi possível proteger esta alteração. '
            'A gravação foi cancelada; tente novamente.';
        rethrow;
      }
    }
    return mutacao;
  }

  /// Um lançamento sem resposta reutiliza o mesmo UUID, inclusive após fechar
  /// o app. Só removemos o pedido depois de receber confirmação do servidor.
  Future<String> pedidoOnline(String chave) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'pedido_online_${_identidadeAtiva}_$chave';
    final existente = prefs.getString(key);
    if (existente != null) return existente;
    final uuid = gerarUuidV4();
    if (!await prefs.setString(key, uuid)) {
      throw StateError(
        'Não foi possível preparar o lançamento. Tente novamente.',
      );
    }
    return uuid;
  }

  Future<void> concluirPedidoOnline(String chave) async {
    try {
      await (await SharedPreferences.getInstance()).remove(
        'pedido_online_${_identidadeAtiva}_$chave',
      );
    } catch (_) {
      /* Manter UUID é seguro: a próxima tentativa apenas confere. */
    }
  }

  /// Uma resposta perdida não prova rollback. Consulte o carimbo que foi
  /// gravado na mesma transação antes de comunicar sucesso ou permitir retry.
  Future<void> confirmarCommit(Transaction tx, MutacaoOutbox? mutacao) async {
    try {
      await tx.commit();
    } catch (_) {
      if (mutacao != null && !_modoLocal) {
        try {
          final remoto = await _sondaRemota();
          final rows = await remoto?.query(
            'SELECT uuid FROM app_mutacoes_aplicadas WHERE uuid = ?',
            positional: [mutacao.uuid],
          );
          if (rows != null && rows.isNotEmpty) return;
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// True quando o UUID está carimbado NO SERVIDOR — a gravação entrou,
  /// mesmo que a resposta do lote tenha se perdido no caminho. Pergunta pela
  /// conexão de sondagem, não pela que acabou de falhar.
  Future<bool> confirmadoNoServidor(String uuid) async {
    try {
      final remoto = await _sondaRemota();
      final rows = await remoto
          ?.query(
            'SELECT uuid FROM app_mutacoes_aplicadas WHERE uuid = ?',
            positional: [uuid],
          )
          .timeout(_timeoutConexao);
      return rows != null && rows.isNotEmpty;
    } catch (_) {
      await _descartarSonda();
      return false;
    }
  }

  /// Carimba o UUID DENTRO da transação da mutação. É o que faz o
  /// reconhecimento viajar nos mesmos frames: ou os dois chegam, ou nenhum.
  Future<void> carimbarMutacao(Transaction tx, MutacaoOutbox m) => tx.execute(
    'INSERT OR REPLACE INTO app_mutacoes_aplicadas '
    '(uuid, aplicada_em, operacao, dispositivo) VALUES (?, ?, ?, ?)',
    positional: [
      m.uuid,
      DateTime.now().toIso8601String(),
      m.operacao,
      m.dispositivo,
    ],
  );

  /// A transação caiu antes do commit: nada foi gravado. O registro NÃO é
  /// apagado (a outbox não apaga nada), só sai da fila de reaplicação.
  Future<void> abortarMutacao(MutacaoOutbox m) async {
    try {
      await _outbox.marcar(m.uuid, EstadoMutacao.abortada);
    } catch (_) {}
  }

  /// Quantas mutações o servidor ainda não confirmou, segundo a outbox.
  Future<int> mutacoesNaoConfirmadas() async {
    await _abrirOutbox();
    return _outbox.quantidadeNaoConfirmada();
  }

  /// O que precisa de uma pessoa: conflito com o remoto, ou operação que a
  /// reconstrução não sabe reaplicar sozinha.
  Future<List<MutacaoOutbox>> mutacoesParaRevisao() async {
    await _abrirOutbox();
    return _outbox.paraRevisao();
  }

  Future<List<MutacaoOutbox>> mutacoesPendentes() async {
    await _abrirOutbox();
    return _outbox.naoConfirmadas();
  }

  /// Confirma no SERVIDOR as mutações que a outbox ainda tem em aberto.
  ///
  /// A pergunta é feita ao remoto de propósito. Consultar a réplica devolveria
  /// o UUID que este aparelho acabou de gravar nela — a linha está lá tendo o
  /// push saído ou não, então a réplica responde "sim" para tudo. Só o servidor
  /// sabe o que recebeu.
  ///
  /// Devolve quantas passaram a contar como confirmadas. Uma falha de rede não
  /// confirma nem desconfirma nada: os registros ficam onde estavam.
  Future<int> confirmarMutacoesNoRemoto() async {
    if (kIsWeb) return 0;
    await _abrirOutbox();
    final List<MutacaoOutbox> abertas;
    try {
      abertas = await _outbox.naoConfirmadas();
    } catch (_) {
      return 0;
    }
    if (abertas.isEmpty) return 0;

    final remoto = await _sondaRemota();
    if (remoto == null) return 0;

    var confirmadas = 0;
    // Em lotes: um IN gigante com centenas de UUIDs é pedido rejeitado.
    for (var i = 0; i < abertas.length; i += 100) {
      final fim = (i + 100 < abertas.length) ? i + 100 : abertas.length;
      final lote = abertas.sublist(i, fim);
      try {
        final marcadores = List.filled(lote.length, '?').join(', ');
        final linhas = await remoto
            .query(
              'SELECT uuid FROM app_mutacoes_aplicadas WHERE uuid IN ($marcadores)',
              positional: [for (final m in lote) m.uuid],
            )
            .timeout(_timeoutConexao);
        final vistos = {for (final l in linhas) l['uuid'] as String?};
        for (final m in lote) {
          if (!vistos.contains(m.uuid)) continue;
          await _outbox.marcar(m.uuid, EstadoMutacao.confirmada);
          confirmadas++;
        }
      } catch (_) {
        // Sem rede, ou a tabela ainda não existe no remoto (banco antigo):
        // nada é confirmado, e nada é perdido. A próxima sincronização tenta
        // de novo.
        await _descartarSonda();
        break;
      }
    }
    return confirmadas;
  }

  /// Reaplica, depois de a réplica ter sido reconstruída, o que ainda não foi
  /// confirmado — e SÓ o que dá para reaplicar em segurança.
  ///
  /// Para cada mutação em aberto, na ordem em que aconteceram:
  ///
  /// - operação que endereça a linha por posição numa pilha (ver
  ///   [operacoesDeRevisaoManual]) → revisão manual, sem tocar no banco;
  /// - remoto igual ao estado final → já aplicada, nada a fazer;
  /// - remoto igual ao estado anterior → aplica o final;
  /// - remoto diferente dos dois → conflito, para uma pessoa decidir.
  ///
  /// Nenhum registro é apagado em nenhum dos caminhos.
  Future<int> reaplicarOutbox() => garantirReplicaProntaParaEscrita(() async {
    await confirmarMutacoesNoRemoto();
    return _reaplicarOutbox();
  });

  Future<int> _reaplicarOutbox() async {
    if (!await _garantirConexao())
      throw StateError('Sem conexão para recuperar.');
    await _abrirOutbox();
    final List<MutacaoOutbox> abertas;
    try {
      abertas = await _outbox.naoConfirmadas();
    } catch (_) {
      throw StateError('Não foi possível ler as alterações protegidas.');
    }

    var reaplicadas = 0;
    final bloqueados = <String>{};
    for (final m in abertas) {
      final alvo = '${m.alvo.tabela}:${canonico(m.alvo.chave)}';
      final carimbo = await _client!.query(
        'SELECT uuid FROM app_mutacoes_aplicadas WHERE uuid = ?',
        positional: [m.uuid],
      );
      if (carimbo.isNotEmpty) continue; // ainda depende de confirmação remota
      if (bloqueados.contains(alvo) || mutacaoExigeRevisaoManual(m)) {
        bloqueados.add(alvo);
        await _outbox.marcar(m.uuid, EstadoMutacao.revisaoManual);
        continue;
      }
      try {
        final decisao = decidirReaplicacao(
          remoto: await _lerLinha(m.alvo),
          anterior: m.estadoAnterior,
          estadoFinal: m.estadoFinal,
          colunas: m.colunasComparadas,
        );
        switch (decisao) {
          case DecisaoReaplicacao.jaAplicada:
            bloqueados.add(alvo);
            // Igualdade de saldo não prova envio nem a existência do histórico.
            // Só confirmarMutacoesNoRemoto pode confirmar o UUID.
            await _outbox.marcar(m.uuid, EstadoMutacao.revisaoManual);
          case DecisaoReaplicacao.conflito:
            bloqueados.add(alvo);
            await _outbox.marcar(m.uuid, EstadoMutacao.conflito);
          case DecisaoReaplicacao.aplicarFinal:
            try {
              await _aplicarEstadoFinal(m);
              reaplicadas++;
            } catch (_) {
              // A aplicação genérica recria a linha só com a chave mais o
              // estado declarado. Numa tabela com outras colunas NOT NULL
              // (inventario_cicli, por exemplo) isso não basta — e o certo
              // então é mandar para conferência, não tentar de novo para
              // sempre em silêncio.
              bloqueados.add(alvo);
              await _outbox.marcar(m.uuid, EstadoMutacao.conflito);
            }
        }
      } catch (_) {
        bloqueados.add(alvo);
        // Erro ao ler ou aplicar não vira confirmação nem descarte: o registro
        // fica em aberto e a próxima passada tenta de novo.
      }
    }
    return reaplicadas;
  }

  /// Lê a linha que a mutação endereça, ou null se ela não existe.
  Future<Map<String, Object?>?> _lerLinha(AlvoMutacao alvo) async {
    if (alvo.chave.isEmpty) return null;
    final onde = alvo.chave.keys.map((c) => '$c = ?').join(' AND ');
    final linhas = await _client!.query(
      'SELECT * FROM ${alvo.tabela} WHERE $onde LIMIT 1',
      positional: alvo.chave.values.toList(),
    );
    return linhas.isEmpty ? null : Map<String, Object?>.from(linhas.first);
  }

  /// Leva a linha ao estado final registrado — e carimba o MESMO UUID, para que
  /// a reaplicação possa ser confirmada pelo servidor como qualquer gravação.
  Future<void> _aplicarEstadoFinal(MutacaoOutbox m) async {
    final tx = await _client!.transaction();
    try {
      final onde = m.alvo.chave.keys.map((c) => '$c = ?').join(' AND ');
      final vistos = await tx.query(
        'SELECT uuid FROM app_mutacoes_aplicadas WHERE uuid = ?',
        positional: [m.uuid],
      );
      if (vistos.isNotEmpty) {
        await tx.rollback();
        return;
      }
      final linhas = await tx.query(
        'SELECT * FROM ${m.alvo.tabela} WHERE $onde LIMIT 1',
        positional: m.alvo.chave.values.toList(),
      );
      if (decidirReaplicacao(
            remoto: linhas.isEmpty
                ? null
                : Map<String, Object?>.from(linhas.first),
            anterior: m.estadoAnterior,
            estadoFinal: m.estadoFinal,
            colunas: m.colunasComparadas,
          ) !=
          DecisaoReaplicacao.aplicarFinal) {
        throw StateError('O registro mudou durante a recuperação.');
      }
      if (m.estadoFinal == null) {
        await tx.execute(
          'DELETE FROM ${m.alvo.tabela} WHERE $onde',
          positional: m.alvo.chave.values.toList(),
        );
      } else {
        final colunas = m.estadoFinal!.keys.toList();
        final atualiza = colunas.map((c) => '$c = ?').join(', ');
        final alterou = await tx.execute(
          'UPDATE ${m.alvo.tabela} SET $atualiza WHERE $onde',
          positional: [
            ...colunas.map((c) => m.estadoFinal![c]),
            ...m.alvo.chave.values,
          ],
        );
        if (alterou == 0) {
          // A linha não existia (o estado anterior era "ausente"): recria com
          // a chave, o estado final e os extras. Os extras são as colunas
          // NOT NULL que não entram na comparação — `atualizado_em`,
          // `criado_em`. Sem elas o SQLite recusa o INSERT, e uma gravação
          // perfeitamente reaplicável terminaria como conflito.
          final extras = m.extrasParaInsercao.keys
              .where(
                (c) => !m.alvo.chave.containsKey(c) && !colunas.contains(c),
              )
              .toList();
          final todas = [...m.alvo.chave.keys, ...colunas, ...extras];
          await tx.execute(
            'INSERT INTO ${m.alvo.tabela} (${todas.join(', ')}) '
            'VALUES (${List.filled(todas.length, '?').join(', ')})',
            positional: [
              ...m.alvo.chave.values,
              ...colunas.map((c) => m.estadoFinal![c]),
              ...extras.map((c) => m.extrasParaInsercao[c]),
            ],
          );
        }
      }
      final auditoria = m.auditoria;
      if (auditoria != null) {
        const campos = [
          'produto_codigo',
          'endereco',
          'qtd_anterior',
          'qtd_nova',
          'origem',
          'registrado_em',
        ];
        await tx.execute(
          'INSERT INTO contagens_log (${campos.join(', ')}) VALUES (?, ?, ?, ?, ?, ?)',
          positional: [for (final campo in campos) auditoria[campo]],
        );
      }
      await carimbarMutacao(tx, m);
      await tx.commit();
      await marcarGravacaoLocal();
    } catch (e) {
      await tx.rollback();
      rethrow;
    }
    _invalidarCachesDeLeitura();
  }

  /// Motivo para NÃO trocar a URL do banco agora, ou null quando pode trocar.
  ///
  /// A troca reescreve as credenciais em disco, e são elas que dizem ao app
  /// qual banco é o seu. Trocar com gravação pendente abandonaria essas
  /// gravações num arquivo de réplica que ninguém mais consegue sincronizar:
  /// a URL de origem já não está em lugar nenhum. Por isso a pergunta é feita
  /// ANTES de gravar — descobrir depois é descobrir tarde demais.
  Future<String?> impedimentoParaTrocarBanco(String novaUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final atual = prefs.getString(keyDbUrl) ?? '';
    if (atual.isEmpty) return null;
    if (idBanco(atual) == idBanco(novaUrl)) return null;
    final banco = idBanco(atual);
    final pendentes =
        (prefs.getInt('${keyGravacoesPendentes}_$banco') ??
            prefs.getInt(keyGravacoesPendentes) ??
            0) +
        // A fila do galpão/barracão: o que ainda não subiu também é deste
        // banco, e depois da troca não teria para onde ir.
        OperacaoPendente.decodificarLista(
          prefs.getString(chaveFilaGravacao),
        ).where((o) => o.banco == banco).length;
    if (pendentes <= 0) return null;
    final plural = pendentes == 1 ? 'gravação' : 'gravações';
    return '$pendentes $plural deste banco ainda não subiram. Espere '
        'subirem (ou sincronize) antes de trocar a URL — depois da troca não '
        'há como enviá-las.';
  }

  /// Tranca o app em recuperação e GRAVA a marca antes de devolver: é ela que
  /// sobrevive ao fechamento do app. Só o apagamento da réplica desfaz.
  Future<void> _exigirRecuperacao() async {
    _coordenador.exigirRecuperacao();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_chavePorBanco(keyRecuperacaoNecessaria), true);
    } catch (_) {
      // Perder a persistência não pode derrubar a trava em memória — nesta
      // sessão o portão de escrita já está fechado, que é o que protege os
      // dados agora.
    }
  }

  DateTime? get ultimaSincronizacao => _ultimaSincronizacao;

  /// Descrição curta (para o usuário) do motivo da última falha de
  /// sincronização, ou null se a última tentativa deu certo.
  String? get ultimoErroSync => _ultimoErroSync;

  /// Recado da última sincronização BEM-SUCEDIDA que não foi rotina — hoje,
  /// só a reconstrução automática da replica divergente, que o usuário precisa
  /// saber que aconteceu (ela descarta gravações locais não sincronizadas).
  /// Null quando o sync foi o de sempre.
  String? get ultimoAvisoSync => _ultimoAvisoSync;

  /// Gravações feitas no aparelho que ainda não foram aceitas pelo banco
  /// online. Zero significa "o que está aqui já está lá".
  int get gravacoesPendentes => _gravacoesPendentes;

  /// Quantas gravações locais o servidor aceitou na última sincronização
  /// bem-sucedida. É o número que o snackbar mostra — ver `resumoDoSync`.
  int get enviadasNoUltimoSync => _enviadasNoUltimoSync;

  /// Registra que uma escrita local acabou de ser confirmada no arquivo da
  /// replica — ou seja, que existe frame novo esperando o próximo push.
  ///
  /// Chamada por TODO ponto de escrita DEPOIS do commit, nunca antes: contar
  /// uma gravação que falhou deixaria o contador preso em > 0 e o app diria
  /// que há coisa esperando envio quando não há.
  ///
  /// No modo remoto não há nada pendente por definição (a escrita já foi ao
  /// servidor), então a chamada é ignorada.
  ///
  /// A persistência é aguardada antes de liberar o mutex. Assim um sync que
  /// venha logo depois não pode remover a chave e ser ultrapassado por uma
  /// gravação assíncrona antiga do contador.
  ///
  /// [expirarQuantidades] falso: quem gravou não mexeu em estoque_localizado
  /// (layout, paletes, contagem do ciclo, seed do barracão), ou já corrige a
  /// cópia das quantidades sozinho — por produto (diálogo de quantidade) ou
  /// pelos locais anotados em [marcarLocalGravado] (fila do galpão e do
  /// barracão). Expirar mandaria reler o estoque_localizado inteiro a cada
  /// gravação.
  ///
  /// [chavesAfetadas]: as únicas consultas guardadas que a gravação pode ter
  /// deixado velhas (nomes curtos, como 'galpao'). Só as leituras em andamento
  /// DELAS são descartadas; sem a lista, todas as que este app grava. Descartar
  /// leitura no ar é jogar fora linhas já cobradas pelo Turso — a volta ao
  /// app relê várias consultas no mesmo instante em que a fila reenvia.
  Future<void> marcarGravacaoLocal({
    bool expirarQuantidades = true,
    Set<String>? chavesAfetadas,
  }) async {
    final banco = _identidadeAtiva;
    _consultaCache.invalidarConsultasEmAndamento(
      chavesAfetadas == null || banco == null
          ? null
          : [for (final c in chavesAfetadas) 'consulta_v1_${banco}_$c'],
    );
    if (expirarQuantidades) this.expirarQuantidades();
    if (!_modoLocal) return;
    _gravacoesPendentes++;
    await _persistirGravacoesPendentes();
  }

  /// Faz a próxima leitura da consulta [chave] (nome curto) ir ao banco.
  void expirarConsulta(String chave) {
    final completa = _chaveCompleta(chave);
    if (completa != null) _consultaCache.expirar(completa);
  }

  Future<void> _persistirGravacoesPendentes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = _identidadeAtiva;
      await prefs.setInt(
        id == null ? keyGravacoesPendentes : '${keyGravacoesPendentes}_$id',
        _gravacoesPendentes,
      );
    } catch (_) {
      // Perder a persistência do contador não pode derrubar a gravação que
      // acabou de dar certo: o valor em memória segue valendo nesta sessão.
    }
  }

  /// Zera o contador de pendências (em memória e no disco). Chamado quando o
  /// envio foi confirmado pelo servidor e quando as gravações locais deixam de
  /// existir — replica reconstruída ou cache limpo.
  Future<void> _zerarGravacoesPendentes() async {
    _gravacoesPendentes = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = _identidadeAtiva;
      await prefs.remove(
        id == null ? keyGravacoesPendentes : '${keyGravacoesPendentes}_$id',
      );
    } catch (_) {
      // Ver marcarGravacaoLocal.
    }
  }

  // Acessor para serviços satélite (ex: EstoqueLocalizadoService) reaproveitarem
  // esta mesma conexão, em vez de abrir uma segunda.
  LibsqlClient? get client => _client;

  /// Identidade (ver [idBanco]) do banco em uso, ou null antes do init.
  String? get identidadeAtiva => _identidadeAtiva;

  /// Identificador deste aparelho (ver [_dispositivoAtual]).
  Future<String> dispositivo() => _dispositivoAtual();

  // ── Gravação em uma requisição ────────────────────────────────────────────

  /// Conexão SÓ de escrita, separada da de leitura ([_client]) e descartada a
  /// cada falha.
  ///
  /// Separada porque o libsql usa um stream Hrana só por conexão, atrás de um
  /// mutex: uma leitura grande presa na rede ruim (o catálogo de 5000 linhas,
  /// por exemplo) seguraria a gravação atrás dela. Descartável porque o mesmo
  /// stream guarda o "baton" da última conversa com o servidor, e uma
  /// requisição cortada no meio pode deixá-lo vencido — daí em diante TODA
  /// requisição daquela conexão volta com erro, até reabrir o app. E porque o
  /// cliente HTTP do libsql não tem prazo: uma requisição sem resposta fica
  /// pendurada segurando o mutex. Conexão nova = stream novo, sem nada disso.
  LibsqlClient? _clienteEscrita;

  /// Prazo de UMA gravação, do envio à resposta. Folgado para a rede da loja
  /// (inclui o handshake TLS de uma conexão nova); estourou, a fila tenta de
  /// novo com o mesmo UUID, sem risco de gravar duas vezes.
  static const Duration timeoutGravacao = Duration(seconds: 25);

  /// Roda [comandos] como UMA requisição: BEGIN IMMEDIATE; …; COMMIT (ver
  /// gravacao_lote.dart). Volta normalmente só quando o servidor confirmou o
  /// COMMIT; qualquer outro desfecho vira [FalhaGravacao], já classificada
  /// entre "reenviar resolve" e "não adianta reenviar".
  ///
  /// Não passa pelo mutex do coordenador de propósito: a escrita é uma
  /// transação inteira no servidor, com prazo próprio, e esperar na fila
  /// atrás de uma gravação antiga sem prazo recriaria o "fica só gravando".
  Future<void> executarLote(
    List<String> comandos, {
    Duration limite = timeoutGravacao,
  }) async {
    if (!await _garantirConexao() || _urlAtiva == null || _tokenAtivo == null) {
      throw const FalhaGravacao(
        TipoFalhaGravacao.rede,
        'Sem conexão com o banco online.',
      );
    }
    final texto = textoDoLote(comandos);
    LibsqlClient? cliente = _clienteEscrita;
    try {
      if (cliente == null) {
        cliente = LibsqlClient.remote(_urlAtiva!, authToken: _tokenAtivo);
        await cliente.connect().timeout(limite);
        _clienteEscrita = cliente;
      }
      await cronometrar('lote', () => cliente!.batch(texto).timeout(limite));
      consultasEmitidas++;
    } catch (e) {
      // Qualquer falha aposenta a conexão (ver [_clienteEscrita]). A próxima
      // tentativa abre outra; a requisição que ficou pendurada, se um dia
      // completar, completa no vazio — e o UUID impede que valha duas vezes.
      if (cliente != null && identical(_clienteEscrita, cliente)) {
        _clienteEscrita = null;
      }
      throw classificarFalhaGravacao(e);
    }
  }

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

  /// Refaz a conexão do zero, mesmo que nada tenha mudado nas preferências.
  ///
  /// Existe para o caso do fallback silencioso: quando abrir o arquivo local
  /// falha (sinal ruim durante o download do snapshot, por exemplo), o `_init`
  /// cai para a conexão direta e o app fica em modo remoto pelo resto da
  /// sessão — o reaproveitamento de conexão impede qualquer nova tentativa.
  /// Sem isto, a única saída era fechar e reabrir o app.
  Future<void> reconectar() {
    _forcarReconexao = true;
    return init();
  }

  static const String _marcaLimpezaV1 = 'limpeza_preferencias_v1';
  static final RegExp _consultaAntigaDeLayout = RegExp(
    r'^consulta_v1_.+_(gondola_\d+|estante_\d+|busca_gondolas|busca_estantes)'
    r'(\|em)?$',
  );
  static final RegExp _copiaAntigaDeEstrutura = RegExp(
    r'^consulta_v1_(.+)_(gondola|estante)_(\d+)$',
  );

  /// Uma vez por aparelho: apaga o que ficou de versões anteriores e nada
  /// mais lê — a chave "Cache de consulta" e as cópias de layout por
  /// estrutura e da busca (hoje é uma cópia por tabela, ver
  /// [chaveLayoutsGondola]). No Android cada gravação no SharedPreferences
  /// reescreve o arquivo inteiro, e essas ~40 cópias iam junto toda vez.
  ///
  /// Antes de apagar, as cópias por estrutura (mesmas colunas da cópia nova)
  /// viram a cópia completa de cada banco, SEM carimbo — vencida, relida na
  /// primeira abertura com rede. Sem isso, o primeiro uso sem sinal depois
  /// da atualização abria toda gôndola sem layout.
  Future<void> _limparPreferenciasAntigas(SharedPreferences prefs) async {
    if (prefs.getBool(_marcaLimpezaV1) ?? false) return;
    try {
      await prefs.remove(keyCacheLocal);
      final porCopiaNova = <String, List<dynamic>>{};
      for (final chave in prefs.getKeys()) {
        final m = _copiaAntigaDeEstrutura.firstMatch(chave);
        if (m == null) continue;
        final nova = m.group(2) == 'gondola'
            ? 'consulta_v1_${m.group(1)}_$chaveLayoutsGondola'
            : 'consulta_v1_${m.group(1)}_$chaveLayoutsEstante';
        if (prefs.containsKey(nova)) continue;
        try {
          (porCopiaNova[nova] ??= []).addAll(
            jsonDecode(prefs.getString(chave) ?? '[]') as List,
          );
        } catch (_) {
          // Cópia antiga ilegível: fica de fora.
        }
      }
      for (final e in porCopiaNova.entries) {
        await prefs.setString(e.key, jsonEncode(e.value));
      }
      for (final chave in prefs.getKeys().toList()) {
        if (_consultaAntigaDeLayout.hasMatch(chave)) await prefs.remove(chave);
      }
      await prefs.setBool(_marcaLimpezaV1, true);
    } catch (_) {
      // Fica para a próxima abertura.
    }
  }

  Future<void> _init() async {
    _coordenador.definirEstado(EstadoReplica.conectando);
    // Consumido já: uma reconexão forçada vale para ESTA passada, senão toda
    // abertura de página passaria a reconectar.
    final forcado = _forcarReconexao;
    _forcarReconexao = false;
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(keyDbUrl) ?? '';
    final token = prefs.getString(keyDbToken) ?? '';
    await _limparPreferenciasAntigas(prefs);
    final identidade = idBanco(url);
    final anterior = prefs.getString(keyIdentidadeAtiva);
    if (anterior != null && anterior != identidade) {
      final pendentesAntigas =
          prefs.getInt('${keyGravacoesPendentes}_$anterior') ??
          prefs.getInt(keyGravacoesPendentes) ??
          0;
      if (pendentesAntigas > 0) {
        _ultimoErroSync =
            'há gravações pendentes no banco anterior; '
            'sincronize ou exporte antes de trocar a URL';
        _coordenador.definirEstado(EstadoReplica.recuperacaoNecessaria);
        return;
      }
    }
    _identidadeAtiva = identidade;
    await prefs.setString(keyIdentidadeAtiva, identidade);
    if (anterior == null) {
      final baseLegada = prefs.getBool(keyBaseLocalOk);
      final syncLegada = prefs.getString(keyUltimaSync);
      final pendentesLegadas = prefs.getInt(keyGravacoesPendentes);
      if (baseLegada != null) {
        await prefs.setBool(_chavePorBanco(keyBaseLocalOk), baseLegada);
        await prefs.remove(keyBaseLocalOk);
      }
      if (syncLegada != null) {
        await prefs.setString(_chavePorBanco(keyUltimaSync), syncLegada);
        await prefs.remove(keyUltimaSync);
      }
      if (pendentesLegadas != null) {
        await prefs.setInt(
          _chavePorBanco(keyGravacoesPendentes),
          pendentesLegadas,
        );
        await prefs.remove(keyGravacoesPendentes);
      }
    }

    // Antes de qualquer `pronta`: a divergência é uma condição do ARQUIVO da
    // réplica, não da sessão. Reabrir o app não a desfaz, então a marca em
    // disco volta a trancar o coordenador — e, trancado, ele ignora todos os
    // `definirEstado` que este init ainda vai fazer.
    //
    // A trava pertence à RÉPLICA marcada, não ao app: fora dela não há frame
    // local nenhum para o servidor recusar. Por isso a decisão é refeita a
    // cada init, e vale só quando este init vai mesmo usar aquele arquivo —
    // com o cache local desligado (gravação vai direto ao remoto) ou em outro
    // banco, travar seria recusar escrita que não tem como divergir. A marca
    // em disco fica onde está: voltar para aquele banco volta a trancar.
    if (_modoLocal &&
        (prefs.getBool(_chavePorBanco(keyRecuperacaoNecessaria)) ?? false)) {
      _coordenador.exigirRecuperacao();
      _ultimoErroSync = _erroRecuperacao;
    } else if (_coordenador.recuperacaoTravada) {
      _coordenador.concluirRecuperacao();
    }

    // Fora de qualquer transação: quando a primeira gravação chegar, o id já
    // está em memória e o abrirMutacao não precisa tocar em disco.
    unawaited(_dispositivoAtual());

    final ultimaSyncIso = prefs.getString(_chavePorBanco(keyUltimaSync));
    _ultimaSincronizacao = ultimaSyncIso != null
        ? DateTime.tryParse(ultimaSyncIso)
        : null;
    // As pendências sobrevivem ao fechamento do app: o arquivo da replica
    // continua com os frames que não subiram.
    _gravacoesPendentes =
        prefs.getInt('${keyGravacoesPendentes}_$identidade') ?? 0;
    // Antes do early-return de reaproveitamento: o carimbo do catálogo em
    // disco não pode depender de a conexão ter dado certo.
    _urlConfigurada = url;

    if (!forcado &&
        _connected &&
        _client != null &&
        url == _urlAtiva &&
        token == _tokenAtivo) {
      _coordenador.definirEstado(
        _basePendente ? EstadoReplica.basePendente : EstadoReplica.pronta,
      );
      return;
    }

    final clienteAntigo = _client;

    _connected = false;
    _client = null;
    // A de escrita foi aberta com as credenciais antigas.
    _clienteEscrita = null;
    _urlAtiva = null;
    _tokenAtivo = null;
    _modoLocal = false;
    _invalidarCachesDeLeitura();

    if (clienteAntigo != null) {
      // Solta a conexão anterior (troca de credenciais ou de modo) sem
      // segurar o init novo.
      unawaited(clienteAntigo.dispose().catchError((_) {}));
    }
    // A sonda foi aberta com as credenciais velhas — reusá-la depois de uma
    // troca de token responderia "sem rede" para sempre.
    await _descartarSonda();

    if (url.isEmpty || token.isEmpty) {
      _coordenador.definirEstado(EstadoReplica.desconectada);
      return;
    }

    LibsqlClient? client;

    // O cache de consulta não é uma réplica. Toda escrita usa o remoto.
    // A conexão local antiga só é aberta pela recuperação explícita.
    // Sem cache local (Web, preferência desligada ou falha ao abrir o
    // arquivo): conexão direta ao remoto, como antes.
    client ??= await _conectarRemoto(url, token);
    if (client == null) {
      _coordenador.definirEstado(EstadoReplica.erro);
      return;
    }

    try {
      // Modo remoto (Web ou falha ao abrir o arquivo local): cria o esquema
      // e conecta direto ao remoto, como antes.
      // Com prazo: o HTTP do libsql não tem nenhum, e um init pendurado na
      // rede ruim segura tudo que espera conexão — a fila de gravação
      // inclusive. Estourou, o init falha como falharia sem rede, e a
      // próxima chamada tenta de novo com cliente novo.
      await _prepararBanco(client).timeout(_timeoutPreparoBanco);
      _client = client;
      _connected = true;
      _modoLocal = false;
      _basePendente = false;
      _coordenador.definirEstado(EstadoReplica.pronta);
      _urlAtiva = url;
      _tokenAtivo = token;
      // Fim do init: os paletes precisam estar em memória antes do primeiro
      // build do mapa e do carrossel (ordemNavegacaoEstantes consulta
      // PaleteRegistry().ativos). Numa replica sem base a tabela pode ainda
      // não existir — carregar() engole a falha e _estabelecerBaseLocal
      // recarrega quando a base chegar.
      await PaleteRegistry().carregar().timeout(
        _timeoutConexao,
        onTimeout: () {},
      );
      // Por trás, sem segurar a abertura (ver _garantirIndicesAlheios).
      unawaited(_garantirIndicesAlheios());
    } catch (_) {
      _connected = false;
      _client = null;
      _coordenador.definirEstado(EstadoReplica.erro);
    }
  }

  // Limites de tempo: nenhuma etapa de conexão/sincronização pode segurar o
  // app indefinidamente — estourou, cai no fallback (remoto) ou falha o botão
  // de sincronizar com aviso, mantendo os dados locais intactos.
  static const Duration _timeoutConexao = Duration(seconds: 20);
  // Esquema + migrações no init. Com as migrações em dia é uma requisição só;
  // a primeira abertura num aparelho confere todas (~12 idas), e na rede da
  // loja isso passa dos 20 s da conexão.
  static const Duration _timeoutPreparoBanco = Duration(seconds: 45);
  // Uma leitura com cópia em cache (consultarComCache). Folgado porque há
  // leituras de milhares de linhas; o que ele pega é a requisição que nunca
  // volta, e que antes prendia a conexão de leitura até reabrir o app.
  static const Duration _timeoutLeitura = Duration(seconds: 45);
  // Baixar a base pela primeira vez é outra ordem de grandeza: é o banco
  // INTEIRO vindo do Turso, não uma consulta. Medido em campo, 90s não bastou
  // nem em wi-fi — e estourar aqui não devolve um erro visível, devolve o
  // fallback para o modo remoto, que é o pior desfecho possível (grava pela
  // rede, e o Sincronizar fica sem replica para empurrar).
  //
  // Três minutos: o dobro do que a medição pediu, e igual ao teto do sync de
  // rotina — não há motivo para a carga inicial poder esperar mais que ele.
  //
  // Vale APENAS enquanto a base não está estabelecida. Com a base pronta,
  // reabrir usa _timeoutConexao (20s) e sincronizar usa _timeoutSync. Nenhum
  // uso rotineiro do app espera por este limite.
  static const Duration _timeoutSync = Duration(minutes: 3);

  Future<String> _caminhoCacheLocal() async {
    final dir = await getApplicationSupportDirectory();
    final id = _identidadeAtiva;
    if (id == null) return '${dir.path}/camda_gondolas_cache.db';
    final novo = File('${dir.path}/camda_gondolas_cache_$id.db');
    final antigo = File('${dir.path}/camda_gondolas_cache.db');
    // Migração única e não destrutiva para instalações existentes.
    if (!await novo.exists() && await antigo.exists()) {
      await antigo.rename(novo.path);
      for (final sufixo in ['-info', '-wal', '-shm', '-journal']) {
        final lateral = File('${antigo.path}$sufixo');
        if (await lateral.exists()) await lateral.rename('${novo.path}$sufixo');
      }
    }
    return novo.path;
  }

  Future<LibsqlClient?> _conectarComCacheLocal(String url, String token) async {
    // Apenas para conferir a recuperação antiga, sem enviar frames ou migrar.
    final path = await _caminhoCacheLocal();
    if (!await File(path).exists()) return null;
    final local = LibsqlClient.local(path);
    try {
      await local.connect();
      return local;
    } catch (_) {
      await local.dispose();
      return null;
    }
  }

  Future<void> _estabelecerBaseLocal(
    LibsqlClient client,
    Duration limite,
  ) async {
    await _syncNativo(client).timeout(limite);
    // O sync do libsql devolve sucesso quando a requisição HTTP não completa
    // (falha de rede vira "0 frames sincronizados"). Se a replica continua no
    // frame 0 depois dele, o estado é ambíguo: ou o servidor realmente não
    // tinha frames nesta geração, ou não deu para falar com ele. Um SELECT 1
    // no remoto separa os dois — e no segundo caso é proibido escrever aqui.
    if (await _replicaNoFrameZero() && !await _remotoAlcancavel()) {
      throw const BaseLocalNaoBaixada();
    }
    await _prepararBanco(client);
    _basePendente = false;
    _coordenador.definirEstado(EstadoReplica.pronta);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_chavePorBanco(keyBaseLocalOk), true);
    await PaleteRegistry().carregar();
    // Antes do dataRevision: os listeners disparam de forma síncrona no
    // `value++` e chamam _carregarLayout na hora — limpar depois os serviria
    // com as linhas de antes do sync.
    _invalidarCachesDeLeitura();
    await _registrarSincronizacao();
    dataRevision.value++;
  }

  /// True quando a replica local ainda precisa puxar a base do remoto antes de
  /// qualquer escrita. A resposta está no `<banco>-info` que o libsql mantém
  /// ao lado do arquivo: `durable_frame_num == 0` significa "snapshot baixado,
  /// frames ainda não" — que é o estado em que o connect() deixa uma replica
  /// recém-criada, mesmo com o arquivo já cheio de dados. Sem esse arquivo (ou
  /// com formato desconhecido), cai no teste antigo de banco vazio.
  Future<EstadoDaReplica?> _estadoAtualDaReplica() async {
    try {
      final info = File('${await _caminhoCacheLocal()}-info');
      if (!await info.exists()) return null;
      return estadoDaReplica(await info.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Frame confirmado da replica local, ou null se o `-info` não existe / não
  /// dá para ler.
  Future<int?> _frameDuravelAtual() async =>
      (await _estadoAtualDaReplica())?.frame;

  Future<bool> _replicaNoFrameZero() async => (await _frameDuravelAtual()) == 0;

  /// Round-trip curto no banco online, só para saber se há rede. Usado para
  /// desempatar o sync que "deu certo" sem falar com o servidor.
  ///
  /// A conexão de sondagem fica guardada em `_sonda` entre as chamadas: agora
  /// que todo Sincronizar sem novidade passa por aqui, refazer o handshake
  /// (DNS + TLS) a cada toque custaria mais que a própria consulta. Some no
  /// `_init` quando as credenciais mudam e a cada falha — reconectar é o
  /// caminho certo quando a anterior morreu.
  Future<bool> _remotoAlcancavel() async {
    try {
      final remoto = await _sondaRemota();
      if (remoto == null) return false;
      await remoto.query('SELECT 1').timeout(_timeoutConexao);
      return true;
    } catch (_) {
      await _descartarSonda();
      return false;
    }
  }

  /// A conexão de sondagem, aberta sob demanda e reaproveitada entre as
  /// chamadas. Null quando não há credenciais ou o handshake não completa.
  Future<LibsqlClient?> _sondaRemota() async {
    final aberta = _sonda;
    if (aberta != null) return aberta;
    final url = _urlAtiva;
    final token = _tokenAtivo;
    if (url == null || token == null) return null;
    try {
      final remoto = LibsqlClient.remote(url, authToken: token);
      await remoto.connect().timeout(_timeoutConexao);
      _sonda = remoto;
      return remoto;
    } catch (_) {
      await _descartarSonda();
      return null;
    }
  }

  /// Roda a consulta do carimbo (ver `sqlDoCarimbo`) num cliente. Null quando
  /// não deu para carimbar — rede, tabela ausente, formato inesperado.
  Future<Map<String, AssinaturaTabela>?> _carimboDe(
    LibsqlClient? cliente,
  ) async {
    if (cliente == null) return null;
    try {
      final stmt = await cliente.prepare(sqlDoCarimbo());
      final linhas =
          (await stmt.query().timeout(_timeoutConexao)) as List<dynamic>;
      if (linhas.isEmpty) return null;
      return carimboDaLinha(linhas.first as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Carimba os dois lados e compara. É a conferência que o `SELECT 1` não
  /// fazia: servidor no ar prova rede, não prova que os dados vieram.
  ///
  /// [bancoRespondeu] sai do carimbo remoto quando ele volta, e de um
  /// `SELECT 1` quando não volta — assim uma consulta que falha por MOTIVO DE
  /// BANCO (tabela que não existe naquele remoto, coluna nova) não é
  /// confundida com estar sem internet, que travaria todo Sincronizar.
  Future<
    ({
      ConferenciaDoCarimbo resultado,
      List<String> tabelas,
      bool bancoRespondeu,
    })
  >
  _conferirCarimbos() async {
    final remoto = await _carimboDe(await _sondaRemota());
    if (remoto == null) {
      return (
        resultado: ConferenciaDoCarimbo.indeterminada,
        tabelas: const <String>[],
        bancoRespondeu: await _remotoAlcancavel(),
      );
    }
    final aparelho = await _carimboDe(_client);
    return (
      resultado: compararCarimbos(aparelho: aparelho, remoto: remoto),
      tabelas: tabelasDivergentes(aparelho: aparelho, remoto: remoto),
      bancoRespondeu: true,
    );
  }

  /// Confere que o banco online responde usando a conexão JÁ ABERTA.
  ///
  /// No modo remoto essa conexão é o próprio banco online, então um `SELECT 1`
  /// nela é a conferência mais direta e mais barata que existe — não abre
  /// socket novo nem refaz handshake, ao contrário de `_remotoAlcancavel`.
  Future<bool> _clienteRespondendo() async {
    final client = _client;
    if (client == null) return false;
    try {
      final stmt = await client.prepare('SELECT 1');
      await stmt.query().timeout(_timeoutConexao);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Solta a conexão de sondagem, se houver.
  Future<void> _descartarSonda() async {
    final aberta = _sonda;
    _sonda = null;
    if (aberta != null) unawaited(aberta.dispose().catchError((_) {}));
  }

  /// Apaga o arquivo da replica local e TODOS os sidecars que o libsql mantém
  /// ao lado dele. Varre por prefixo de propósito: além do `-wal`/`-shm`/
  /// `-journal` do SQLite existe o `-info` (geração e frame confirmados do
  /// sync), e deixar o `-info` órfão faz a próxima abertura falhar com
  /// InvalidLocalState — ou seja, "limpar o cache" deixaria o app pior do que
  /// estava.
  Future<bool> _apagarArquivosDaReplica() async {
    try {
      final caminho = await _caminhoCacheLocal();
      final arquivo = File(caminho);
      final nome = arquivo.uri.pathSegments.last;
      final pasta = arquivo.parent;
      if (await pasta.exists()) {
        await for (final item in pasta.list(followLinks: false)) {
          if (item is! File) continue;
          if (item.uri.pathSegments.last.startsWith(nome)) await item.delete();
        }
      }
      // A marca de base estabelecida vale para o arquivo que acabou de sumir —
      // e, com ele, foram-se os frames locais que ainda não tinham subido.
      // Manter o contador aqui faria todo Sincronizar seguinte acusar "envio
      // não confirmado" por gravações que não existem mais.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_chavePorBanco(keyBaseLocalOk));
      _gravacoesPendentes = 0;
      // As DUAS chaves: a com namespace do banco é a que vale hoje, e a sem
      // namespace pode ter sobrado de uma instalação anterior à migração.
      // Deixar a com namespace para trás ressuscitava, na próxima abertura,
      // pendências de gravações que sumiram junto com o arquivo.
      await prefs.remove(_chavePorBanco(keyGravacoesPendentes));
      await prefs.remove(keyGravacoesPendentes);
      // A marca de recuperação NÃO sai aqui. Este método também roda no
      // conserto automático de um arquivo que nem abre (ver
      // _conectarComCacheLocal), e ali o apagamento não é escolha do usuário.
      // Quem destrava é só limparCacheLocal.
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Quantas vezes [_invalidarCachesDeLeitura] rodou: quem guarda leitura
  /// própria fora daqui (a conferência do dia) compara para saber que o
  /// Sincronizar (ou uma reconexão) passou e a dele não vale mais.
  int leiturasInvalidadas = 0;

  /// Zera tudo que é leitura em cache (catálogo e layouts). Chamado nos quatro
  /// pontos em que a base sob o app pode ter mudado por inteiro: reconexão,
  /// carga inicial, sincronização e limpeza do cache local.
  void _invalidarCachesDeLeitura() {
    leiturasInvalidadas++;
    _produtosCache = null;
    _produtosCacheEm = null;
    // Locais anotados ainda sem correção: a cópia das quantidades está sem
    // essas gravações, e sem a anotação ninguém mais a corrigiria — ela
    // expira e a próxima leitura busca a tabela. (Num banco novo, as
    // anotações do anterior não dizem nada sobre ele.)
    if (_locaisGravados.isNotEmpty) expirarQuantidades();
    _locaisGravados.clear();
    _tabelasDoMapaAusentes.clear();
    _prewarmFeitoEm = null;
    _layoutsGondola.esquecer();
    _layoutsEstante.esquecer();
  }

  /// True se o arquivo local acabou de ser criado (nenhuma tabela ainda).
  Future<LibsqlClient?> _conectarRemoto(String url, String token) async {
    try {
      final client = LibsqlClient.remote(url, authToken: token);
      await client.connect().timeout(_timeoutConexao);
      return client;
    } catch (_) {
      return null;
    }
  }

  /// Tabelas e índices do app — numa requisição só.
  ///
  /// Eram ~20 `CREATE … IF NOT EXISTS` em fila, cada um uma ida e volta (duas,
  /// com o `describe` do libsql), a cada abertura do app e a cada reconexão.
  /// Na rede da loja isso segurava o init por dezenas de segundos — e tudo
  /// que grava ou lê espera o init. Juntos num `batch`, viram um pipeline
  /// Hrana único. Continua sendo a primeira conversa com o servidor, então
  /// também é ela que prova que há conexão.
  ///
  /// [migracoesEmDia] pula a migração da identidade do rack (que precisa ler
  /// o esquema antes de alterar): ver [_migracoesEmDia].
  Future<void> _criarEsquema(
    LibsqlClient client, {
    bool migracoesEmDia = false,
  }) async {
    final esquema = <String>[];
    esquema.add('''
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
    esquema.add('''
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
    esquema.add('''
      CREATE TABLE IF NOT EXISTS app_migrations (
        nome TEXT PRIMARY KEY,
        aplicada_em TEXT NOT NULL
      )
    ''');
    // Reconhecimento de mutação. Cada gravação insere aqui o seu UUID NA MESMA
    // transação local, então a linha viaja nos mesmos frames que a mutação: ou
    // as duas chegam ao servidor, ou nenhuma. Achar o UUID numa consulta AO
    // REMOTO é a única prova de que o push saiu — o frame não prova (um pull
    // também o move) e a ausência de exceção não prova nada.
    esquema.add('''
      CREATE TABLE IF NOT EXISTS app_mutacoes_aplicadas (
        uuid TEXT PRIMARY KEY,
        aplicada_em TEXT NOT NULL,
        operacao TEXT,
        dispositivo TEXT
      )
    ''');
    // Quantidade de cada produto por endereço físico (gôndola ou estante).
    // Chave por endereço lógico — não referencia gondola_layout.id/estante_layout.id
    // porque salvarLayout/salvarLayoutEstante são destrutivos (DELETE + INSERT).
    esquema.add('''
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
    esquema.add('''
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
    // Catálogo dos paletes de madeira do piso, cadastrados em RUNTIME (o
    // número de paletes na loja é variável — ver PaleteRegistry). `num` é
    // alocado por MAX(num) + 1 varrendo inclusive os inativos, então NUNCA
    // execute DELETE FROM paletes: apagar linha desativada libera o número
    // para reciclagem e o palete novo herdaria os endereços velhos em
    // estoque_localizado. Palete que sai da loja vira ativo = 0.
    esquema.add('''
      CREATE TABLE IF NOT EXISTS paletes (
        num        INTEGER PRIMARY KEY,
        apelido    TEXT    NOT NULL DEFAULT '',
        pos_x      REAL    NOT NULL,
        pos_z      REAL    NOT NULL,
        rotacao    REAL    NOT NULL DEFAULT 0,
        colunas    INTEGER NOT NULL DEFAULT 5,
        fileiras   INTEGER NOT NULL DEFAULT 3,
        ativo      INTEGER NOT NULL DEFAULT 1,
        criado_em  TEXT    NOT NULL
      )
    ''');
    // Estrutura fixa do galpão de racks: as 129 posições de chão das duas
    // partes, sem nível.
    // É espelho de GalpaoConfig (a autoridade das coordenadas continua sendo
    // o código, ver galpao_config.dart) para que os apps irmãos consigam ler
    // a planta sem embutir a tabela de novo. Populada por seed idempotente.
    esquema.add('''
      CREATE TABLE IF NOT EXISTS galpao_posicoes (
        numero INTEGER PRIMARY KEY,
        rua    INTEGER NOT NULL,
        eixo   TEXT    NOT NULL,
        pos_x  REAL    NOT NULL,
        pos_z  REAL    NOT NULL
      )
    ''');
    // Ocupação: um rack por linha. `ordem` é a posição na pilha (1 = chão) e
    // MUDA quando algo abaixo é retirado — é dado, não identidade, e por isso
    // nunca aparece dentro de um código de endereço textual. O UNIQUE
    // (posicao, ordem) é o que garante pilha sem buraco nem duplicata; a
    // renumeração ao esvaziar acontece em transação (ver GalpaoService).
    esquema.add('''
      CREATE TABLE IF NOT EXISTS galpao_racks (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        posicao        INTEGER NOT NULL,
        ordem          INTEGER NOT NULL,
        produto_codigo TEXT    NOT NULL,
        produto_nome   TEXT    NOT NULL DEFAULT '',
        quantidade     REAL    NOT NULL DEFAULT 0,
        atualizado_em  TEXT    NOT NULL,
        UNIQUE(posicao, ordem)
      )
    ''');
    // Rack misto: os produtos ALÉM do primeiro, quando se junta pouco de
    // vários produtos no mesmo palete (até GalpaoConfig.produtosMaxPorRack).
    // O primeiro continua na linha do rack, então a pilha — ordem, descida,
    // UNIQUE(posicao, ordem) — não sabe que isto existe. O item é preso ao
    // rack pelo rack_uuid, que não muda quando a pilha desce (a ordem muda).
    esquema.add('''
      CREATE TABLE IF NOT EXISTS galpao_rack_itens (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        item_uuid      TEXT    NOT NULL UNIQUE,
        rack_uuid      TEXT    NOT NULL,
        produto_codigo TEXT    NOT NULL,
        produto_nome   TEXT    NOT NULL DEFAULT '',
        quantidade     REAL    NOT NULL DEFAULT 0,
        atualizado_em  TEXT    NOT NULL
      )
    ''');


    // Endereços do BARRACÃO: uma linha por palete no chão (ver
    // barracao_config.dart). Uma tabela só, e não o par estrutura + ocupação
    // do galpão, porque aqui o palete É o endereço e leva um produto só — não
    // há pilha para renumerar nem vaga sem palete para guardar.
    //
    // Quantos paletes existem é DADO, não código: a tabela é semeada UMA vez
    // a partir do layout padrão (BarracaoService.garantirSeed) e daí em diante
    // manda no que o app desenha. `rotulo` é UNIQUE porque é o endereço
    // etiquetado no palete — dois 'BAR-07' no mesmo barracão não são endereço,
    // são ambiguidade. pos_x/pos_z estão em CENTÍMETROS, a unidade da planta
    // do barracão (a loja e o galpão usam metros).
    esquema.add('''
      CREATE TABLE IF NOT EXISTS barracao_enderecos (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        rotulo         TEXT    NOT NULL UNIQUE,
        pos_x          REAL    NOT NULL,
        pos_z          REAL    NOT NULL,
        produto_codigo TEXT    NOT NULL DEFAULT '',
        produto_nome   TEXT    NOT NULL DEFAULT '',
        quantidade     REAL    NOT NULL DEFAULT 0,
        atualizado_em  TEXT    NOT NULL
      )
    ''');

    // Índices das buscas mais quentes (só tabelas do próprio app): evitam full
    // scan em fetchLayout / fetchLayoutEstante / buscarProdutoEstante e na
    // busca global. IF NOT EXISTS torna idempotente; estoque_localizado já tem
    // o índice implícito do seu UNIQUE(produto_codigo, ...).
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_gondola_layout_num '
      'ON gondola_layout (gondola_num)',
    );
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_estante_layout_num '
      'ON estante_layout (estante_num)',
    );
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_estante_layout_produto '
      'ON estante_layout (produto_codigo)',
    );
    // Espelha o índice de estante acima: buscarProduto e o SELECT DISTINCT do
    // Modo Conferência filtram gondola_layout por produto_codigo e até aqui
    // faziam varredura completa.
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_gondola_layout_produto '
      'ON gondola_layout (produto_codigo)',
    );
    // As buscas de badge filtram por endereço físico. O índice implícito do
    // UNIQUE de estoque_localizado NÃO serve esse predicado: a coluna líder
    // dele é produto_codigo.
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_estoque_localizado_local '
      'ON estoque_localizado (local_tipo, local_num)',
    );
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_paletes_ativo ON paletes (ativo)',
    );
    // Busca "onde está este produto no galpão" — o UNIQUE(posicao, ordem) não
    // serve esse predicado, a coluna líder dele é posicao.
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_galpao_racks_produto '
      'ON galpao_racks (produto_codigo)',
    );
    // Os itens de um rack (a tela, o espelho, a promoção ao principal) e
    // "onde está este produto" também entre os itens dos racks mistos.
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_galpao_rack_itens_rack '
      'ON galpao_rack_itens (rack_uuid)',
    );
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_galpao_rack_itens_produto '
      'ON galpao_rack_itens (produto_codigo)',
    );
    // Mesmo predicado, do outro prédio: "onde está este produto no barracão".
    // O índice implícito do UNIQUE(rotulo) não serve — a coluna dele é outra.
    esquema.add(
      'CREATE INDEX IF NOT EXISTS idx_barracao_enderecos_produto '
      'ON barracao_enderecos (produto_codigo)',
    );
    await client.batch(esquema.join(';\n'));
    if (migracoesEmDia) return;

    // Identidade do rack: a coluna só é acrescentada se faltar (ALTER não tem
    // IF NOT EXISTS), e o resto é idempotente. Uma leitura do esquema e um
    // lote transacional, em vez de uma transação interativa comando a comando.
    final colunasRack = await client.query('PRAGMA table_info(galpao_racks)');
    await client.batch(
      textoDoLote([
        if (!colunasRack.any((c) => c['name'] == 'rack_uuid'))
          'ALTER TABLE galpao_racks ADD COLUMN rack_uuid TEXT',
        ...migracaoRackIdentidade,
      ]),
    );
  }

  /// O que [_marcarMigracoesEmDia] grava: muda sozinho quando entra migração
  /// nova (nome novo) ou quando a da identidade do rack muda de texto — e aí
  /// tudo roda de novo uma vez.
  static final String _assinaturaMigracoes = [
    'v1',
    _migracaoEstante3,
    _migracaoPaletes,
    migracaoGalpaoUnidades,
    migracaoBarracaoLayout2x2,
    ...migracaoRackIdentidade,
  ].join('\u0001');

  /// True quando as migrações já rodaram até o fim NESTE banco, a partir deste
  /// aparelho. Elas conferem `app_migrations` uma a uma (duas idas cada) e a
  /// do rack ainda lê o esquema: sem esta marca, toda abertura do app pagava
  /// essas idas para descobrir que não havia nada a fazer.
  Future<bool> _migracoesEmDia() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_chavePorBanco('esquema_migrado')) ==
          _assinaturaMigracoes;
    } catch (_) {
      return false;
    }
  }

  Future<void> _marcarMigracoesEmDia() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _chavePorBanco('esquema_migrado'),
        _assinaturaMigracoes,
      );
    } catch (_) {
      // Sem a marca, a próxima abertura só confere de novo.
    }
  }

  /// Esquema + migrações, do jeito mais barato que o estado do aparelho
  /// permite: com tudo em dia, uma requisição só.
  Future<void> _prepararBanco(LibsqlClient client) async {
    final emDia = await _migracoesEmDia();
    await _criarEsquema(client, migracoesEmDia: emDia);
    if (emDia) return;
    // Todas rodam mesmo que uma falhe (cada uma se protege), e a marca só é
    // gravada se TODAS confirmaram: uma que falhou tenta de novo na próxima
    // abertura, como sempre foi.
    final resultados = [
      await _migrarEsquemaLabelsEstante3(client),
      await _migrarPaletesCadastroDinamico(client),
      await migrarGalpaoParaUnidades(client),
      await migrarBarracaoParaLayout2x2(client),
    ];
    if (resultados.every((ok) => ok)) await _marcarMigracoesEmDia();
  }

  Future<void> _registrarSincronizacao() async {
    _ultimaSincronizacao = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _chavePorBanco(keyUltimaSync),
      _ultimaSincronizacao!.toIso8601String(),
    );
  }

  /// Sincroniza o cache local com o banco online: envia as gravações feitas
  /// no dispositivo e baixa as novidades do Turso. Retorna false quando não
  /// há conexão configurada ou a sincronização falhou (ex: sem internet) —
  /// nesse caso os dados locais ficam intactos e dá pra tentar de novo.
  /// No modo remoto (sem cache local) não há o que empurrar: só renova o
  /// cache do catálogo em memória.
  Future<bool> sincronizar() async {
    // Réplica divergente: sincronizar de novo é repetir o erro que a condenou.
    // Antes esta tentativa ainda "curava" o estado no fim, reabrindo o portão
    // de escrita sobre uma réplica que o servidor recusa.
    if (_coordenador.recuperacaoTravada) {
      _ultimoErroSync = _erroRecuperacao;
      return false;
    }
    if (_coordenador.syncReservado) {
      _ultimoErroSync = 'já existe uma sincronização em andamento';
      return false;
    }
    final operacao = _coordenador.executarSincronizacao(_sincronizarExclusiva);
    return operacao
        .timeout(
          _timeoutSync,
          onTimeout: () {
            _ultimoErroSync = 'a sincronização continua em segundo plano; aguarde antes de tentar novamente';
            return false;
          },
        )
        .catchError((Object e) {
          // A trava pode ter subido entre a checagem acima e a reserva. Quem
          // explica é o próprio estado da exceção, não um palpite.
          final recusa = e as ReplicaNaoProntaParaEscrita;
          _ultimoErroSync = recusa.estado == EstadoReplica.recuperacaoNecessaria
              ? _erroRecuperacao
              : recusa.toString();
          return false;
        }, test: (e) => e is ReplicaNaoProntaParaEscrita);
  }

  static const String _erroRecuperacao =
      'a réplica divergiu do banco e os dados locais foram preservados; '
      'use "Revisar recuperação" em ⚙️ para recuperar';

  Future<bool> _sincronizarExclusiva() async {
    if (!await _garantirConexao()) {
      final prefs = await SharedPreferences.getInstance();
      final configurado =
          (prefs.getString(keyDbUrl) ?? '').isNotEmpty &&
          (prefs.getString(keyDbToken) ?? '').isNotEmpty;
      _ultimoErroSync = configurado
          ? 'sem conexão com o banco — verifique a internet'
          : 'configure URL e token do banco em ⚙️';
      return false;
    }
    _sincronizando = true;
    _ultimoAvisoSync = null;
    // Zerado no começo: o número mostrado no fim tem de ser o DESTA rodada.
    // Sem isso, um sync remoto (que não empurra nada) herdaria a contagem do
    // sync local anterior e diria "3 gravações enviadas" sem ter enviado uma.
    _enviadasNoUltimoSync = 0;
    try {
      final erro = await _tentarSincronizar();
      if (erro == null) {
        // O sync deu certo; agora o servidor é quem diz o que de fato chegou.
        // É esta consulta — ao REMOTO — que fecha o ciclo de cada mutação.
        await confirmarMutacoesNoRemoto();
        _ultimoErroSync = null;
        return true;
      }
      // Divergência nunca autoriza destruição silenciosa. Sem uma outbox com
      // ACK remoto, nem mesmo sabemos quais frames seriam perdidos.
      if (_modoLocal && erroDeReplicaDivergente(erro)) {
        await _exigirRecuperacao();
        _ultimoErroSync = _erroRecuperacao;
        return false;
      }
      _ultimoErroSync = descreverErroSync(erro);
      return false;
    } finally {
      _sincronizando = false;
    }
  }

  /// Uma tentativa de sincronização: devolve null se deu certo, ou o erro (sem
  /// traduzir) para quem chama decidir se dá para reagir a ele.
  Future<Object?> _tentarSincronizar() async {
    try {
      if (_modoLocal && _basePendente) {
        // A base nunca foi estabelecida (primeira abertura sem internet, ou
        // reconstrução recente): puxa tudo e só então grava esquema e
        // migrações — nunca o contrário. Ver _estabelecerBaseLocal.
        await _estabelecerBaseLocal(_client!, _timeoutSync);
        return null;
      }
      if (_modoLocal) {
        final erroDoEnvio = await _sincronizarReplica();
        if (erroDoEnvio != null) return erroDoEnvio;
      } else {
        // Modo remoto: não existe replica para empurrar nem puxar, então este
        // ramo NUNCA tocava a rede — só recarregava caches e devolvia sucesso.
        // Era o "Sincronizado ✓" instantâneo e vazio, com ou sem internet.
        // O que dá para conferir aqui é o que importa: o banco online responde?
        if (!await _clienteRespondendo())
          return const SincronizacaoNaoConfirmada();
      }
      await _consultaCache.atualizar();
      // O sync pode ter trazido paletes cadastrados em outro dispositivo.
      await PaleteRegistry().carregar();
      // Antes do dataRevision — ver a nota em _estabelecerBaseLocal.
      _invalidarCachesDeLeitura();
      await _registrarSincronizacao();
      dataRevision.value++;
      return null;
    } catch (e) {
      return e;
    }
  }

  /// Roda o `client.sync()` e CONFERE que ele de fato falou com o servidor.
  /// Devolve null quando o sync foi confirmado, ou o erro a reportar.
  ///
  /// A conferência existe porque o `sync()` do libsql devolve sucesso quando a
  /// requisição HTTP não completa — era ele que fazia o botão Sincronizar
  /// responder "Sincronizado ✓" em segundos, sem rede, sem ter enviado nada.
  ///
  /// Quem julga é o CARIMBO (ver `compararCarimbos`): a mesma consulta nos
  /// dois lados, comparada. Ele responde a pergunta que interessa — "o que
  /// está no banco está aqui, e o que está aqui está lá?" — e responde sobre
  /// os dados, não sobre contadores.
  ///
  /// O `-info` ficou de reserva, para quando não dá para carimbar. Ele conta o
  /// que o libsql moveu, e isso ENGANA nos dois sentidos: um pull também move
  /// o frame (parece push aceito) e uma gravação que não mudou byte nenhum não
  /// move nada, deixando o contador de pendências preso em 1 para sempre —
  /// que era o app acusando "o envio não saiu" a cada toque, sem ter o que
  /// enviar. Carimbos iguais desfazem essa acusação: se o banco tem tudo o que
  /// o aparelho tem, não há envio preso, e o contador estava velho.
  Future<Object?> _sincronizarReplica() async {
    final antes = await _estadoAtualDaReplica();
    await _syncNativo(_client!);
    final peloFrame = avaliarSync(
      antes: antes,
      depois: await _estadoAtualDaReplica(),
      gravacoesPendentes: _gravacoesPendentes,
    );

    // Sem carimbo remoto e sem `SELECT 1` não houve conversa nenhuma: é o modo
    // avião, em que o sync volta calado e sem erro.
    var conferencia = await _conferirCarimbos();
    if (!conferencia.bancoRespondeu) {
      return SincronizacaoNaoConfirmada(_gravacoesPendentes);
    }

    if (_carimboAcusaAtraso(conferencia.resultado)) {
      // Um pull que veio pela metade costuma completar na tentativa seguinte,
      // e um push preso sobe nela. Só depois disso a diferença vira erro.
      debugPrint(
        '[turso] carimbo diferente em '
        '${conferencia.tabelas.join(", ")} '
        '(${conferencia.resultado.name}) — tentando de novo',
      );
      await _syncNativo(_client!);
      conferencia = await _conferirCarimbos();
      if (_carimboAcusaAtraso(conferencia.resultado)) {
        return DadosForaDeSincronia(conferencia.resultado, conferencia.tabelas);
      }
    } else if (conferencia.resultado == ConferenciaDoCarimbo.indeterminada) {
      // Fail-closed: avanço de frame não é reconhecimento das mutações.
      return SincronizacaoNaoConfirmada(_gravacoesPendentes, true);
    } else if (_gravacoesPendentes > 0) {
      // Carimbos iguais: está tudo lá. Se ainda havia pendência contada, ela
      // era de uma gravação que não mudou nada (DELETE de zero linha, UPDATE
      // sem efeito) — some no _zerarGravacoesPendentes logo abaixo.
      debugPrint(
        '[turso] carimbos iguais com $_gravacoesPendentes '
        'pendente(s) contada(s): contador velho, zerando',
      );
    }

    // O número do snackbar só vale se frames REALMENTE subiram. Contador velho
    // (pendência de gravação que não mudou nada) diria "1 enviada" sem ter
    // enviado — de novo o app se gabando de trabalho que não fez. Na dúvida,
    // fica no "Sincronizado ✓" sem número.
    _enviadasNoUltimoSync = peloFrame == ResultadoDoSync.confirmado
        ? _gravacoesPendentes
        : 0;
    await _zerarGravacoesPendentes();
    return null;
  }

  /// True quando a conferência do carimbo apontou atraso de um dos lados.
  /// `indeterminada` fica de fora de propósito: não dá para acusar atraso sem
  /// ter conseguido carimbar — e o banco já respondeu, que era a dúvida antiga.
  bool _carimboAcusaAtraso(ConferenciaDoCarimbo conferencia) =>
      conferencia != ConferenciaDoCarimbo.iguais &&
      conferencia != ConferenciaDoCarimbo.indeterminada;

  /// Confere rede e proteção antes de permitir reconstruir a réplica.
  /// Falhas preservam o cache. A checagem é repetida sob exclusão mútua.
  Future<void> verificarProtecaoParaRecuperar() async {
    await init();
    if (!_modoLocal) {
      final legado = await _conectarComCacheLocal(
        _urlConfigurada ?? '',
        _tokenAtivo ?? '',
      );
      if (legado == null) {
        if (_gravacoesPendentes > 0 || (await mutacoesPendentes()).isNotEmpty) {
          throw StateError(
            'Não foi possível conferir o arquivo antigo. Ele foi preservado.',
          );
        }
      } else {
        try {
          await _verificarProtecaoLegada(legado);
        } finally {
          await legado.dispose();
        }
        return;
      }
    }
    await _verificarProtecaoLegada(null);
  }

  Future<void> _verificarProtecaoLegada(LibsqlClient? legado) async {
    if (!await _remotoAlcancavel()) {
      throw StateError(
        'Conecte à internet antes de recuperar. O cache foi preservado.',
      );
    }
    final abertas = await mutacoesPendentes();
    if (_gravacoesPendentes > abertas.length) {
      throw StateError(
        'Há gravações locais sem proteção comprovada. '
        'O cache foi preservado; confira essas alterações antes de recuperar.',
      );
    }
    if (legado != null) {
      final carimbos = await legado.query(
        'SELECT uuid FROM app_mutacoes_aplicadas',
      );
      final vistosLocalmente = {for (final linha in carimbos) linha['uuid']};
      for (final m in abertas) {
        if (!vistosLocalmente.contains(m.uuid)) {
          await _outbox.marcar(m.uuid, EstadoMutacao.revisaoManual);
        }
      }
      final registradas = await _outbox.todosUuids();
      // Apenas carimbos ainda ausentes do servidor precisam de proteção local.
      final remoto = await _sondaRemota();
      if (remoto == null)
        throw StateError('Conecte à internet antes de recuperar.');
      for (final linha in carimbos) {
        final uuid = linha['uuid'];
        if (registradas.contains(uuid)) continue;
        final enviadas = await remoto
            .query(
              'SELECT uuid FROM app_mutacoes_aplicadas WHERE uuid = ?',
              positional: [uuid],
            )
            .timeout(_timeoutConexao);
        if (enviadas.isEmpty) {
          throw StateError(
            'Uma gravação local não está protegida. O cache foi preservado.',
          );
        }
      }
    }
  }

  Future<bool> limparCacheLocal() => _coordenador.executarRecuperacao(() async {
    await _aguardarSyncNativo();
    await verificarProtecaoParaRecuperar();
    return _limparCacheLocal();
  });

  Future<bool> _limparCacheLocal() async {
    final clienteAntigo = _client;

    if (clienteAntigo != null) {
      try {
        await clienteAntigo.dispose();
      } catch (_) {
        throw StateError(
          'Não foi possível fechar o cache com segurança. Recuperação cancelada.',
        );
      }
    }

    _connected = false;
    _client = null;
    // A de escrita foi aberta com as credenciais antigas.
    _clienteEscrita = null;
    _urlAtiva = null;
    _tokenAtivo = null;
    _modoLocal = false;
    _basePendente = false;
    _ultimoErroSync = null;
    _ultimoAvisoSync = null;
    _invalidarCachesDeLeitura();

    // Cópia fechada e independente, incluindo os sidecars, antes da exclusão.
    // Falha ao copiar interrompe a recuperação e mantém os originais.
    final caminho = await _caminhoCacheLocal();
    final arquivo = File(caminho);
    final pastaBackup = Directory(
      '${arquivo.parent.path}/recuperacao_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await pastaBackup.create();
    final nome = arquivo.uri.pathSegments.last;
    await for (final item in arquivo.parent.list(followLinks: false)) {
      if (item is File && item.uri.pathSegments.last.startsWith(nome)) {
        final copia = await item.copy(
          '${pastaBackup.path}/${item.uri.pathSegments.last}',
        );
        if (await copia.length() != await item.length()) {
          throw StateError(
            'Não foi possível preservar o cache. Recuperação cancelada.',
          );
        }
      }
    }
    if (!await _apagarArquivosDaReplica()) return false;

    _ultimaSincronizacao = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyUltimaSync);
    // A proteção foi verificada e o cache anterior foi copiado. Só agora
    // a reconstrução explícita pode remover a marca de divergência.
    await prefs.remove(_chavePorBanco(keyRecuperacaoNecessaria));
    _coordenador.concluirRecuperacao();
    // A outbox NÃO foi apagada junto (ela mora noutro arquivo, é esse o
    // ponto). Quem reconecta é o init do chamador; a reaplicação vem depois
    // dele, em reaplicarOutbox.

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

  Future<bool> _migrarEsquemaLabelsEstante3(LibsqlClient client) async {
    try {
      final stmtCheck = await client.prepare(
        'SELECT 1 FROM app_migrations WHERE nome = ? LIMIT 1',
      );
      final jaAplicada = (await stmtCheck.query(
        positional: [_migracaoEstante3],
      )) as List<dynamic>;
      if (jaAplicada.isNotEmpty) return true;

      final stmtUpdate = await client.prepare(
        'UPDATE estante_layout SET nivel = nivel + 1 WHERE estante_num = 3',
      );
      await stmtUpdate.query();

      final stmtInsert = await client.prepare(
        'INSERT INTO app_migrations (nome, aplicada_em) VALUES (?, ?)',
      );
      await stmtInsert.query(
        positional: [_migracaoEstante3, DateTime.now().toIso8601String()],
      );
      return true;
    } catch (_) {
      // Se a migração falhar, não derruba a conexão — só tenta de novo no
      // próximo init().
      return false;
    }
  }

  // Chegada dos paletes cadastráveis dinamicamente (tabela `paletes`). A
  // criação da tabela em si é idempotente e mora em _criarEsquema; este
  // marcador registra em app_migrations QUANDO o esquema de paletes entrou
  // no banco, seguindo o padrão da migração da Estante 3.
  static const String _migracaoPaletes = 'paletes_cadastro_dinamico_v1';

  Future<bool> _migrarPaletesCadastroDinamico(LibsqlClient client) async {
    try {
      final stmtCheck = await client.prepare(
        'SELECT 1 FROM app_migrations WHERE nome = ? LIMIT 1',
      );
      final jaAplicada = (await stmtCheck.query(
        positional: [_migracaoPaletes],
      )) as List<dynamic>;
      if (jaAplicada.isNotEmpty) return true;

      final stmtInsert = await client.prepare(
        'INSERT INTO app_migrations (nome, aplicada_em) VALUES (?, ?)',
      );
      await stmtInsert.query(
        positional: [_migracaoPaletes, DateTime.now().toIso8601String()],
      );
      return true;
    } catch (_) {
      // Se a migração falhar, não derruba a conexão — só tenta de novo no
      // próximo init().
      return false;
    }
  }

  /// True enquanto o catálogo em cache pode ser servido sem reconsultar.
  ///
  /// No modo local a validade não é por relógio: a base do dispositivo só muda
  /// via `client.sync()`, que só acontece em `sincronizar()` e
  /// `_estabelecerBaseLocal` — e os dois zeram o cache. Cache não-nulo ali
  /// significa "em dia", ponto. O TTL fica valendo só no modo remoto, onde um
  /// app irmão pode alterar o estoque_mestre por fora sem avisar.
  bool get _catalogoEmCacheValido {
    final em = _produtosCacheEm;
    if (_produtosCache == null || em == null) return false;
    return _modoLocal || DateTime.now().difference(em) < _produtosCacheTtl;
  }

  Future<List<Produto>> fetchProdutos({bool forceRefresh = false}) async {
    // Antes do _garantirConexao: um cache quente não tem por que esperar o
    // init() terminar.
    if (!forceRefresh && _catalogoEmCacheValido) return _produtosCache!;

    // Uma leitura de cada vez. Na abertura do app o prewarm, o mapa e o
    // carrossel pedem o catálogo quase juntos, todos com o cache frio: sem
    // esta costura saíam três SELECTs de até 5000 linhas em paralelo pela
    // mesma rede, e o usuário esperava o mais lento dos três.
    final emAndamento = _catalogoEmAndamento;
    if (emAndamento != null && !forceRefresh) return emAndamento;

    final leitura = _lerCatalogo(forceRefresh: forceRefresh);
    _catalogoEmAndamento = leitura;
    try {
      return await leitura;
    } finally {
      // Só limpa se ainda for a leitura desta chamada: um forceRefresh
      // concorrente pode ter posto outra no lugar.
      if (identical(_catalogoEmAndamento, leitura)) _catalogoEmAndamento = null;
    }
  }

  /// Decide DE ONDE o catálogo vem: da cópia em disco (instantânea) ou do
  /// banco. Ver `_lerCatalogoDoDisco` para o porquê da cópia existir.
  Future<List<Produto>> _lerCatalogo({required bool forceRefresh}) async {
    final prefs = await SharedPreferences.getInstance();
    _urlConfigurada = prefs.getString(keyDbUrl) ?? '';
    if (!forceRefresh) {
      final disco = await _lerCatalogoDoDisco();
      if (disco != null) {
        _produtosCache = disco;
        _produtosCacheEm = DateTime.now();
        unawaited(_revalidarCatalogo());
        return disco;
      }
    }
    if (!await _garantirConexao()) {
      // Sem conexão configurada ou sem rede na primeira abertura: a cópia em
      // disco é a diferença entre uma busca de produto que funciona e uma
      // lista vazia sem explicação.
      return _produtosCache ?? await _lerCatalogoDoDisco() ?? const [];
    }

    // Bootstrap pelo disco: vale UMA vez por sessão, e só enquanto o banco
    // ainda não foi lido. Depois de um sincronizar() (que zera o cache de
    // propósito, porque os dados mudaram) a cópia em disco está velha por
    // definição — ali a consulta ao banco é obrigatória.
    if (!forceRefresh && !_catalogoLidoDoBanco && _produtosCache == null) {
      final doDisco = await _lerCatalogoDoDisco();
      if (doDisco != null && doDisco.isNotEmpty) {
        _produtosCache = doDisco;
        _produtosCacheEm = DateTime.now();
        // Devolve agora e confere com o banco atrás: quem abriu o app já pode
        // buscar produto enquanto as 5000 linhas viajam.
        unawaited(_revalidarCatalogo());
        return doDisco;
      }
    }
    return _consultarCatalogo();
  }

  /// Relê o catálogo do banco depois de ter servido a cópia em disco, e só
  /// avisa as telas se ele mudou de verdade — `dataRevision` recarrega todas
  /// as cenas, e fazer isso a cada abertura do app anularia o ganho.
  Future<void> _revalidarCatalogo() async {
    try {
      final anterior = _produtosCache;
      final atual = await _consultarCatalogo();
      if (anterior != null && !catalogosIguais(anterior, atual)) {
        dataRevision.value++;
      }
    } catch (_) {
      // Revalidação é best-effort: falhou, fica valendo a cópia em disco até
      // o próximo Sincronizar.
    }
  }

  /// Lê o catálogo do banco (a consulta de verdade) e atualiza os dois caches.
  Future<List<Produto>> _consultarCatalogo() async {
    if (!await _garantirConexao()) return _produtosCache ?? const [];

    final cache = _produtosCache;
    try {
      // Sem ORDER BY: estoque_mestre é de outro app e não tem índice em
      // `produto`, então ordenar no banco montava uma b-tree temporária a cada
      // leitura fria. A ordenação em Dart logo abaixo dá o mesmo resultado —
      // a colação BINARY do SQLite e o String.compareTo do Dart são ambos por
      // code point — e a ordem importa rio abaixo (produtosComCaixa documenta
      // "mantém a ordem do catálogo", e o autocomplete faz .take(8)).
      //
      // A leitura é a MESMA do saldo (`consultarSaldos`, que traz também o
      // qtd_sistema): uma ida ao estoque_mestre alimenta o catálogo, o saldo
      // do galpão, o diálogo de quantidade e a baixa. Antes eram quatro
      // leituras da tabela inteira na abertura do app e do galpão. O teto de
      // 5000 do catálogo continua, aplicado aqui.
      //
      // Só vai ao banco se a cópia passou da janela desde a última leitura
      // que deu certo — mesmo vinda do disco de uma sessão anterior. Forçar
      // sempre furava a janela: o Sincronizar lia o estoque_mestre duas
      // vezes, e cada vencimento do catálogo lia de novo uma tabela que
      // alguém tinha acabado de ler.
      final produtos = await cronometrar('fetchProdutos', () async {
        final rows = await consultarSaldos(atualizarSeVencida: true);
        return rows.take(5000).map((r) {
          final cat = r['categoria'] as String? ?? '';
          final corHex = categoriaCores[cat] ?? '#888888';
          return Produto(
            codigo: r['codigo'] as String? ?? '',
            nome: r['produto'] as String? ?? '',
            categoria: cat,
            corHex: corHex,
          );
        }).toList()..sort((a, b) => a.nome.compareTo(b.nome));
      });
      _produtosCache = produtos;
      _produtosCacheEm = DateTime.now();
      _catalogoLidoDoBanco = true;
      // Só grava quando mudou: reescrever ~300 KB a cada leitura idêntica
      // gastaria disco (e bateria) sem trocar um byte de conteúdo.
      if (cache == null || !catalogosIguais(cache, produtos)) {
        unawaited(_gravarCatalogoNoDisco(produtos));
      }
      return produtos;
    } catch (_) {
      return cache ?? const [];
    }
  }

  Future<String> _caminhoCatalogo() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/camda_catalogo.json';
  }

  /// Catálogo salvo em disco na última leitura do banco, ou null se não há
  /// cópia utilizável.
  ///
  /// Existe por causa da abertura fria: sem cache local (Web, preferência
  /// desligada, primeira instalação) o catálogo é um SELECT de até 5000 linhas
  /// que atravessa a rede antes de qualquer busca de produto funcionar — é o
  /// "demora demais para carregar os produtos" de quem usa o app no galpão.
  /// Com a cópia em disco, a segunda abertura em diante mostra a lista na hora
  /// e confere com o banco em segundo plano.
  ///
  /// A cópia é carimbada com a URL do banco: trocar de banco em ⚙️ tem de
  /// invalidar o catálogo, senão o app mostraria os produtos do banco anterior.
  Future<List<Produto>?> _lerCatalogoDoDisco() async {
    if (kIsWeb) return null; // sem filesystem
    try {
      final arquivo = File(await _caminhoCatalogo());
      if (!await arquivo.exists()) return null;
      final json = jsonDecode(await arquivo.readAsString());
      if (json is! Map) return null;
      if (json['versao'] != _versaoCatalogoEmDisco) return null;
      if (json['url'] != (_urlConfigurada ?? '')) return null;
      final itens = json['itens'];
      if (itens is! List) return null;
      return [
        for (final dynamic item in itens)
          if (item is List && item.length == 3)
            Produto(
              codigo: item[0] as String? ?? '',
              nome: item[1] as String? ?? '',
              categoria: item[2] as String? ?? '',
              corHex: categoriaCores[item[2] as String? ?? ''] ?? '#888888',
            ),
      ];
    } catch (_) {
      // Arquivo truncado ou de outra versão do app: melhor ignorar e consultar
      // o banco do que servir lixo.
      return null;
    }
  }

  Future<void> _gravarCatalogoNoDisco(List<Produto> produtos) async {
    if (kIsWeb) return;
    try {
      // Triplas posicionais em vez de objetos: repetir os nomes das três
      // colunas em 5000 linhas quase dobra o tamanho do arquivo — e o que se
      // quer aqui é justamente uma leitura curta na abertura.
      final dados = jsonEncode({
        'versao': _versaoCatalogoEmDisco,
        'url': _urlConfigurada ?? '',
        'itens': [
          for (final p in produtos) [p.codigo, p.nome, p.categoria],
        ],
      });
      // Grava num temporário e renomeia: o rename é atômico, então uma queda
      // no meio da escrita não deixa meio catálogo no lugar do inteiro.
      final caminho = await _caminhoCatalogo();
      final temp = File('$caminho.tmp');
      await temp.writeAsString(dados, flush: true);
      await temp.rename(caminho);
    } catch (_) {
      // Cache de disco é otimização: falhar aqui não pode atrapalhar quem já
      // recebeu a lista.
    }
  }

  CaixaLayout _caixaLayoutDaLinha(Map<String, dynamic> r, int gondolaNum) =>
      CaixaLayout(
        gondolaNum: r['gondola_num'] as int? ?? gondolaNum,
        andar: r['andar'] as int? ?? 0,
        produtoCodigo: r['produto_codigo'] as String? ?? '',
        produtoNome: r['produto_nome'] as String? ?? '',
        posX: (r['pos_x'] as num?)?.toDouble() ?? 0,
        posZ: (r['pos_z'] as num?)?.toDouble() ?? 0,
        corHex: r['cor_hex'] as String? ?? '#888888',
      );

  static const String _colunasLayoutGondola =
      'gondola_num, andar, produto_codigo, produto_nome, pos_x, pos_z, cor_hex';
  static const String _colunasLayoutEstante =
      'estante_num, coluna, nivel, slot, produto_codigo, produto_nome, cor_hex';

  /// Cópias completas das duas tabelas de layout: servem a busca do mapa, o
  /// prewarm e a cena de cada estrutura (ver [LayoutsDaCopia]). Ordem de id,
  /// que é a da varredura (sem ordenação no banco) e a de cada estrutura.
  /// Nomes novos de propósito: as cópias antigas da busca (DISTINCT, sem cor)
  /// ficaram no disco com outro formato.
  static const String chaveLayoutsGondola = 'layouts_gondola_v1';
  static const String sqlLayoutsGondola =
      'SELECT $_colunasLayoutGondola FROM gondola_layout ORDER BY id';
  static const String chaveLayoutsEstante = 'layouts_estante_v1';
  static const String sqlLayoutsEstante =
      'SELECT $_colunasLayoutEstante FROM estante_layout ORDER BY id';

  /// Lê a cópia completa de layouts. Janela de tabela grande (a busca relê
  /// ao buscar, a cena relê a estrutura aberta), fora da volta ao app.
  ///
  /// [paraPrewarm]: espera a releitura quando a cópia passou da janela, e,
  /// sem rede, aceita a cópia que houver — sem cópia nenhuma, lança.
  Future<List<Map<String, dynamic>>> _copiaDeLayouts({
    required bool gondola,
    bool paraPrewarm = false,
  }) async {
    Future<List<Map<String, dynamic>>> ler({bool atualizarSeVencida = false}) =>
        consultarComCache(
          gondola ? chaveLayoutsGondola : chaveLayoutsEstante,
          gondola ? sqlLayoutsGondola : sqlLayoutsEstante,
          janela: janelaTabelaGrande,
          falharSemCache: paraPrewarm,
          atualizarSeVencida: atualizarSeVencida,
          releNaVolta: false,
        );
    if (!paraPrewarm) return ler();
    try {
      return await ler(atualizarSeVencida: true);
    } catch (_) {
      return ler();
    }
  }

  /// Layout da gôndola já em memória, ou null se nada se sabe dela ainda.
  /// Síncrono de propósito: é o que permite semear a cena no mesmo frame do
  /// toque. Lista vazia é "a gôndola não tem caixas" — nunca "não carregou".
  List<CaixaLayout>? layoutEmCache(int gondolaNum) => _layoutsGondola
      .linhasEmMemoria(gondolaNum)
      ?.map((r) => _caixaLayoutDaLinha(r, gondolaNum))
      .toList();

  /// O layout da gôndola em dia (relê só ela, pelo índice, quando passou da
  /// janela). Sem rede, o que houver na cópia; sem rede e sem cópia, LANÇA:
  /// mostrar a gôndola vazia deixaria um "Salvar layout" apagar a de verdade.
  Future<List<CaixaLayout>> fetchLayout(
    int gondolaNum, {
    bool forceRefresh = false,
  }) async {
    final rows = await _layoutsGondola.linhas(
      gondolaNum,
      forcar: forceRefresh,
    );
    return rows.map((r) => _caixaLayoutDaLinha(r, gondolaNum)).toList();
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

  static const SalvamentoLayout _salvamentoFalhou = (
    resultado: ResultadoSalvarLayout.falhou,
    codigosAntes: <String>{},
  );

  /// Grava o layout inteiro da gôndola (apaga e regrava a estrutura).
  ///
  /// [base] é o layout que a tela carregou antes da edição. Se o banco já não
  /// está igual a ela, outro aparelho salvou no meio: nada é gravado e volta
  /// [ResultadoSalvarLayout.conflito] — antes, o último a salvar apagava a
  /// edição do outro sem aviso nenhum. [sobrescrever] grava assim mesmo (a
  /// pessoa escolheu "Salvar por cima").
  Future<SalvamentoLayout> salvarLayout(
    int gondolaNum,
    List<CaixaLayout> itens, {
    required List<CaixaLayout> base,
    bool sobrescrever = false,
  }) async {
    try {
      return await garantirReplicaProntaParaEscrita(
        () => _salvarLayout(
          gondolaNum,
          itens,
          base: base,
          sobrescrever: sobrescrever,
        ),
      );
    } catch (_) {
      return _salvamentoFalhou;
    }
  }

  Future<SalvamentoLayout> _salvarLayout(
    int gondolaNum,
    List<CaixaLayout> itens, {
    required List<CaixaLayout> base,
    required bool sobrescrever,
  }) async {
    if (!await _garantirConexao()) return _salvamentoFalhou;
    // IMMEDIATE: a trava de escrita vem já no BEGIN, então nenhum outro
    // aparelho grava entre a conferência abaixo e o DELETE.
    final tx = await _client!.transaction(
      behavior: LibsqlTransactionBehavior.immediate,
    );
    MutacaoOutbox? mutacao;
    try {
      // O layout de antes, lido dentro da própria transação: é com ele que a
      // base da tela é conferida, e é dele que saem os produtos removidos.
      final antes = await tx.query(
        'SELECT andar, produto_codigo, pos_x, pos_z FROM gondola_layout '
        'WHERE gondola_num = ? ORDER BY andar, pos_x, pos_z',
        positional: [gondolaNum],
      );
      contarLeitura('salvar_layout', antes.length);
      // Produtos que podem ter saído: os do banco agora e os da base da tela.
      // A base conta para o caso de uma tentativa anterior ter gravado sem a
      // resposta chegar — aí o banco já está sem o produto removido, e a
      // limpeza dos endereços zerados dele não pode se perder.
      final codigosAntes = {
        for (final r in antes) r['produto_codigo'] as String? ?? '',
        for (final c in base) c.produtoCodigo,
      }..remove('');
      Map<String, dynamic> linha(CaixaLayout c) => {
        'andar': c.andar,
        'produto_codigo': c.produtoCodigo,
        'pos_x': c.posX,
        'pos_z': c.posZ,
      };
      final mudouNoBanco = layoutMudouPorBaixo(
        noBanco: antes,
        base: base.map(linha),
        itens: itens.map(linha),
        colunas: colunasConteudoGondola,
      );
      if (mudouNoBanco && !sobrescrever) {
        await tx.rollback();
        // A cópia deste aparelho está velha: a próxima abertura relê.
        _layoutsGondola.suja(gondolaNum);
        return (
          resultado: ResultadoSalvarLayout.conflito,
          codigosAntes: codigosAntes,
        );
      }
      await tx.execute(
        'DELETE FROM gondola_layout WHERE gondola_num = ?',
        positional: [gondolaNum],
      );

      // INSERT multi-linha: uma ida ao servidor por lote em vez de uma por
      // caixa. Além de rápido, encurta a janela em que uma queda de rede
      // deixaria o layout salvo pela metade após o DELETE acima.
      final agora = DateTime.now().toIso8601String();
      for (var i = 0; i < itens.length; i += _maxLinhasPorInsert) {
        final fim = (i + _maxLinhasPorInsert < itens.length)
            ? i + _maxLinhasPorInsert
            : itens.length;
        final lote = itens.sublist(i, fim);
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
        await tx.execute(
          'INSERT INTO gondola_layout '
          '(gondola_num, andar, produto_codigo, produto_nome, pos_x, pos_z, cor_hex, registrado_em) '
          'VALUES ${List.filled(lote.length, '(?, ?, ?, ?, ?, ?, ?, ?)').join(', ')}',
          positional: params,
        );
      }
      mutacao = await abrirMutacao(
        operacao: 'layout.salvarGondola',
        tabela: 'gondola_layout',
        chave: {'gondola_num': gondolaNum},
        estadoAnterior: {'itens': _resumoLayout(antes)},
        estadoFinal: {
          'itens': _resumoLayout([
            for (final i in itens)
              {
                'andar': i.andar,
                'produto_codigo': i.produtoCodigo,
                'pos_x': i.posX,
                'pos_z': i.posZ,
              },
          ]),
        },
        posicao: gondolaNum,
      );
      await carimbarMutacao(tx, mutacao);
      await confirmarCommit(tx, mutacao);
      // Write-through: as linhas recém-gravadas SÃO o novo estado persistido,
      // então dá para corrigir a cópia sem reler.
      await _layoutsGondola.salva(gondolaNum, [
        for (final i in itens)
          {
            'gondola_num': gondolaNum,
            'andar': i.andar,
            'produto_codigo': i.produtoCodigo,
            'produto_nome': i.produtoNome,
            'pos_x': i.posX,
            'pos_z': i.posZ,
            'cor_hex': i.corHex,
          },
      ]);
      // Layout não grava estoque_localizado (o produto que sai é tratado à
      // parte, por deleteEnderecosZerados, que corrige a cópia sozinho). Só a
      // cópia dos layouts pode ter ficado velha numa leitura no ar.
      await marcarGravacaoLocal(
        expirarQuantidades: false,
        chavesAfetadas: {chaveLayoutsGondola},
      );
      return (resultado: ResultadoSalvarLayout.salvo, codigosAntes: codigosAntes);
    } catch (_) {
      try {
        await tx.rollback();
      } catch (_) {}
      if (mutacao != null) await abortarMutacao(mutacao);
      // Resposta perdida não prova que não gravou: a próxima abertura relê.
      _layoutsGondola.suja(gondolaNum);
      return _salvamentoFalhou;
    }
  }

  CaixaLayoutEstante _caixaLayoutEstanteDaLinha(
    Map<String, dynamic> r,
    int estanteNum,
  ) => CaixaLayoutEstante(
    estanteNum: r['estante_num'] as int? ?? estanteNum,
    coluna: r['coluna'] as int? ?? 0,
    nivel: r['nivel'] as int? ?? 0,
    slot: r['slot'] as int? ?? 0,
    produtoCodigo: r['produto_codigo'] as String? ?? '',
    produtoNome: r['produto_nome'] as String? ?? '',
    corHex: r['cor_hex'] as String? ?? '#888888',
  );

  /// Layout da estante já em memória, ou null se nada se sabe dela ainda (ver
  /// [layoutEmCache]).
  List<CaixaLayoutEstante>? layoutEstanteEmCache(int estanteNum) =>
      _layoutsEstante.linhasEmMemoria(estanteNum) == null
      ? null
      : _estanteDasLinhas(
          estanteNum,
          _layoutsEstante.linhasEmMemoria(estanteNum)!,
        );

  /// O layout da estante em dia (ver [fetchLayout]).
  Future<List<CaixaLayoutEstante>> fetchLayoutEstante(
    int estanteNum, {
    bool forceRefresh = false,
  }) async => _estanteDasLinhas(
    estanteNum,
    await _layoutsEstante.linhas(estanteNum, forcar: forceRefresh),
  );

  List<CaixaLayoutEstante> _estanteDasLinhas(
    int estanteNum,
    List<Map<String, dynamic>> rows,
  ) => rows
      .map((r) => _caixaLayoutEstanteDaLinha(r, estanteNum))
      .where((c) => !_ehBaseNelloreRemovida(c.estanteNum, c.nivel))
      .toList();

  /// Traz as duas cópias completas de layout, de fora do caminho crítico
  /// enquanto o usuário olha o mapa: duas consultas, e toda gôndola e estante
  /// abre na hora a partir delas. Antes era uma consulta por estrutura (~35)
  /// além das duas da busca, que liam as mesmas tabelas.
  ///
  /// Falha em silêncio: é otimização, não caminho obrigatório. Sem cópia, cada
  /// estrutura é lida sob demanda ao abrir.
  Future<void> precarregarLayouts() async {
    await Future.wait([
      for (final gondola in [true, false])
        _copiaDeLayouts(
          gondola: gondola,
          paraPrewarm: true,
        ).then<void>((_) {}, onError: (_) {}),
    ]);
  }

  /// Aquece os caches de leitura enquanto o usuário ainda está no mapa.
  ///
  /// Chamado logo depois do init() na abertura do app: `LojaPage` é a home e
  /// não emite trabalho de banco próprio, então essa janela é livre. É o que
  /// faz a primeira abertura de uma cena custar o mesmo que as seguintes.
  ///
  /// Uma vez por sessão e por banco: cada "Ver no mapa" cria uma LojaPage
  /// nova, e cada uma pedia tudo de novo (os ~35 layouts de janela curta
  /// quase sempre vencidos). Nada do que ele lê conta como uso para a volta
  /// ao app (ver [ConsultaCache.semMarcarUso]) — só o que uma tela de fato
  /// abrir.
  Future<void> prewarm() async {
    if (!_connected) return;
    final banco = _identidadeAtiva;
    if (banco != null && _prewarmFeitoEm == banco) return;
    await ConsultaCache.semMarcarUso(() async {
      await _precarregarBusca();
      await precarregarLayouts();
      await fetchProdutos();
    });
    _prewarmFeitoEm = banco;
  }

  // Banco em que o prewarm já rodou nesta sessão (zerado na troca de banco e
  // no Sincronizar, junto com os outros caches de leitura).
  String? _prewarmFeitoEm;

  /// Grava o layout inteiro da estante, com a mesma conferência da base que
  /// [salvarLayout].
  Future<SalvamentoLayout> salvarLayoutEstante(
    int estanteNum,
    List<CaixaLayoutEstante> itens, {
    required List<CaixaLayoutEstante> base,
    bool sobrescrever = false,
  }) async {
    try {
      return await garantirReplicaProntaParaEscrita(
        () => _salvarLayoutEstante(
          estanteNum,
          itens,
          base: base,
          sobrescrever: sobrescrever,
        ),
      );
    } catch (_) {
      return _salvamentoFalhou;
    }
  }

  Future<SalvamentoLayout> _salvarLayoutEstante(
    int estanteNum,
    List<CaixaLayoutEstante> itens, {
    required List<CaixaLayoutEstante> base,
    required bool sobrescrever,
  }) async {
    if (!await _garantirConexao()) return _salvamentoFalhou;
    final tx = await _client!.transaction(
      behavior: LibsqlTransactionBehavior.immediate,
    );
    MutacaoOutbox? mutacao;
    try {
      final antes = await tx.query(
        'SELECT coluna, nivel, slot, produto_codigo FROM estante_layout '
        'WHERE estante_num = ? ORDER BY coluna, nivel, slot',
        positional: [estanteNum],
      );
      contarLeitura('salvar_layout', antes.length);
      // A base da tela nunca tem a base do Expositor Nellore (nível 0, fora
      // dos endereços): as linhas antigas dela não contam como diferença, e
      // este salvamento as apaga de vez.
      final antesVisiveis = [
        for (final r in antes)
          if (!_ehBaseNelloreRemovida(estanteNum, r['nivel'] as int? ?? -1)) r,
      ];
      // Ver o gêmeo em _salvarLayout: a base entra nos possíveis removidos, e
      // o banco igual ao que vai ser gravado não é conflito.
      final codigosAntes = {
        for (final r in antesVisiveis) r['produto_codigo'] as String? ?? '',
        for (final c in base) c.produtoCodigo,
      }..remove('');
      Map<String, dynamic> linha(CaixaLayoutEstante c) => {
        'coluna': c.coluna,
        'nivel': c.nivel,
        'slot': c.slot,
        'produto_codigo': c.produtoCodigo,
      };
      final mudouNoBanco = layoutMudouPorBaixo(
        noBanco: antesVisiveis,
        base: base.map(linha),
        itens: itens.map(linha),
        colunas: colunasConteudoEstante,
      );
      if (mudouNoBanco && !sobrescrever) {
        await tx.rollback();
        _layoutsEstante.suja(estanteNum);
        return (
          resultado: ResultadoSalvarLayout.conflito,
          codigosAntes: codigosAntes,
        );
      }
      await tx.execute(
        'DELETE FROM estante_layout WHERE estante_num = ?',
        positional: [estanteNum],
      );

      final agora = DateTime.now().toIso8601String();
      for (var i = 0; i < itens.length; i += _maxLinhasPorInsert) {
        final fim = (i + _maxLinhasPorInsert < itens.length)
            ? i + _maxLinhasPorInsert
            : itens.length;
        final lote = itens.sublist(i, fim);
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
        await tx.execute(
          'INSERT INTO estante_layout '
          '(estante_num, coluna, nivel, slot, produto_codigo, produto_nome, cor_hex, registrado_em) '
          'VALUES ${List.filled(lote.length, '(?, ?, ?, ?, ?, ?, ?, ?)').join(', ')}',
          positional: params,
        );
      }
      mutacao = await abrirMutacao(
        operacao: 'layout.salvarEstante',
        tabela: 'estante_layout',
        chave: {'estante_num': estanteNum},
        estadoAnterior: {'itens': _resumoLayout(antes)},
        estadoFinal: {
          'itens': _resumoLayout([
            for (final i in itens)
              {
                'coluna': i.coluna,
                'nivel': i.nivel,
                'slot': i.slot,
                'produto_codigo': i.produtoCodigo,
              },
          ]),
        },
        posicao: estanteNum,
      );
      await carimbarMutacao(tx, mutacao);
      await confirmarCommit(tx, mutacao);
      await _layoutsEstante.salva(estanteNum, [
        for (final i in itens)
          {
            'estante_num': estanteNum,
            'coluna': i.coluna,
            'nivel': i.nivel,
            'slot': i.slot,
            'produto_codigo': i.produtoCodigo,
            'produto_nome': i.produtoNome,
            'cor_hex': i.corHex,
          },
      ]);
      // Layout não grava estoque_localizado (o produto que sai é tratado à
      // parte, por deleteEnderecosZerados, que corrige a cópia sozinho).
      await marcarGravacaoLocal(
        expirarQuantidades: false,
        chavesAfetadas: {chaveLayoutsEstante},
      );
      return (resultado: ResultadoSalvarLayout.salvo, codigosAntes: codigosAntes);
    } catch (_) {
      try {
        await tx.rollback();
      } catch (_) {}
      if (mutacao != null) await abortarMutacao(mutacao);
      _layoutsEstante.suja(estanteNum);
      return _salvamentoFalhou;
    }
  }

  /// Serializa um layout inteiro numa linha de texto estável, para caber num
  /// estado da outbox. Não é para exibir: é para COMPARAR — dois layouts iguais
  /// têm de dar o mesmo texto, e a ordem vem do ORDER BY de quem leu.
  static String _resumoLayout(List<Map<String, dynamic>> linhas) => linhas
      .map((l) => (l.keys.toList()..sort()).map((k) => '$k=${l[k]}').join(','))
      .join(';');

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
      contarLeitura('busca_na_cena', (rows as List<dynamic>).length);
      final list = rows as List<dynamic>;
      if (list.isEmpty) return null;
      final r = list.first as Map<String, dynamic>;
      return CaixaLayoutEstante(
        estanteNum: r['estante_num'] as int? ?? 0,
        coluna: r['coluna'] as int? ?? 0,
        nivel: r['nivel'] as int? ?? 0,
        slot: r['slot'] as int? ?? 0,
        produtoCodigo: r['produto_codigo'] as String? ?? produtoCodigo,
        produtoNome: r['produto_nome'] as String? ?? '',
        corHex: r['cor_hex'] as String? ?? '#888888',
      );
    } catch (_) {
      return null;
    }
  }

  static const String _chaveQuantidades = 'quantidades_detalhes_v2';
  static const String _colunasQuantidades =
      'id, produto_codigo, local_tipo, local_num, face_ou_coluna, '
      'andar_ou_nivel, quantidade, atualizado_em';

  // Busca produto por nome (LIKE) em gôndola_layout E estante_layout,
  // retornando uma lista combinada (gôndolas primeiro).
  /// O estoque_localizado inteiro, da cópia de leitura, com os locais que a
  /// fila gravou desde a última vez já relidos (ver [marcarLocalGravado]).
  Future<List<Map<String, dynamic>>> consultarQuantidades({
    bool falharSemCache = false,
    bool atualizarSeVencida = false,
  }) async {
    await _corrigirQuantidadesGravadas();
    return consultarComCache(
      _chaveQuantidades,
      'SELECT $_colunasQuantidades FROM estoque_localizado',
      falharSemCache: falharSemCache,
      janela: janelaTabelaGrande,
      atualizarSeVencida: atualizarSeVencida,
    );
  }

  // Locais (local_tipo → números) que a fila gravou e cujo espelho ainda não
  // foi relido para a cópia das quantidades. Em memória: a cópia em disco de
  // uma sessão anterior é relida inteira na primeira consulta de qualquer
  // jeito (a janela começa vencida).
  final Map<String, Set<int>> _locaisGravados = {};
  Future<void>? _correcaoQuantidades;

  /// Anota que o espelho de [local] mudou no servidor. A releitura acontece
  /// na próxima [consultarQuantidades], uma só para todos os locais anotados
  /// até ali — dez paletes lançados em sequência custam uma ida, não dez.
  ///
  /// A anotação vive só em memória, então o carimbo em disco da cópia sai na
  /// hora: se o Android matar o app antes da correção, a reabertura relê a
  /// tabela em vez de servir como fresca uma cópia sem esta gravação.
  void marcarLocalGravado(String localTipo, int local) {
    _locaisGravados.putIfAbsent(localTipo, () => <int>{}).add(local);
    final chave = _chaveCompleta(_chaveQuantidades);
    if (chave != null) _consultaCache.esquecerCarimboEmDisco(chave);
  }

  Future<void> _corrigirQuantidadesGravadas() {
    if (_locaisGravados.isEmpty) return Future<void>.value();
    final emAndamento = _correcaoQuantidades;
    if (emAndamento != null) return emAndamento;
    final futuro = () async {
      while (_locaisGravados.isNotEmpty) {
        final tipo = _locaisGravados.keys.first;
        final locais = _locaisGravados.remove(tipo)!;
        await atualizarQuantidadesDosLocais(tipo, locais);
      }
    }();
    _correcaoQuantidades = futuro;
    unawaited(
      futuro.whenComplete(() {
        if (identical(_correcaoQuantidades, futuro)) {
          _correcaoQuantidades = null;
        }
      }),
    );
    return futuro;
  }

  /// Relê do servidor só as linhas de estoque_localizado de [locais] (do tipo
  /// [localTipo]) e põe na cópia de [consultarQuantidades] no lugar das
  /// antigas. True quando a cópia ficou em dia; sem ela em dia, a cópia
  /// expira e a próxima leitura busca a tabela inteira.
  ///
  /// É o que segue uma gravação da fila do galpão/barracão: o lote reescreveu
  /// o espelho dessas posições, e reler a tabela inteira para ver quatro
  /// linhas custava milhares de linhas no Turso a cada palete. O filtro é o
  /// do `idx_estoque_localizado_local`, então o banco lê só o que devolve.
  Future<bool> atualizarQuantidadesDosLocais(
    String localTipo,
    Set<int> locais,
  ) async {
    if (locais.isEmpty) return true;
    final chave = 'consulta_v1_${_identidadeAtiva}_$_chaveQuantidades';
    final cliente = await _garantirConexao() ? _client : null;
    if (cliente == null) {
      _consultaCache.expirar(chave);
      return false;
    }
    final lista = locais.toList()..sort();
    try {
      consultasEmitidas++;
      final stmt = await cliente
          .prepare(
            'SELECT $_colunasQuantidades FROM estoque_localizado '
            'WHERE local_tipo = ? AND local_num IN '
            '(${List.filled(lista.length, '?').join(', ')})',
          )
          .timeout(_timeoutConexao);
      final rows =
          await stmt
                  .query(positional: [localTipo, ...lista])
                  .timeout(_timeoutLeitura)
              as List<dynamic>;
      contarLeitura('quantidades_locais', rows.length);
      await _consultaCache.atualizarParte(
        chave,
        (r) => r['local_tipo'] == localTipo && locais.contains(r['local_num']),
        rows.map((r) => Map<String, dynamic>.from(r as Map)).toList(),
      );
      return true;
    } catch (_) {
      _renovarClienteDeLeitura(cliente);
      // A cópia ficou sem a gravação: a próxima leitura busca a tabela.
      _consultaCache.expirar(chave);
      return false;
    }
  }

  static const String _chaveSaldos = 'saldos_dialogo_v1';

  /// O estoque_mestre inteiro: código, nome, categoria e qtd_sistema.
  ///
  /// É a fonte única da tabela no app (catálogo, saldo do galpão, diálogo de
  /// quantidade, baixa), guardada por [janelaCadastro]. [forceRefresh] vai ao
  /// banco na hora e deixa a cópia nova para todos os outros.
  Future<List<Map<String, dynamic>>> consultarSaldos({
    bool forceRefresh = false,
    bool atualizarSeVencida = false,
  }) => consultarComCache(
    _chaveSaldos,
    'SELECT codigo, produto, categoria, qtd_sistema FROM estoque_mestre',
    falharSemCache: true,
    forceRefresh: forceRefresh,
    atualizarSeVencida: atualizarSeVencida,
    janela: janelaCadastro,
    somenteLeitura: true,
  );

  // Tabelas do mapa de produtos que faltam neste banco (o dashboard nunca as
  // criou). Lembrado na sessão para não gastar uma ida por saldo calculado.
  final Set<String> _tabelasDoMapaAusentes = {};

  /// Código normalizado → produto_id do mapa de produtos (principal e
  /// secundários), guardado por [janelaCadastro].
  ///
  /// As duas tabelas são criadas pelo dashboard e podem não existir num banco
  /// onde o mapa nunca foi usado; a ausência de uma não derruba a outra — sem
  /// mapa, resta o nome (ver codigos_vinculados.dart).
  ///
  /// [falharFechado]: para quem GRAVA com base nos vínculos (a baixa). Uma
  /// tabela que existe e não pôde ser lida lança em vez de sumir da conta —
  /// sem o vínculo, o código secundário seria planejado sozinho, com alvo no
  /// próprio qtd_sistema (muitas vezes 0), e os endereços dele seriam
  /// esvaziados.
  Future<Map<String, String>> vinculosDoMapa({
    bool forceRefresh = false,
    bool atualizarSeVencida = false,
    bool falharFechado = false,
  }) async {
    final vinculos = <String, String>{};
    for (final tabela in const ['mapa_produtos', 'mapa_produtos_codigos']) {
      if (_tabelasDoMapaAusentes.contains(tabela)) continue;
      try {
        final rows = await consultarComCache(
          'vinculos_$tabela',
          'SELECT produto_id, codigo FROM $tabela WHERE codigo IS NOT NULL',
          falharSemCache: true,
          forceRefresh: forceRefresh,
          atualizarSeVencida: atualizarSeVencida,
          janela: janelaCadastro,
          somenteLeitura: true,
        );
        for (final r in rows) {
          final codigo = normalizarCodigo(r['codigo']?.toString());
          final produtoId = (r['produto_id']?.toString() ?? '').trim();
          if (codigo == null || produtoId.isEmpty) continue;
          vinculos[codigo] = produtoId;
        }
      } catch (e) {
        if (erroDeTabelaAusente(e)) {
          _tabelasDoMapaAusentes.add(tabela);
          continue;
        }
        if (falharFechado) rethrow;
        // Sem conexão (ou coluna diferente): segue sem ela.
      }
    }
    return vinculos;
  }

  /// O erro é de tabela que não existe neste banco (e não de rede).
  static bool erroDeTabelaAusente(Object erro) =>
      erro.toString().toLowerCase().contains('no such table');

  /// O erro é de coluna que não existe neste banco (e não de rede).
  static bool erroDeColunaAusente(Object erro) =>
      erro.toString().toLowerCase().contains('no such column');

  // ── Contagens e divergências do ciclo (selos das prateleiras e baixa) ──────

  static const String _chaveCiclico = 'ultima_contagem_ciclico_v1';
  static const String _chaveDivergentes = 'divergentes_ciclo_v1';

  /// Coluna de confirmação de contagem_itens que existe neste banco
  /// (`confirmado_em` vem de uma migração do dashboard e pode faltar; aí vale
  /// `registrado_em`). Descoberta na primeira leitura.
  String? _colunaConfirmacao;
  String get colunaConfirmacao => _colunaConfirmacao ?? 'confirmado_em';

  /// Última contagem CONFIRMADA de cada código em contagem_itens (o app
  /// Contagem CAMDA): linhas `produto_codigo`, `ultima` (texto, como gravado).
  ///
  /// Uma varredura de contagem_itens, que só cresce, servindo o selo âmbar das
  /// prateleiras E a baixa automática — antes cada um lia a tabela inteira por
  /// conta própria, a cada dataRevision. Guardada por [janelaContagem], sem
  /// avisar as telas quando muda (o app de contagem confirma itens o dia
  /// todo, e cada aviso recarregaria tudo). A coluna só troca em erro de
  /// coluna inexistente: um timeout com `confirmado_em` não pode fazer a
  /// sessão inteira passar a usar outra data.
  Future<List<Map<String, dynamic>>> consultarUltimasContagensItens({
    bool forceRefresh = false,
    bool atualizarSeVencida = false,
  }) async {
    Future<List<Map<String, dynamic>>> ler(String coluna) => consultarComCache(
      'ultima_contagem_itens_$coluna',
      sqlUltimaContagemItens(coluna),
      falharSemCache: true,
      forceRefresh: forceRefresh,
      atualizarSeVencida: atualizarSeVencida,
      janela: janelaContagem,
      somenteLeitura: true,
      avisar: false,
      releNaVolta: false,
    );

    final preferida = colunaConfirmacao;
    try {
      final rows = await ler(preferida);
      _colunaConfirmacao = preferida;
      return rows;
    } catch (e) {
      if (!erroDeColunaAusente(e)) rethrow;
      final outra = preferida == 'confirmado_em'
          ? 'registrado_em'
          : 'confirmado_em';
      final rows = await ler(outra);
      _colunaConfirmacao = outra;
      return rows;
    }
  }

  /// Última contagem de cada produto no inventário cíclico (inventario_cicli,
  /// gravado por este app em concluirContagem e pelos apps irmãos): linhas
  /// `produto_codigo`, `ultima`. Corrigida na hora por
  /// [registrarContagemConcluida] depois de uma contagem concluída aqui.
  Future<List<Map<String, dynamic>>> consultarUltimasContagensCiclico({
    bool forceRefresh = false,
    bool atualizarSeVencida = false,
  }) => consultarComCache(
    _chaveCiclico,
    sqlUltimaContagemCiclico,
    falharSemCache: true,
    forceRefresh: forceRefresh,
    atualizarSeVencida: atualizarSeVencida,
    janela: janelaContagem,
    avisar: false,
    releNaVolta: false,
  );

  /// Produtos com divergência no ciclo (estoque_mestre.status_ciclo), com o
  /// contado e o sistema da contagem. Pelo índice de status_ciclo, lê só os
  /// divergentes. Corrigida por [registrarContagemConcluida].
  Future<List<Map<String, dynamic>>> consultarDivergentesCiclo({
    bool forceRefresh = false,
    bool atualizarSeVencida = false,
  }) => consultarComCache(
    _chaveDivergentes,
    sqlDivergentesCiclo,
    falharSemCache: true,
    forceRefresh: forceRefresh,
    atualizarSeVencida: atualizarSeVencida,
    janela: janelaTabelaGrande,
    avisar: false,
    releNaVolta: false,
  );

  /// Depois de um concluirContagem: relê do banco só as linhas do produto
  /// nas duas cópias dos selos (pelos índices de produto_id e de codigo) e as
  /// troca nelas. Relidas, e não montadas aqui: o código volta com o tipo que
  /// a coluna deu a ele (num `produto_id` INTEGER o texto vira número, que o
  /// selo âmbar nunca casou), e a cópia fica igual ao que o banco devolveria.
  /// Sem conseguir reler, a cópia expira e a próxima leitura busca inteira.
  Future<void> registrarContagemConcluida(String codigo) async {
    final ciclico = _chaveCompleta(_chaveCiclico);
    final divergentes = _chaveCompleta(_chaveDivergentes);
    if (ciclico == null || divergentes == null) return;

    bool doProduto(Object? valor, List<Map<String, dynamic>> lidas, String col) =>
        valor?.toString() == codigo || lidas.any((r) => r[col] == valor);

    try {
      final ultimas = await consultarDireto(
        '$sqlUltimaContagemCiclicoBase AND produto_id = ? '
        'GROUP BY produto_id',
        parametros: [codigo],
        tipo: 'contagem_concluida',
      );
      await _consultaCache.atualizarParte(
        ciclico,
        (r) => doProduto(r['produto_codigo'], ultimas, 'produto_codigo'),
        ultimas,
      );
    } catch (_) {
      _consultaCache.expirar(ciclico);
    }
    try {
      final linhas = await consultarDireto(
        'SELECT codigo, status_ciclo, qtd_contada_ciclo, '
        'qtd_sistema_na_contagem FROM estoque_mestre WHERE codigo = ?',
        parametros: [codigo],
        tipo: 'contagem_concluida',
      );
      await _consultaCache.atualizarParte(
        divergentes,
        (r) => doProduto(r['codigo'], linhas, 'codigo'),
        [
          for (final r in linhas)
            if (r['status_ciclo'] == 'divergencia')
              {
                'codigo': r['codigo'],
                'qtd_contada_ciclo': r['qtd_contada_ciclo'],
                'qtd_sistema_na_contagem': r['qtd_sistema_na_contagem'],
              },
        ],
      );
    } catch (_) {
      _consultaCache.expirar(divergentes);
    }
  }

  // ── Índices nas tabelas dos outros apps ───────────────────────────────────

  /// Índices que este app cria nas tabelas dos apps irmãos (autorizado pelo
  /// Leo). Cada um serve uma consulta daqui que, sem ele, varre a tabela
  /// inteira — e o Turso cobra cada linha varrida.
  static const List<({String nome, String tabela, List<String> colunas})>
  indicesAlheios = [
    // Pendentes do Modo Conferência (status = 'pendente').
    (
      nome: 'idx_gondolas_contagem_itens_status',
      tabela: 'contagem_itens',
      colunas: ['status'],
    ),
    // Divergentes do ciclo (status_ciclo = 'divergencia').
    (
      nome: 'idx_gondolas_estoque_mestre_status_ciclo',
      tabela: 'estoque_mestre',
      colunas: ['status_ciclo'],
    ),
    // concluirContagem lê e grava o produto por código.
    (
      nome: 'idx_gondolas_estoque_mestre_codigo',
      tabela: 'estoque_mestre',
      colunas: ['codigo'],
    ),
    // concluirContagem procura a linha do dia do produto.
    (
      nome: 'idx_gondolas_inventario_cicli_produto',
      tabela: 'inventario_cicli',
      colunas: ['produto_id', 'data_contagem'],
    ),
  ];

  static final String _assinaturaIndicesAlheios = [
    for (final i in indicesAlheios) '${i.nome}:${i.tabela}:${i.colunas}',
  ].join('|');

  /// Cria os [indicesAlheios] que faltam, uma vez por banco e aparelho.
  ///
  /// Nunca duplica: se algum índice da tabela (inclusive o da chave primária)
  /// já começa pela mesma coluna, não cria nada. Tabela ou coluna que não
  /// existe neste banco é pulada. Roda em segundo plano depois do init; sem
  /// conexão, tenta de novo na próxima abertura.
  Future<void> _garantirIndicesAlheios() async {
    final banco = _identidadeAtiva;
    final cliente = _client;
    if (banco == null || cliente == null) return;
    final marca = 'indices_alheios_$banco';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(marca) == _assinaturaIndicesAlheios) return;
      for (final indice in indicesAlheios) {
        await _criarIndiceAlheio(cliente, indice);
      }
      await prefs.setString(marca, _assinaturaIndicesAlheios);
    } catch (_) {
      // Rede caiu no meio: a próxima abertura confere de novo (os que já
      // existem são reconhecidos e pulados).
    }
  }

  Future<void> _criarIndiceAlheio(
    LibsqlClient cliente,
    ({String nome, String tabela, List<String> colunas}) indice,
  ) async {
    Future<bool> existe(String sql, List<Object> parametros) async {
      final stmt = await cliente.prepare(sql).timeout(_timeoutConexao);
      final rows =
          await stmt.query(positional: parametros).timeout(_timeoutLeitura)
              as List<dynamic>;
      contarLeitura('indices_conferencia', rows.length);
      return rows.isNotEmpty;
    }

    try {
      for (final coluna in indice.colunas) {
        if (!await existe(
          'SELECT 1 FROM pragma_table_info(?) WHERE name = ? LIMIT 1',
          [indice.tabela, coluna],
        )) {
          return; // Tabela ou coluna ausente neste banco.
        }
      }
      if (await existe(
        'SELECT 1 FROM pragma_index_list(?) il '
        'JOIN pragma_index_info(il.name) ii '
        'WHERE ii.seqno = 0 AND ii.name = ? LIMIT 1',
        [indice.tabela, indice.colunas.first],
      )) {
        return; // Já há índice começando por essa coluna.
      }
      await cliente
          .batch(
            'CREATE INDEX IF NOT EXISTS ${indice.nome} '
            'ON ${indice.tabela} (${indice.colunas.join(', ')})',
          )
          .timeout(_timeoutPreparoBanco);
    } on TimeoutException {
      rethrow;
    } catch (e) {
      // Erro de esquema (tabela sem permissão, pragma não suportado): pula
      // este índice. Erro de rede sobe e a marca não é gravada.
      if (!erroDeTabelaAusente(e) && !erroDeColunaAusente(e) &&
          _pareceErroDeRede(e)) {
        rethrow;
      }
    }
  }

  static bool _pareceErroDeRede(Object erro) {
    final texto = erro.toString().toLowerCase();
    return texto.contains('socket') ||
        texto.contains('connection') ||
        texto.contains('network') ||
        texto.contains('timeout') ||
        texto.contains('handshake') ||
        texto.contains('failed host lookup');
  }

  Future<List<Map<String, dynamic>>> _quantidadesParaBusca() =>
      consultarQuantidades();

  // A busca nas gôndolas e estantes sai das cópias de layout, que o prewarm
  // já traz (precarregarLayouts).
  Future<void> _precarregarBusca() async {
    await Future.wait([
      _buscarNoGalpao(''),
      _buscarNoBarracao(''),
      _quantidadesParaBusca(),
      consultarSaldos().catchError((_) => <Map<String, dynamic>>[]),
    ]);
  }

  Future<List<ProdutoEncontrado>> buscarProdutoGlobal(String termo) async {
    final q = termo.trim();
    if (q.length < 2) return [];
    final like = q;

    final resultados = await Future.wait([
      _buscarNasGondolas(like),
      _buscarNasEstantes(like),
      _buscarNoGalpao(like),
      _buscarNoBarracao(like),
    ]);
    return _anexarQuantidades([
      ...resultados[0],
      ...resultados[1],
      ...resultados[2],
      ...resultados[3],
    ]);
  }

  /// Produtos do galpão que casam com a busca. Lê galpao_racks (a ocupação),
  /// não o espelho em estoque_localizado: é lá que estão o nome do produto e
  /// a ordem na pilha.
  ///
  /// Sem isto, um produto lançado no galpão simplesmente não existia para a
  /// busca do mapa — era o caminho pelo qual alguém procurava um herbicida e
  /// concluía que ele não estava na loja.
  Future<List<ProdutoEncontrado>> _buscarNoGalpao(String like) async {
    try {
      // A MESMA cópia que a tela do galpão usa ('galpao'): antes havia uma
      // segunda, com a mesma tabela em outra ordem, relida à parte — e a
      // diferença de ordem entre as duas acusava "mudou" depois de cada
      // rajada de lançamentos.
      final linhas = [...await consultarComCache(chaveGalpao, sqlGalpao)]
        ..sort((a, b) {
          final porNome = (a['produto_nome'] as String? ?? '').compareTo(
            b['produto_nome'] as String? ?? '',
          );
          if (porNome != 0) return porNome;
          final porPosicao = (a['posicao'] as int? ?? 0).compareTo(
            b['posicao'] as int? ?? 0,
          );
          if (porPosicao != 0) return porPosicao;
          return (a['ordem'] as int? ?? 0).compareTo(b['ordem'] as int? ?? 0);
        });
      final rows = filtrarBuscaLocal(linhas, like);
      return rows.map((dynamic row) {
        final r = row as Map<String, dynamic>;
        final posicao = r['posicao'] as int? ?? 0;
        final ordem = r['ordem'] as int? ?? 1;
        final rua = GalpaoConfig.ruaDe(posicao);
        return ProdutoEncontrado(
          nome: r['produto_nome'] as String? ?? '',
          tipo: localTipoGalpao,
          numero: posicao,
          // O endereço do galpão é '<número> · N<nível>'; a rua é derivada e
          // entra só para orientar quem vai buscar.
          nivelDescricao: rua == null
              ? 'N$ordem'
              : 'Rua ${rua.numero} · N$ordem',
          produtoCodigo: r['produto_codigo'] as String? ?? '',
          nivel: ordem,
          // A quantidade vem da própria linha do rack — não precisa esperar
          // o espelho em estoque_localizado.
          quantidade: (r['quantidade'] as num?)?.toDouble(),
        );
      }).toList();
    } catch (_) {
      // Tabela ainda não criada (replica antes do bootstrap): a busca nas
      // outras estruturas não pode cair por causa disso.
      return [];
    }
  }

  Future<List<ProdutoEncontrado>> _buscarNoBarracao(String like) async {
    try {
      // A mesma cópia da tela do barracão ('barracao'), só com os paletes
      // ocupados.
      final linhas = [
        for (final r in await consultarComCache(chaveBarracao, sqlBarracao))
          if ((r['produto_codigo'] as String? ?? '').isNotEmpty) r,
      ]..sort((a, b) {
          final porNome = (a['produto_nome'] as String? ?? '').compareTo(
            b['produto_nome'] as String? ?? '',
          );
          if (porNome != 0) return porNome;
          return (a['rotulo'] as String? ?? '').compareTo(
            b['rotulo'] as String? ?? '',
          );
        });
      final rows = filtrarBuscaLocal(linhas, like);
      return rows.map((dynamic row) {
        final r = row as Map<String, dynamic>;
        return ProdutoEncontrado(
          nome:             r['produto_nome'] as String? ?? '',
          tipo:             localTipoBarracao,
          numero:           r['id'] as int? ?? 0,
          nivelDescricao:   r['rotulo'] as String? ?? 'Barracão',
          produtoCodigo:    r['produto_codigo'] as String? ?? '',
          quantidade:       (r['quantidade'] as num?)?.toDouble(),
        );
      }).where((p) => p.numero > 0 && p.produtoCodigo.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  /// Anexa a cada resultado a quantidade contada (estoque_localizado) no seu
  /// local: gôndola casa pelo endereço exato (face + andar); estante soma as
  /// colunas do nível, já que a busca agrupa por estante + nível.
  Future<List<ProdutoEncontrado>> _anexarQuantidades(
    List<ProdutoEncontrado> encontrados,
  ) async {
    if (encontrados.isEmpty) return encontrados;
    final codigos = encontrados
        .map((p) => p.produtoCodigo)
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();
    if (codigos.isEmpty) return encontrados;
    // Galpão e barracão trazem a quantidade na própria linha: só gôndola e
    // estante precisam da cópia do estoque_localizado (que, vencida, relê a
    // tabela inteira).
    if (encontrados.every(
      (p) => p.tipo == localTipoGalpao || p.tipo == localTipoBarracao,
    )) {
      return encontrados;
    }
    try {
      final rows = await _quantidadesParaBusca();

      // gôndola: 'g|codigo|num|face|andar' · estante: 'e|codigo|num|nivel' ·
      // galpão: 'x|codigo|posicao|ordem'.
      //
      // O prefixo por TIPO não é enfeite: os números de posição do galpão
      // (1–129) se sobrepõem aos de estante (1–21), então uma chave montada só
      // com o número faria a quantidade do galpão ser somada dentro da
      // estante de mesmo número.
      final somas = <String, double>{};
      for (final dynamic row in rows) {
        final r = row as Map<String, dynamic>;
        final codigo = r['produto_codigo'] as String? ?? '';
        final tipo = r['local_tipo'] as String? ?? '';
        final localNum = r['local_num'] as int? ?? 0;
        final fc = r['face_ou_coluna'] as int? ?? 0;
        final an = r['andar_ou_nivel'] as int? ?? 0;
        final qtd = (r['quantidade'] as num?)?.toDouble() ?? 0;
        // Estante: mesmo clamp de nível usado em _buscarNasEstantes, pra
        // chave casar com o resultado exibido.
        final chave = switch (tipo) {
          'gondola' => 'g|$codigo|$localNum|$fc|$an',
          localTipoGalpao => 'x|$codigo|$localNum|$an',
          localTipoBarracao => 'b|$codigo|$localNum',
          _ =>
            'e|$codigo|$localNum|${an.clamp(0, niveisProdutoPara(localNum) - 1)}',
        };
        somas[chave] = (somas[chave] ?? 0) + qtd;
      }

      return encontrados.map((p) {
        // O galpão já traz a quantidade da própria linha do rack; o espelho
        // em estoque_localizado só confirmaria o mesmo número.
        if (p.tipo == localTipoGalpao || p.tipo == localTipoBarracao) return p;
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
      // A cópia completa da tabela: filtrarBuscaLocal já ordena por nome e
      // descarta as repetidas nas colunas da busca (o DISTINCT de antes).
      final rows = filtrarBuscaLocal(
        await _copiaDeLayouts(gondola: true),
        like,
      );
      const andarNomes = ['Base', 'Meio', 'Topo'];
      // A face é derivada de pos_x/pos_z (sem coluna no banco); caixas do
      // mesmo produto no mesmo endereço G·F·A viram um resultado só.
      final vistos = <String>{};
      final encontrados = <ProdutoEncontrado>[];
      for (final dynamic row in rows) {
        final r = row as Map<String, dynamic>;
        final a = ((r['andar'] as int?) ?? 0).clamp(0, 2);
        final posX = (r['pos_x'] as num?)?.toDouble() ?? 0;
        final posZ = (r['pos_z'] as num?)?.toDouble() ?? 0;
        final face = faceFromPos(posX, posZ);
        final codigo = r['produto_codigo'] as String? ?? '';
        final gondola = r['gondola_num'] as int? ?? 0;
        if (!vistos.add('$codigo|$gondola|$a|$face')) continue;
        encontrados.add(
          ProdutoEncontrado(
            nome: r['produto_nome'] as String? ?? '',
            tipo: 'gondola',
            numero: gondola,
            nivelDescricao: 'Face $face · Andar ${andarNomes[a]}',
            produtoCodigo: codigo,
            face: face,
            andar: a,
          ),
        );
      }
      return encontrados;
    } catch (_) {
      return [];
    }
  }

  Future<List<ProdutoEncontrado>> _buscarNasEstantes(String like) async {
    try {
      // O WHERE da consulta antiga, em Dart: sem as estantes removidas e sem
      // a base do Expositor Nellore.
      final rows = filtrarBuscaLocal([
        for (final r in await _copiaDeLayouts(gondola: false))
          if (linhaDeEstanteBuscavel(r)) r,
      ], like);
      return rows.map((dynamic row) {
        final r = row as Map<String, dynamic>;
        final estanteNum = r['estante_num'] as int? ?? 0;
        final nivProduto = niveisProdutoPara(estanteNum);
        final n = ((r['nivel'] as int?) ?? 0).clamp(0, nivProduto - 1);
        // No palete o nível é a FILEIRA (0 = corredor), não uma altura, então
        // "Nível 2" não ajudaria ninguém a achar o produto. Como esta busca
        // agrupa por estante + nível (sem coluna), o mais específico que dá
        // pra dizer é a faixa de posições daquela fileira: 1–5, 6–10, 11–15.
        final descricao = ehPalete(estanteNum)
            ? 'Posições ${n * colunasPalete + 1}–${n * colunasPalete + colunasPalete}'
            : 'Nível ${n + 1}';
        return ProdutoEncontrado(
          nome: r['produto_nome'] as String? ?? '',
          tipo: 'estante',
          numero: estanteNum,
          nivelDescricao: descricao,
          produtoCodigo: r['produto_codigo'] as String? ?? '',
          nivel: n,
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
      contarLeitura('busca_na_cena', (rows as List<dynamic>).length);
      final list = rows as List<dynamic>;
      if (list.isEmpty) return null;
      final r = list.first as Map<String, dynamic>;
      return CaixaLayout(
        gondolaNum: r['gondola_num'] as int? ?? 0,
        andar: r['andar'] as int? ?? 0,
        produtoCodigo: r['produto_codigo'] as String? ?? produtoCodigo,
        produtoNome: r['produto_nome'] as String? ?? '',
        posX: (r['pos_x'] as num?)?.toDouble() ?? 0,
        posZ: (r['pos_z'] as num?)?.toDouble() ?? 0,
        corHex: r['cor_hex'] as String? ?? '#888888',
      );
    } catch (_) {
      return null;
    }
  }
}
