import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, ValueNotifier, debugPrint;
import 'package:libsql_dart/libsql_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'galpao_config.dart';
import 'galpao_migracao_unidades.dart';
import 'layout_cache.dart';
import 'models.dart';
import 'palete_registry.dart';
import 'replica_local.dart';
import 'replica_coordinator.dart';

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

  static const String keyDbUrl      = 'turso_db_url';
  static const String keyDbToken    = 'turso_db_token';
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
  // Conexão direta ao remoto usada só para saber se há rede (ver
  // _remotoAlcancavel). Nunca serve leitura nem escrita do app.
  LibsqlClient? _sonda;

  // Cache local (embedded replica com offline writes): o banco vive num
  // arquivo do dispositivo — leituras e gravações são instantâneas e
  // funcionam sem internet; sincronizar() empurra/puxa as mudanças para o
  // Turso quando o usuário pedir. Indisponível no Flutter Web (sem
  // filesystem), onde o app segue conectando direto no remoto.
  bool      _modoLocal           = false;
  bool      _sincronizando       = false;
  // True enquanto a replica local ainda não puxou (pull) os frames que o
  // servidor já tem. Nesse estado NADA pode ser escrito no arquivo local: os
  // frames locais sairiam na frente dos do servidor e o push passaria a falhar
  // para sempre com InvalidPushFrameConflict. Ver _estabelecerBaseLocal.
  bool      _basePendente        = false;
  DateTime? _ultimaSincronizacao;
  String?   _ultimoErroSync;
  String?   _ultimoAvisoSync;
  int       _gravacoesPendentes = 0;
  int       _enviadasNoUltimoSync = 0;
  final CoordenadorReplica _coordenador = CoordenadorReplica();
  String? _identidadeAtiva;

  String _chavePorBanco(String base) =>
      _identidadeAtiva == null ? base : '${base}_${_identidadeAtiva!}';

  // Credenciais/modo da conexão ativa. Enquanto não mudarem, init()
  // reaproveita a conexão (e o esquema já criado) em vez de reconectar e
  // reexecutar os CREATE TABLEs a cada abertura de página.
  String? _urlAtiva;
  String? _tokenAtivo;
  bool?   _cacheLocalAtivo;
  Future<void>? _initEmAndamento;
  bool _forcarReconexao = false;
  String? _motivoFalhaCacheLocal;

  // Cache do catálogo (estoque_mestre): evita repetir o SELECT de até 5000
  // linhas toda vez que uma página abre. No modo local o TTL é ignorado (ver
  // fetchProdutos): a base do dispositivo só muda em sincronizar() /
  // _estabelecerBaseLocal, e os dois já zeram este cache — o relógio ali só
  // garantia uma reconsulta inútil em toda sessão longa. O TTL continua valendo
  // no modo remoto, onde um app irmão pode mexer no estoque_mestre por fora.
  List<Produto>? _produtosCache;
  DateTime?      _produtosCacheEm;
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

  // Cache dos layouts por estrutura. Ver layout_cache.dart para o porquê de
  // morar aqui dentro. Invalidado pelos mesmos pontos que zeram _produtosCache,
  // mais os dois salvarLayout* (que gravam direto o que acabaram de persistir).
  final CacheDeLayout<CaixaLayout>        _cacheGondola = CacheDeLayout();
  final CacheDeLayout<CaixaLayoutEstante> _cacheEstante = CacheDeLayout();

  /// Consultas efetivamente enviadas ao banco desde a abertura do app. Serve
  /// para conferir, no log de debug, que reabrir uma cena já visitada não
  /// emite consulta nenhuma.
  int consultasEmitidas = 0;

  bool get isConnected => _connected;

  /// Incrementa a cada sincronização bem-sucedida (carga inicial em segundo
  /// plano ou botão Sincronizar). As páginas ouvem para recarregar a cena
  /// assim que dados novos chegam, sem travar a abertura.
  final ValueNotifier<int> dataRevision = ValueNotifier<int>(0);

  /// True quando a conexão ativa usa o cache local (arquivo no dispositivo).
  bool get modoLocal => _modoLocal;

  /// True quando o cache local está LIGADO em ⚙️ mas o app acabou conectando
  /// direto no banco online assim mesmo.
  ///
  /// Acontece quando `_conectarComCacheLocal` falha — tipicamente sinal ruim
  /// durante o download do snapshot inicial, que é a única abertura em que
  /// esse connect() usa a rede — e o `_init` cai calado para o remoto. Nesse
  /// estado TODA gravação vai pela rede (e falha sem sinal) e o Sincronizar
  /// não tem replica para empurrar. A tela precisa dizer isso: até aqui, ⚙️
  /// mostrava a preferência e escondia o que estava acontecendo de verdade.
  bool get caiuParaRemoto =>
      _connected && !_modoLocal && (_cacheLocalAtivo ?? false);

  /// Por que a última tentativa de abrir o cache local não deu certo, ou null
  /// se ela deu. Mostrado junto do aviso em ⚙️ — ver `_conectarComCacheLocal`.
  String? get motivoFalhaCacheLocal => _motivoFalhaCacheLocal;

  bool get sincronizando => _sincronizando;

  EstadoReplica get estadoReplica => _coordenador.estado;

  /// Porta única de toda mutação. A reserva síncrona impede corrida com sync.
  Future<T> garantirReplicaProntaParaEscrita<T>(
      Future<T> Function() acao) async {
    try {
      return await _coordenador.executarEscrita(acao);
    } on ReplicaNaoProntaParaEscrita catch (e) {
      _ultimoErroSync = e.toString();
      rethrow;
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
  Future<void> marcarGravacaoLocal() async {
    if (!_modoLocal) return;
    _gravacoesPendentes++;
    await _persistirGravacoesPendentes();
  }

  Future<void> _persistirGravacoesPendentes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = _identidadeAtiva;
      await prefs.setInt(id == null
          ? keyGravacoesPendentes
          : '${keyGravacoesPendentes}_$id', _gravacoesPendentes);
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
      await prefs.remove(id == null
          ? keyGravacoesPendentes
          : '${keyGravacoesPendentes}_$id');
    } catch (_) {
      // Ver marcarGravacaoLocal.
    }
  }

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

  Future<void> _init() async {
    _coordenador.definirEstado(EstadoReplica.conectando);
    // Consumido já: uma reconexão forçada vale para ESTA passada, senão toda
    // abertura de página passaria a reconectar.
    final forcado    = _forcarReconexao;
    _forcarReconexao = false;
    final prefs      = await SharedPreferences.getInstance();
    final url        = prefs.getString(keyDbUrl)   ?? '';
    final token      = prefs.getString(keyDbToken) ?? '';
    final cacheLocal = !kIsWeb && (prefs.getBool(keyCacheLocal) ?? true);
    final identidade = idBanco(url);
    final anterior = prefs.getString('turso_identidade_ativa');
    if (anterior != null && anterior != identidade) {
      final pendentesAntigas =
          prefs.getInt('${keyGravacoesPendentes}_$anterior') ??
              prefs.getInt(keyGravacoesPendentes) ?? 0;
      if (pendentesAntigas > 0) {
        _ultimoErroSync = 'há gravações pendentes no banco anterior; '
            'sincronize ou exporte antes de trocar a URL';
        _coordenador.definirEstado(EstadoReplica.recuperacaoNecessaria);
        return;
      }
    }
    _identidadeAtiva = identidade;
    await prefs.setString('turso_identidade_ativa', identidade);
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
            _chavePorBanco(keyGravacoesPendentes), pendentesLegadas);
        await prefs.remove(keyGravacoesPendentes);
      }
    }

    final ultimaSyncIso = prefs.getString(_chavePorBanco(keyUltimaSync));
    _ultimaSincronizacao =
        ultimaSyncIso != null ? DateTime.tryParse(ultimaSyncIso) : null;
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
        token == _tokenAtivo &&
        cacheLocal == _cacheLocalAtivo) {
      _coordenador.definirEstado(
          _basePendente ? EstadoReplica.basePendente : EstadoReplica.pronta);
      return;
    }

    final clienteAntigo = _client;

    _connected       = false;
    _client          = null;
    _urlAtiva        = null;
    _tokenAtivo      = null;
    _cacheLocalAtivo = null;
    _modoLocal       = false;
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
    var conectouLocal = false;

    if (cacheLocal) {
      client        = await _conectarComCacheLocal(url, token);
      conectouLocal = client != null;
    }
    // Sem cache local (Web, preferência desligada ou falha ao abrir o
    // arquivo): conexão direta ao remoto, como antes.
    client ??= await _conectarRemoto(url, token);
    if (client == null) {
      _coordenador.definirEstado(EstadoReplica.erro);
      return;
    }

    try {
      if (conectouLocal) {
        // Replica local sem a base do remoto estabelecida (primeira abertura
        // deste arquivo): NÃO escreve NADA localmente antes do primeiro pull.
        // O connect() já trouxe o snapshot do banco — dá para ler tudo —, mas
        // o protocolo de sync ainda considera a replica no frame 0; criar o
        // esquema ou rodar migração agora deixaria frames locais na frente dos
        // do servidor, e a partir daí todo sync falharia com
        // InvalidPushFrameConflict (foi exatamente o que quebrou o cache local
        // em produção). Só quando o arquivo já está em dia é que o esquema
        // idempotente (inclui os índices) e as migrações rodam direto.
        final precisaBase = await _replicaPrecisaBaixarBase(client);
        if (!precisaBase) {
          await _criarEsquema(client);
          await _migrarEsquemaLabelsEstante3(client);
          await _migrarPaletesCadastroDinamico(client);
          await migrarGalpaoParaUnidades(client);
        }
        _client          = client;
        _connected       = true;
        _modoLocal       = true;
        _urlAtiva        = url;
        _tokenAtivo      = token;
        _cacheLocalAtivo = cacheLocal;
        _basePendente    = precisaBase;
        _coordenador.definirEstado(precisaBase
            ? EstadoReplica.basePendente
            : EstadoReplica.pronta);
        if (precisaBase) {
          try {
            await _estabelecerBaseLocal(client, _timeoutBootstrap);
            _ultimoErroSync = null;
          } catch (e) {
            // Sem rede agora: a replica continua legível (o arquivo veio do
            // remoto no connect) e _basePendente segue true — o esquema, as
            // migrações e a base entram no próximo Sincronizar, nunca antes.
            _ultimoErroSync = descreverErroSync(e);
          }
        }
      } else {
        // Modo remoto (Web ou falha ao abrir o arquivo local): cria o esquema
        // e conecta direto ao remoto, como antes.
        await _criarEsquema(client);
        await _migrarEsquemaLabelsEstante3(client);
        await _migrarPaletesCadastroDinamico(client);
        await migrarGalpaoParaUnidades(client);
        _client          = client;
        _connected       = true;
        _modoLocal       = false;
        _basePendente    = false;
        _coordenador.definirEstado(EstadoReplica.pronta);
        _urlAtiva        = url;
        _tokenAtivo      = token;
        _cacheLocalAtivo = cacheLocal;
      }
      // Fim do init: os paletes precisam estar em memória antes do primeiro
      // build do mapa e do carrossel (ordemNavegacaoEstantes consulta
      // PaleteRegistry().ativos). Numa replica sem base a tabela pode ainda
      // não existir — carregar() engole a falha e _estabelecerBaseLocal
      // recarrega quando a base chegar.
      await PaleteRegistry().carregar();
    } catch (_) {
      _connected = false;
      _client    = null;
      _coordenador.definirEstado(EstadoReplica.erro);
    }
  }

  // Limites de tempo: nenhuma etapa de conexão/sincronização pode segurar o
  // app indefinidamente — estourou, cai no fallback (remoto) ou falha o botão
  // de sincronizar com aviso, mantendo os dados locais intactos.
  static const Duration _timeoutConexao   = Duration(seconds: 20);
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
  static const Duration _timeoutBootstrap = Duration(minutes: 3);
  static const Duration _timeoutSync      = Duration(minutes: 3);

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

  Future<LibsqlClient?> _conectarComCacheLocal(String url, String token,
      {bool podeReconstruir = true}) async {
    LibsqlClient? client;
    // Fora do try: o catch precisa do valor para explicar um timeout.
    var limite = _timeoutConexao;
    try {
      final path = await _caminhoCacheLocal();
      // Atenção: quando o arquivo local ainda não existe, este connect() NÃO é
      // local — o libsql baixa do Turso o snapshot inteiro do banco antes de
      // devolver a conexão. Da segunda abertura em diante ele é local e
      // instantâneo, e a rede só volta a entrar no Sincronizar.
      //
      // Por isso o limite é MUITO maior enquanto a base não está estabelecida:
      // 20s não baixam o banco, o connect estoura, e o `_init` cai calado para
      // o modo remoto — onde toda gravação passa a depender da rede e o
      // Sincronizar não tem replica para empurrar. Era o caminho mais provável
      // para o app acabar em modo remoto com o cache local ligado.
      //
      // A pergunta é "a base já está pronta?", NÃO "o arquivo existe?". Um
      // download que estourou o tempo deixa arquivo no disco sem a base
      // completa: pela existência do arquivo, a tentativa seguinte cairia nos
      // 20s justamente quando ainda falta baixar o grosso. `keyBaseLocalOk` só
      // é gravada quando `_estabelecerBaseLocal` termina, então é ela que
      // responde de verdade.
      final prefs = await SharedPreferences.getInstance();
      final baseJaPronta =
          (prefs.getBool(_chavePorBanco(keyBaseLocalOk)) ?? false) &&
              await File(path).exists();
      limite = baseJaPronta ? _timeoutConexao : _timeoutBootstrap;
      client = LibsqlClient.offline(path, syncUrl: url, authToken: token);
      await client.connect().timeout(limite);
      _motivoFalhaCacheLocal = null;
      return client;
    } catch (e) {
      // Guarda o PORQUÊ. Sem isto o app só sabia dizer "não pôde ser aberto",
      // e a causa (estourou o tempo do download? token recusado? arquivo em
      // estado inválido?) pede correções completamente diferentes — cada uma
      // some junto com o erro engolido aqui.
      _motivoFalhaCacheLocal = e is TimeoutException
          ? 'o download da base passou de ${limite.inSeconds}s'
          : descreverErroSync(e);
      if (client != null) {
        unawaited(client.dispose().catchError((_) {}));
      }
      // Arquivo local em estado que o libsql se recusa a abrir (ex: o `.db`
      // apagado sem o `-info` ao lado) — nenhuma tentativa futura muda isso.
      // Apaga os arquivos e refaz do zero, uma vez, em vez de cair calado pro
      // modo remoto e deixar o cache local quebrado para sempre. Falha de rede
      // não entra aqui: aí o arquivo está bom e o fallback remoto é o certo.
      if (podeReconstruir &&
          _gravacoesPendentes == 0 &&
          erroDeReplicaDivergente(e) &&
          await _apagarArquivosDaReplica()) {
        return _conectarComCacheLocal(url, token, podeReconstruir: false);
      }
      return null;
    }
  }

  /// Estabelece a base do remoto numa replica local que ainda está no frame 0:
  /// primeiro PUXA tudo o que o servidor já tem, e só depois aplica o esquema
  /// idempotente e as migrações. A ordem é o ponto: escrever antes do pull
  /// coloca frames locais na frente dos do servidor, e o push seguinte morre
  /// com InvalidPushFrameConflict — para sempre, porque o cliente sempre
  /// recomeça do mesmo frame.
  Future<void> _estabelecerBaseLocal(
      LibsqlClient client, Duration limite) async {
    await client.sync().timeout(limite);
    // O sync do libsql devolve sucesso quando a requisição HTTP não completa
    // (falha de rede vira "0 frames sincronizados"). Se a replica continua no
    // frame 0 depois dele, o estado é ambíguo: ou o servidor realmente não
    // tinha frames nesta geração, ou não deu para falar com ele. Um SELECT 1
    // no remoto separa os dois — e no segundo caso é proibido escrever aqui.
    if (await _replicaNoFrameZero() && !await _remotoAlcancavel()) {
      throw const BaseLocalNaoBaixada();
    }
    await _criarEsquema(client);
    await _migrarEsquemaLabelsEstante3(client);
    await _migrarPaletesCadastroDinamico(client);
    await migrarGalpaoParaUnidades(client);
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
  Future<bool> _replicaPrecisaBaixarBase(LibsqlClient client) async {
    // Base já estabelecida para ESTE arquivo: nada a puxar, nem que o frame
    // confirmado siga em 0 (acontece quando o servidor acabou de fazer
    // checkpoint e a geração nova ainda não tem frames). Sem esta marca, toda
    // abertura do app repetiria o sync — e, sem internet, esperaria os
    // timeouts antes de mostrar o mapa.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_chavePorBanco(keyBaseLocalOk)) ?? false) return false;

    final frame = await _frameDuravelAtual();
    if (frame != null) return frame == 0;
    return _bancoLocalVazio(client);
  }

  /// Geração + frame confirmados da replica local, ou null se o `-info` não
  /// existe / não dá para ler.
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
    final url   = _urlAtiva;
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
  Future<Map<String, AssinaturaTabela>?> _carimboDe(LibsqlClient? cliente) async {
    if (cliente == null) return null;
    try {
      final stmt   = await cliente.prepare(sqlDoCarimbo());
      final linhas = (await stmt.query().timeout(_timeoutConexao)) as List<dynamic>;
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
      })> _conferirCarimbos() async {
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
      final nome    = arquivo.uri.pathSegments.last;
      final pasta   = arquivo.parent;
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
      await prefs.remove(keyGravacoesPendentes);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Zera tudo que é leitura em cache (catálogo e layouts). Chamado nos quatro
  /// pontos em que a base sob o app pode ter mudado por inteiro: reconexão,
  /// carga inicial, sincronização e limpeza do cache local.
  void _invalidarCachesDeLeitura() {
    _produtosCache   = null;
    _produtosCacheEm = null;
    _cacheGondola.invalidarTudo();
    _cacheEstante.invalidarTudo();
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
    // Catálogo dos paletes de madeira do piso, cadastrados em RUNTIME (o
    // número de paletes na loja é variável — ver PaleteRegistry). `num` é
    // alocado por MAX(num) + 1 varrendo inclusive os inativos, então NUNCA
    // execute DELETE FROM paletes: apagar linha desativada libera o número
    // para reciclagem e o palete novo herdaria os endereços velhos em
    // estoque_localizado. Palete que sai da loja vira ativo = 0.
    await client.execute('''
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
    await client.execute('''
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
    await client.execute('''
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
    await client.execute('''
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
    // Espelha o índice de estante acima: buscarProduto e o SELECT DISTINCT do
    // Modo Conferência filtram gondola_layout por produto_codigo e até aqui
    // faziam varredura completa.
    await client.execute(
      'CREATE INDEX IF NOT EXISTS idx_gondola_layout_produto '
      'ON gondola_layout (produto_codigo)',
    );
    // As buscas de badge filtram por endereço físico. O índice implícito do
    // UNIQUE de estoque_localizado NÃO serve esse predicado: a coluna líder
    // dele é produto_codigo.
    await client.execute(
      'CREATE INDEX IF NOT EXISTS idx_estoque_localizado_local '
      'ON estoque_localizado (local_tipo, local_num)',
    );
    await client.execute(
      'CREATE INDEX IF NOT EXISTS idx_paletes_ativo ON paletes (ativo)',
    );
    // Busca "onde está este produto no galpão" — o UNIQUE(posicao, ordem) não
    // serve esse predicado, a coluna líder dele é posicao.
    await client.execute(
      'CREATE INDEX IF NOT EXISTS idx_galpao_racks_produto '
      'ON galpao_racks (produto_codigo)',
    );
    // Mesmo predicado, do outro prédio: "onde está este produto no barracão".
    // O índice implícito do UNIQUE(rotulo) não serve — a coluna dele é outra.
    await client.execute(
      'CREATE INDEX IF NOT EXISTS idx_barracao_enderecos_produto '
      'ON barracao_enderecos (produto_codigo)',
    );
  }

  Future<void> _registrarSincronizacao() async {
    _ultimaSincronizacao = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _chavePorBanco(keyUltimaSync), _ultimaSincronizacao!.toIso8601String());
  }

  /// Sincroniza o cache local com o banco online: envia as gravações feitas
  /// no dispositivo e baixa as novidades do Turso. Retorna false quando não
  /// há conexão configurada ou a sincronização falhou (ex: sem internet) —
  /// nesse caso os dados locais ficam intactos e dá pra tentar de novo.
  /// No modo remoto (sem cache local) não há o que empurrar: só renova o
  /// cache do catálogo em memória.
  Future<bool> sincronizar() async {
    if (_coordenador.syncReservado) {
      _ultimoErroSync = 'já existe uma sincronização em andamento';
      return false;
    }
    final operacao = _coordenador.executarSincronizacao(_sincronizarExclusiva);
    return operacao.timeout(_timeoutSync, onTimeout: () {
      _ultimoErroSync = 'a sincronização continua em segundo plano; aguarde antes de tentar novamente';
      return false;
    });
  }

  Future<bool> _sincronizarExclusiva() async {
    if (!await _garantirConexao()) {
      final prefs = await SharedPreferences.getInstance();
      final configurado = (prefs.getString(keyDbUrl) ?? '').isNotEmpty &&
          (prefs.getString(keyDbToken) ?? '').isNotEmpty;
      _ultimoErroSync = configurado
          ? 'sem conexão com o banco — verifique a internet'
          : 'configure URL e token do banco em ⚙️';
      return false;
    }
    _sincronizando        = true;
    _ultimoAvisoSync      = null;
    // Zerado no começo: o número mostrado no fim tem de ser o DESTA rodada.
    // Sem isso, um sync remoto (que não empurra nada) herdaria a contagem do
    // sync local anterior e diria "3 gravações enviadas" sem ter enviado uma.
    _enviadasNoUltimoSync = 0;
    try {
      final erro = await _tentarSincronizar();
      if (erro == null) {
        _ultimoErroSync = null;
        return true;
      }
      // Divergência nunca autoriza destruição silenciosa. Sem uma outbox com
      // ACK remoto, nem mesmo sabemos quais frames seriam perdidos.
      if (_modoLocal && erroDeReplicaDivergente(erro)) {
        _coordenador.definirEstado(EstadoReplica.recuperacaoNecessaria);
        _ultimoErroSync = 'a réplica divergiu; os dados locais foram preservados e precisam de recuperação';
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
        if (!await _clienteRespondendo()) return const SincronizacaoNaoConfirmada();
      }
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
    await _client!.sync();
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
      debugPrint('[turso] carimbo diferente em '
          '${conferencia.tabelas.join(", ")} '
          '(${conferencia.resultado.name}) — tentando de novo');
      await _client!.sync();
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
      debugPrint('[turso] carimbos iguais com $_gravacoesPendentes '
          'pendente(s) contada(s): contador velho, zerando');
    }

    // O número do snackbar só vale se frames REALMENTE subiram. Contador velho
    // (pendência de gravação que não mudou nada) diria "1 enviada" sem ter
    // enviado — de novo o app se gabando de trabalho que não fez. Na dúvida,
    // fica no "Sincronizado ✓" sem número.
    _enviadasNoUltimoSync =
        peloFrame == ResultadoDoSync.confirmado ? _gravacoesPendentes : 0;
    await _zerarGravacoesPendentes();
    return null;
  }

  /// True quando a conferência do carimbo apontou atraso de um dos lados.
  /// `indeterminada` fica de fora de propósito: não dá para acusar atraso sem
  /// ter conseguido carimbar — e o banco já respondeu, que era a dúvida antiga.
  bool _carimboAcusaAtraso(ConferenciaDoCarimbo conferencia) =>
      conferencia != ConferenciaDoCarimbo.iguais &&
      conferencia != ConferenciaDoCarimbo.indeterminada;

  /// Apaga a replica local divergente e refaz o arquivo a partir do Turso.
  /// É a única saída quando o servidor recusa os frames locais — sem isso o
  /// app fica preso repetindo o mesmo erro a cada Sincronizar. Devolve false
  /// se não deu (sem internet, por exemplo): aí a conexão anterior já foi
  /// solta, mas o próximo init() reconecta e tenta de novo.
  Future<bool> _reconstruirReplicaLocal() async {
    final url   = _urlAtiva;
    final token = _tokenAtivo;
    if (url == null || token == null) return false;

    final clienteAntigo = _client;
    _connected    = false;
    _client       = null;
    _modoLocal    = false;
    _basePendente = false;
    _invalidarCachesDeLeitura();
    if (clienteAntigo != null) {
      try {
        await clienteAntigo.dispose();
      } catch (_) {}
    }

    if (!await _apagarArquivosDaReplica()) return false;

    final client = await _conectarComCacheLocal(url, token);
    if (client == null) return false;

    _client       = client;
    _connected    = true;
    _modoLocal    = true;
    _basePendente = true;
    try {
      await _estabelecerBaseLocal(client, _timeoutBootstrap);
      return true;
    } catch (_) {
      // Arquivo novo e vazio de frames: fica marcado como base pendente, então
      // nada será escrito nele até o próximo Sincronizar completar o pull.
      return false;
    }
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
    _basePendente    = false;
    _ultimoErroSync  = null;
    _ultimoAvisoSync = null;
    _invalidarCachesDeLeitura();

    if (clienteAntigo != null) {
      try {
        await clienteAntigo.dispose();
      } catch (_) {}
    }

    if (!await _apagarArquivosDaReplica()) return false;

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

  // Chegada dos paletes cadastráveis dinamicamente (tabela `paletes`). A
  // criação da tabela em si é idempotente e mora em _criarEsquema; este
  // marcador registra em app_migrations QUANDO o esquema de paletes entrou
  // no banco, seguindo o padrão da migração da Estante 3.
  static const String _migracaoPaletes = 'paletes_cadastro_dinamico_v1';

  Future<void> _migrarPaletesCadastroDinamico(LibsqlClient client) async {
    try {
      final stmtCheck = await client.prepare(
        'SELECT 1 FROM app_migrations WHERE nome = ? LIMIT 1',
      );
      final jaAplicada =
          (await stmtCheck.query(positional: [_migracaoPaletes]))
              as List<dynamic>;
      if (jaAplicada.isNotEmpty) return;

      final stmtInsert = await client.prepare(
        'INSERT INTO app_migrations (nome, aplicada_em) VALUES (?, ?)',
      );
      await stmtInsert.query(positional: [
        _migracaoPaletes,
        DateTime.now().toIso8601String(),
      ]);
    } catch (_) {
      // Se a migração falhar, não derruba a conexão — só tenta de novo no
      // próximo init().
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
        _produtosCache   = doDisco;
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
      final atual    = await _consultarCatalogo();
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
      // Use prepare() so the return type is consistent with fetchLayout.
      // The bare client.query() returns a different type in libsql_dart 0.9.x
      // and silently fails the cast, yielding an empty list.
      //
      // Sem ORDER BY: estoque_mestre é de outro app e não tem índice em
      // `produto`, então ordenar no banco montava uma b-tree temporária a cada
      // leitura fria. A ordenação em Dart logo abaixo dá o mesmo resultado —
      // a colação BINARY do SQLite e o String.compareTo do Dart são ambos por
      // code point — e a ordem importa rio abaixo (produtosComCaixa documenta
      // "mantém a ordem do catálogo", e o autocomplete faz .take(8)).
      final produtos = await cronometrar('fetchProdutos', () async {
        consultasEmitidas++;
        final stmt = await _client!.prepare(
          'SELECT codigo, produto, categoria FROM estoque_mestre LIMIT 5000',
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
        }).toList()
          ..sort((a, b) => a.nome.compareTo(b.nome));
      });
      _produtosCache       = produtos;
      _produtosCacheEm     = DateTime.now();
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
              codigo:    item[0] as String? ?? '',
              nome:      item[1] as String? ?? '',
              categoria: item[2] as String? ?? '',
              corHex:    categoriaCores[item[2] as String? ?? ''] ?? '#888888',
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
        'url':    _urlConfigurada ?? '',
        'itens':  [
          for (final p in produtos) [p.codigo, p.nome, p.categoria],
        ],
      });
      // Grava num temporário e renomeia: o rename é atômico, então uma queda
      // no meio da escrita não deixa meio catálogo no lugar do inteiro.
      final caminho = await _caminhoCatalogo();
      final temp    = File('$caminho.tmp');
      await temp.writeAsString(dados, flush: true);
      await temp.rename(caminho);
    } catch (_) {
      // Cache de disco é otimização: falhar aqui não pode atrapalhar quem já
      // recebeu a lista.
    }
  }

  CaixaLayout _caixaLayoutDaLinha(Map<String, dynamic> r, int gondolaNum) =>
      CaixaLayout(
        gondolaNum:    r['gondola_num']    as int?    ?? gondolaNum,
        andar:         r['andar']          as int?    ?? 0,
        produtoCodigo: r['produto_codigo'] as String? ?? '',
        produtoNome:   r['produto_nome']   as String? ?? '',
        posX:          (r['pos_x']  as num?)?.toDouble() ?? 0,
        posZ:          (r['pos_z']  as num?)?.toDouble() ?? 0,
        corHex:        r['cor_hex']        as String? ?? '#888888',
      );

  static const String _colunasLayoutGondola =
      'gondola_num, andar, produto_codigo, produto_nome, pos_x, pos_z, cor_hex';

  /// Layout da gôndola já em memória, ou null se ainda não foi lido. Síncrono
  /// de propósito: é o que permite semear a cena no mesmo frame do toque.
  List<CaixaLayout>? layoutEmCache(int gondolaNum) =>
      _cacheGondola.ler(gondolaNum);

  Future<List<CaixaLayout>> fetchLayout(
    int gondolaNum, {
    bool forceRefresh = false,
  }) async {
    final cache = _cacheGondola.ler(gondolaNum);
    // No modo local o cache é sempre confiável: o arquivo só muda por escrita
    // deste app (que grava direto no cache) ou por sync (que o invalida). Não
    // há terceiro escritor, então não há o que revalidar.
    if (!forceRefresh && cache != null && _modoLocal) return cache;
    if (!await _garantirConexao()) return cache ?? [];
    try {
      final itens = await cronometrar('fetchLayout($gondolaNum)', () async {
        consultasEmitidas++;
        final stmt = await _client!.prepare(
          'SELECT $_colunasLayoutGondola '
          'FROM gondola_layout WHERE gondola_num = ? ORDER BY id',
        );
        final rows = await stmt.query(positional: [gondolaNum]);
        return (rows as List<dynamic>)
            .map((dynamic row) =>
                _caixaLayoutDaLinha(row as Map<String, dynamic>, gondolaNum))
            .toList();
      });
      _cacheGondola.gravar(gondolaNum, itens);
      return itens;
    } catch (_) {
      return cache ?? [];
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
    try {
      return await garantirReplicaProntaParaEscrita(
          () => _salvarLayout(gondolaNum, itens));
    } on ReplicaNaoProntaParaEscrita {
      return false;
    }
  }

  Future<bool> _salvarLayout(int gondolaNum, List<CaixaLayout> itens) async {
    if (!await _garantirConexao()) return false;
    final tx = await _client!.transaction();
    try {
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
      await tx.commit();
      // Write-through: as linhas recém-gravadas SÃO o novo estado persistido,
      // então dá para atualizar o cache sem reler.
      _cacheGondola.gravar(gondolaNum, itens);
      await marcarGravacaoLocal();
      return true;
    } catch (_) {
      await tx.rollback();
      _cacheGondola.invalidar(gondolaNum);
      return false;
    }
  }

  CaixaLayoutEstante _caixaLayoutEstanteDaLinha(
          Map<String, dynamic> r, int estanteNum) =>
      CaixaLayoutEstante(
        estanteNum:    r['estante_num']    as int?    ?? estanteNum,
        coluna:        r['coluna']         as int?    ?? 0,
        nivel:         r['nivel']          as int?    ?? 0,
        slot:          r['slot']           as int?    ?? 0,
        produtoCodigo: r['produto_codigo'] as String? ?? '',
        produtoNome:   r['produto_nome']   as String? ?? '',
        corHex:        r['cor_hex']        as String? ?? '#888888',
      );

  static const String _colunasLayoutEstante =
      'estante_num, coluna, nivel, slot, produto_codigo, produto_nome, cor_hex';

  /// Layout da estante já em memória, ou null se ainda não foi lido.
  List<CaixaLayoutEstante>? layoutEstanteEmCache(int estanteNum) =>
      _cacheEstante.ler(estanteNum);

  Future<List<CaixaLayoutEstante>> fetchLayoutEstante(
    int estanteNum, {
    bool forceRefresh = false,
  }) async {
    final cache = _cacheEstante.ler(estanteNum);
    if (!forceRefresh && cache != null && _modoLocal) return cache;
    if (!await _garantirConexao()) return cache ?? [];
    try {
      final itens =
          await cronometrar('fetchLayoutEstante($estanteNum)', () async {
        consultasEmitidas++;
        final stmt = await _client!.prepare(
          'SELECT $_colunasLayoutEstante '
          'FROM estante_layout WHERE estante_num = ? ORDER BY id',
        );
        final rows = await stmt.query(positional: [estanteNum]);
        return (rows as List<dynamic>)
            .map((dynamic row) => _caixaLayoutEstanteDaLinha(
                row as Map<String, dynamic>, estanteNum))
            .where((c) => !_ehBaseNelloreRemovida(c.estanteNum, c.nivel))
            .toList();
      });
      _cacheEstante.gravar(estanteNum, itens);
      return itens;
    } catch (_) {
      return cache ?? [];
    }
  }

  /// Carrega os layouts de TODAS as estruturas em duas consultas e deixa os
  /// dois caches quentes.
  ///
  /// As tabelas são pequenas (dezenas de caixas por estrutura, ~30 estruturas),
  /// então duas consultas sem WHERE saem mais baratas que as ~30 que percorrer
  /// o carrossel dispararia uma a uma — e, chamadas do prewarm enquanto o
  /// usuário olha o mapa, saem inteiramente de fora do caminho crítico.
  ///
  /// Falha em silêncio: é otimização, não caminho obrigatório. Se não der
  /// certo, cada estrutura volta a ser lida sob demanda como antes.
  Future<void> precarregarLayouts() async {
    if (!await _garantirConexao()) return;
    try {
      await cronometrar('precarregarLayouts', () async {
        consultasEmitidas++;
        final stmtG = await _client!.prepare(
          'SELECT $_colunasLayoutGondola '
          'FROM gondola_layout ORDER BY gondola_num, id',
        );
        final rowsG = await stmtG.query() as List<dynamic>;
        // Semeia vazio para toda estrutura conhecida: sem isso uma prateleira
        // sem nenhuma caixa nunca apareceria no agrupamento, ficaria como miss
        // e voltaria a consultar o banco a cada abertura. Lista vazia em cache
        // é uma resposta legítima ("consultado, não tem nada").
        final porGondola = <int, List<CaixaLayout>>{
          for (var n = 1; n <= 12; n++) n: <CaixaLayout>[],
        };
        for (final dynamic row in rowsG) {
          final r = row as Map<String, dynamic>;
          final num_ = r['gondola_num'] as int? ?? 0;
          porGondola
              .putIfAbsent(num_, () => <CaixaLayout>[])
              .add(_caixaLayoutDaLinha(r, num_));
        }
        // Nunca sobrescreve o que já está em cache: o prewarm começa na
        // abertura do app e pode terminar DEPOIS de um salvarLayout ter feito
        // write-through, e aí devolveria a estrutura ao estado anterior.
        porGondola.forEach((n, itens) {
          if (_cacheGondola.ler(n) == null) _cacheGondola.gravar(n, itens);
        });

        consultasEmitidas++;
        final stmtE = await _client!.prepare(
          'SELECT $_colunasLayoutEstante '
          'FROM estante_layout ORDER BY estante_num, id',
        );
        final rowsE = await stmtE.query() as List<dynamic>;
        final porEstante = <int, List<CaixaLayoutEstante>>{
          for (final n in ordemNavegacaoEstantes) n: <CaixaLayoutEstante>[],
        };
        for (final dynamic row in rowsE) {
          final r = row as Map<String, dynamic>;
          final num_ = r['estante_num'] as int? ?? 0;
          final caixa = _caixaLayoutEstanteDaLinha(r, num_);
          // Mesmo filtro de fetchLayoutEstante: sem ele uma leitura do cache
          // discordaria de uma consulta fresca da mesma estante.
          if (_ehBaseNelloreRemovida(caixa.estanteNum, caixa.nivel)) continue;
          porEstante
              .putIfAbsent(num_, () => <CaixaLayoutEstante>[])
              .add(caixa);
        }
        porEstante.forEach((n, itens) {
          if (_cacheEstante.ler(n) == null) _cacheEstante.gravar(n, itens);
        });
      });
    } catch (_) {
      // Prewarm é best-effort — ver doc acima.
    }
  }

  /// Aquece os caches de leitura enquanto o usuário ainda está no mapa.
  ///
  /// Chamado logo depois do init() na abertura do app: `LojaPage` é a home e
  /// não emite trabalho de banco próprio, então essa janela é livre. É o que
  /// faz a primeira abertura de uma cena custar o mesmo que as seguintes.
  Future<void> prewarm() async {
    if (!_connected) return;
    await precarregarLayouts();
    await fetchProdutos();
  }

  Future<bool> salvarLayoutEstante(
      int estanteNum, List<CaixaLayoutEstante> itens) async {
    try {
      return await garantirReplicaProntaParaEscrita(
          () => _salvarLayoutEstante(estanteNum, itens));
    } on ReplicaNaoProntaParaEscrita {
      return false;
    }
  }

  Future<bool> _salvarLayoutEstante(
      int estanteNum, List<CaixaLayoutEstante> itens) async {
    if (!await _garantirConexao()) return false;
    final tx = await _client!.transaction();
    try {
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
      await tx.commit();
      await marcarGravacaoLocal();
      return true;
    } catch (_) {
      await tx.rollback();
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
      _buscarNoGalpao(like),
    ]);
    return _anexarQuantidades(
        [...resultados[0], ...resultados[1], ...resultados[2]]);
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
      final stmt = await _client!.prepare(
        'SELECT posicao, ordem, produto_codigo, produto_nome, quantidade '
        'FROM galpao_racks '
        'WHERE produto_nome LIKE ? OR produto_codigo LIKE ? '
        'ORDER BY produto_nome, posicao, ordem LIMIT 20',
      );
      final rows = await stmt.query(positional: [like, like]);
      return (rows as List<dynamic>).map((dynamic row) {
        final r       = row as Map<String, dynamic>;
        final posicao = r['posicao'] as int? ?? 0;
        final ordem   = r['ordem']   as int? ?? 1;
        final rua     = GalpaoConfig.ruaDe(posicao);
        return ProdutoEncontrado(
          nome:           r['produto_nome']   as String? ?? '',
          tipo:           localTipoGalpao,
          numero:         posicao,
          // O endereço do galpão é '<número> · N<nível>'; a rua é derivada e
          // entra só para orientar quem vai buscar.
          nivelDescricao: rua == null
              ? 'N$ordem'
              : 'Rua ${rua.numero} · N$ordem',
          produtoCodigo:  r['produto_codigo'] as String? ?? '',
          nivel:          ordem,
          // A quantidade vem da própria linha do rack — não precisa esperar
          // o espelho em estoque_localizado.
          quantidade:     (r['quantidade'] as num?)?.toDouble(),
        );
      }).toList();
    } catch (_) {
      // Tabela ainda não criada (replica antes do bootstrap): a busca nas
      // outras estruturas não pode cair por causa disso.
      return [];
    }
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

      // gôndola: 'g|codigo|num|face|andar' · estante: 'e|codigo|num|nivel' ·
      // galpão: 'x|codigo|posicao|ordem'.
      //
      // O prefixo por TIPO não é enfeite: os números de posição do galpão
      // (1–129) se sobrepõem aos de estante (1–21), então uma chave montada só
      // com o número faria a quantidade do galpão ser somada dentro da
      // estante de mesmo número.
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
        final chave = switch (tipo) {
          'gondola'      => 'g|$codigo|$localNum|$fc|$an',
          localTipoGalpao => 'x|$codigo|$localNum|$an',
          _ =>
            'e|$codigo|$localNum|${an.clamp(0, niveisProdutoPara(localNum) - 1)}',
        };
        somas[chave] = (somas[chave] ?? 0) + qtd;
      }

      return encontrados.map((p) {
        // O galpão já traz a quantidade da própria linha do rack; o espelho
        // em estoque_localizado só confirmaria o mesmo número.
        if (p.tipo == localTipoGalpao) return p;
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
        // No palete o nível é a FILEIRA (0 = corredor), não uma altura, então
        // "Nível 2" não ajudaria ninguém a achar o produto. Como esta busca
        // agrupa por estante + nível (sem coluna), o mais específico que dá
        // pra dizer é a faixa de posições daquela fileira: 1–5, 6–10, 11–15.
        final descricao = ehPalete(estanteNum)
            ? 'Posições ${n * colunasPalete + 1}–${n * colunasPalete + colunasPalete}'
            : 'Nível ${n + 1}';
        return ProdutoEncontrado(
          nome:           r['produto_nome']   as String? ?? '',
          tipo:           'estante',
          numero:         estanteNum,
          nivelDescricao: descricao,
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
