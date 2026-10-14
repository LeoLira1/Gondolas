import 'dart:async';
import 'dart:collection';
import 'dart:convert';

typedef LinhasConsulta = List<Map<String, dynamic>>;

/// Cópias de respostas confirmadas pelo servidor. Nunca recebe SQL de escrita.
/// A geração impede uma leitura iniciada antes de um commit de desfazê-lo.
///
/// Cada chave tem a sua JANELA: servida da cópia, ela só volta ao banco quando
/// a última tentativa passou dessa idade. O Turso cobra por linha varrida, e
/// as tabelas grandes (estoque_mestre, estoque_localizado) eram relidas
/// inteiras a cada 30 s de uso — o mesmo número de linhas para descobrir, quase
/// sempre, que nada tinha mudado.
///
/// A idade da cópia é a do último SUCESSO, e ela vai para o disco junto com as
/// linhas (`'<chave>|em'`). Só em memória, cada vez que o Android matava o app
/// a cópia voltava "vencida" e a abertura seguinte relia tudo — umas 11 mil
/// linhas por abertura a frio.
class ConsultaCache {
  ConsultaCache({
    required this.lerDisco,
    required this.gravarDisco,
    required this.aoAtualizar,
  });
  final Future<String?> Function(String) lerDisco;
  final Future<void> Function(String, String) gravarDisco;
  final void Function() aoAtualizar;
  final _valores = <String, LinhasConsulta>{};
  final _consultas = <String, Future<LinhasConsulta> Function()>{};
  final _emAndamento = <String, Future<LinhasConsulta>>{};

  /// Início da última ida ao banco, deu certo ou não. É a trava que impede
  /// reler de novo dentro da janela — inclusive durante uma queda de rede.
  final _ultimaTentativa = <String, DateTime>{};

  /// Início da última leitura que DEU CERTO. É a idade de verdade da cópia:
  /// uma tentativa que falhou não deixa a cópia mais nova.
  final _sucessoEm = <String, DateTime>{};

  /// Última vez que alguém (fora do prewarm) leu a chave.
  final _ultimoUso = <String, DateTime>{};
  final _persistencias = <String, Future<void>>{};
  final _janelas = <String, Duration>{};
  final _somenteLeitura = <String>{};
  final _semAviso = <String>{};
  final _geracoes = <String, int>{};
  int _geracao = 0;
  Future<void>? _passada;

  /// A janela de quem não pede outra: a das consultas pequenas, que custam
  /// poucas linhas e mudam a cada lançamento.
  static const Duration janelaPadrao = Duration(seconds: 30);

  /// Valor de Zone que marca leituras que não contam como uso (o prewarm lê
  /// tudo na abertura, e isso não quer dizer que alguém esteja vendo).
  static const Object zonaSemUso = #consultaCacheSemUso;

  /// Roda [acao] sem marcar uso das chaves que ela ler.
  static Future<T> semMarcarUso<T>(Future<T> Function() acao) =>
      runZoned(acao, zoneValues: {zonaSemUso: true});

  bool get atualizando => _passada != null;

  static String _chaveCarimbo(String chave) => '$chave|em';

  /// [janela] é a idade a partir da qual a cópia servida dispara uma
  /// releitura em segundo plano.
  ///
  /// [somenteLeitura] marca consulta cujas colunas ESTE app nunca grava
  /// (estoque_mestre, mapa de produtos, contagem_itens): nenhum commit daqui a
  /// deixa velha, então a resposta que chega depois de um commit vale do mesmo
  /// jeito. Sem isso, um lançamento confirmado no meio da leitura do catálogo
  /// fazia a resposta nova ser jogada fora em troca da cópia de ontem.
  ///
  /// [avisar] falso: uma releitura que trouxe dado diferente NÃO chama
  /// [aoAtualizar]. É para cópias que mudam o dia todo (contagens feitas em
  /// outro app) e que as telas recalculam quando precisam — avisar a cada
  /// mudança recarregaria o app inteiro em cascata.
  Future<LinhasConsulta> ler(
    String chave,
    Future<LinhasConsulta> Function() consultar, {
    bool usarCache = true,
    bool forceRefresh = false,
    bool falharSemCache = false,
    Duration janela = janelaPadrao,
    bool somenteLeitura = false,
    bool avisar = true,
  }) async {
    _consultas[chave] = consultar;
    _janelas[chave] = janela;
    if (somenteLeitura) {
      _somenteLeitura.add(chave);
    } else {
      _somenteLeitura.remove(chave);
    }
    if (avisar) {
      _semAviso.remove(chave);
    } else {
      _semAviso.add(chave);
    }
    if (Zone.current[zonaSemUso] != true) _ultimoUso[chave] = DateTime.now();
    if (usarCache) await _carregarDoDisco(chave);
    final atual = _valores[chave];
    if (usarCache && !forceRefresh && atual != null) {
      final ultima = _ultimaTentativa[chave];
      if (ultima == null || DateTime.now().difference(ultima) > janela) {
        unawaited(_atualizar(chave).then<void>((_) {}, onError: (_) {}));
      }
      return _copiar(atual);
    }
    try {
      return _copiar(await _atualizar(chave));
    } catch (_) {
      if (forceRefresh || (falharSemCache && (!usarCache || atual == null)))
        rethrow;
      return usarCache ? _copiar(atual ?? []) : [];
    }
  }

  /// Traz do disco a cópia e o carimbo do último sucesso, se ainda não estão
  /// em memória. True quando há cópia.
  Future<bool> _carregarDoDisco(String chave) async {
    if (_valores.containsKey(chave)) return true;
    try {
      final texto = await lerDisco(chave);
      if (texto == null || _valores.containsKey(chave)) {
        return _valores.containsKey(chave);
      }
      _valores[chave] = (jsonDecode(texto) as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
    } catch (_) {
      return _valores.containsKey(chave); // Cópia inválida: buscar no banco.
    }
    try {
      final carimbo = DateTime.tryParse(
        await lerDisco(_chaveCarimbo(chave)) ?? '',
      );
      if (carimbo != null && !_sucessoEm.containsKey(chave)) {
        _sucessoEm[chave] = carimbo;
        _ultimaTentativa.putIfAbsent(chave, () => carimbo);
      }
    } catch (_) {
      // Sem carimbo a cópia vale como vencida: a primeira leitura relê.
    }
    return true;
  }

  Future<LinhasConsulta> _atualizar(String chave) {
    final existente = _emAndamento[chave];
    if (existente != null) return existente;
    final geracao = _geracao;
    final geracaoChave = _geracoes[chave] ?? 0;
    final inicio = DateTime.now();
    _ultimaTentativa[chave] = inicio;
    late final Future<LinhasConsulta> futuro;
    futuro =
        Future<LinhasConsulta>(() async {
          final novo = await _consultas[chave]!();
          final invalidada =
              geracaoChave != (_geracoes[chave] ?? 0) ||
              (geracao != _geracao && !_somenteLeitura.contains(chave));
          if (invalidada) {
            // A resposta é de antes de um commit e foi jogada fora: a
            // tentativa não conta, e a cópia continua com a idade que tinha.
            final sucesso = _sucessoEm[chave];
            if (identical(_ultimaTentativa[chave], inicio)) {
              if (sucesso == null) {
                _ultimaTentativa.remove(chave);
              } else {
                _ultimaTentativa[chave] = sucesso;
              }
            }
            return _valores[chave] ?? novo;
          }
          final anterior = _valores[chave];
          final mudou =
              anterior != null && _assinatura(anterior) != _assinatura(novo);
          _valores[chave] = _copiar(novo);
          _sucessoEm[chave] = inicio;
          await _persistir(chave, jsonEncode(novo));
          unawaited(_persistir(_chaveCarimbo(chave), inicio.toIso8601String()));
          if (mudou && !_semAviso.contains(chave)) aoAtualizar();
          return novo;
        }).whenComplete(() {
          if (identical(_emAndamento[chave], futuro))
            _emAndamento.remove(chave);
        });
    _emAndamento[chave] = futuro;
    return futuro;
  }

  /// Grava [linhas] como a cópia confirmada de [chave] (um commit deste
  /// aparelho, ou uma leitura completa feita por fora). Uma leitura de
  /// [chave] que já estava no ar não pode mais sobrescrevê-la.
  ///
  /// [renovarJanela] falso é para cópia que só foi CORRIGIDA em parte (ver
  /// [atualizarParte]): o resto dela continua com a idade que tinha.
  Future<void> confirmar(
    String chave,
    LinhasConsulta linhas, {
    bool renovarJanela = true,
  }) async {
    _geracoes[chave] = (_geracoes[chave] ?? 0) + 1;
    _valores[chave] = _copiar(linhas);
    if (renovarJanela) {
      final agora = DateTime.now();
      _ultimaTentativa[chave] = agora;
      _sucessoEm[chave] = agora;
      unawaited(_persistir(_chaveCarimbo(chave), agora.toIso8601String()));
    }
    await _persistir(chave, jsonEncode(linhas));
  }

  /// Atualiza uma estrutura confirmada sem apagar posições de outras estruturas.
  /// Se a cópia completa ainda não existe, não cria um índice parcial.
  ///
  /// NÃO renova a janela da cópia inteira: quem grava o dia todo corrigia
  /// a cópia a cada gravação, e o que outro aparelho mudou nunca chegava.
  /// [ordenar] mantém a ordem da cópia (as linhas novas iriam para o fim).
  /// Devolve a cópia inteira já corrigida, ou null quando não havia cópia.
  Future<LinhasConsulta?> atualizarParte(
    String chave,
    bool Function(Map<String, dynamic>) pertence,
    LinhasConsulta novas, {
    int Function(Map<String, dynamic>, Map<String, dynamic>)? ordenar,
  }) async {
    if (!await _carregarDoDisco(chave)) return null;
    final linhas = [..._valores[chave]!.where((r) => !pertence(r)), ...novas];
    if (ordenar != null) linhas.sort(ordenar);
    await confirmar(chave, linhas, renovarJanela: false);
    return _copiar(linhas);
  }

  /// Faz a próxima leitura de [chave] ir ao banco — também depois de reabrir
  /// o app (o carimbo em disco sai junto).
  void expirar(String chave) {
    _ultimaTentativa.remove(chave);
    _sucessoEm.remove(chave);
    unawaited(_persistir(_chaveCarimbo(chave), ''));
  }

  /// Só o carimbo em disco: a cópia vale nesta sessão como está, mas uma
  /// reabertura do app a trata como vencida. É para quando a cópia ainda
  /// vai ser corrigida em memória e o app pode morrer antes disso.
  void esquecerCarimboEmDisco(String chave) =>
      unawaited(_persistir(_chaveCarimbo(chave), ''));

  /// True quando a cópia de [chave] não teve leitura bem-sucedida dentro de
  /// [janela] (ou não existe). Lê o carimbo do disco se preciso.
  Future<bool> vencida(String chave, Duration janela) async {
    await _carregarDoDisco(chave);
    final sucesso = _sucessoEm[chave];
    return sucesso == null || DateTime.now().difference(sucesso) > janela;
  }

  /// Depois de um commit: a consulta que já estava no ar não pode mais
  /// sobrescrever a cópia, e quem pedir atualização daqui para frente ganha
  /// uma consulta NOVA — pegar carona na antiga devolveria o estado de antes
  /// da gravação para quem pediu justamente para conferir a gravação.
  ///
  /// Sem [chaves], vale para todas, menos as [somenteLeitura] (nenhum commit
  /// daqui as deixa velhas, e descartar a leitura delas é jogar fora linhas
  /// já cobradas). Com [chaves], só para elas.
  void invalidarConsultasEmAndamento([Iterable<String>? chaves]) {
    if (chaves == null) {
      _geracao++;
      _emAndamento.removeWhere((chave, _) => !_somenteLeitura.contains(chave));
      return;
    }
    for (final chave in chaves) {
      _geracoes[chave] = (_geracoes[chave] ?? 0) + 1;
      _emAndamento.remove(chave);
    }
  }

  /// Relê as consultas conhecidas.
  ///
  /// Com [soVencidas], só as que passaram da própria janela; com [usadasHa],
  /// só as lidas por alguém nesse intervalo (o prewarm não conta). É o que a
  /// volta ao app usa, para não reler o estoque_mestre inteiro nem os ~35
  /// layouts que ninguém abriu a cada desbloqueio de tela. Uma volta ao app
  /// com outra passada no ar não faz nada.
  ///
  /// Sem filtro (o Sincronizar) espera a passada em andamento e relê TUDO —
  /// antes, ele voltava na hora sem reler nada e ainda avisava sucesso.
  Future<void> atualizar({bool soVencidas = false, Duration? usadasHa}) async {
    final emCurso = _passada;
    if (emCurso != null) {
      if (soVencidas) return;
      await emCurso.then<void>((_) {}, onError: (_) {});
    }
    final agora = DateTime.now();
    final chaves = _consultas.keys.where((chave) {
      if (!soVencidas) return true;
      if (!_tentativaVencida(chave, agora)) return false;
      if (usadasHa == null) return true;
      final uso = _ultimoUso[chave];
      return uso != null && agora.difference(uso) <= usadasHa;
    }).toList();
    final futuro = Future.wait(chaves.map(_atualizar));
    _passada = futuro;
    try {
      await futuro;
    } finally {
      if (identical(_passada, futuro)) _passada = null;
    }
  }

  bool _tentativaVencida(String chave, DateTime agora) {
    final ultima = _ultimaTentativa[chave];
    return ultima == null ||
        agora.difference(ultima) > (_janelas[chave] ?? janelaPadrao);
  }

  Future<void> _persistir(String chaveDisco, String texto) {
    final futuro = (_persistencias[chaveDisco] ?? Future<void>.value()).then((
      _,
    ) async {
      try {
        await gravarDisco(chaveDisco, texto);
      } catch (_) {
        // O commit online continua confirmado mesmo se o disco estiver cheio.
      }
    });
    _persistencias[chaveDisco] = futuro;
    return futuro;
  }

  /// Identidade do conteúdo, sem depender da ordem das linhas nem da ordem
  /// das colunas. Uma correção parcial põe as linhas no fim da cópia, e a
  /// releitura seguinte (que volta em ordem de rowid) acusava "mudou" sem
  /// nada ter mudado no banco — e cada aviso desses recarregava o app.
  static String _assinatura(LinhasConsulta linhas) =>
      (linhas
              .map((r) => jsonEncode(SplayTreeMap<String, dynamic>.from(r)))
              .toList()
            ..sort())
          .join('\n');

  static LinhasConsulta _copiar(LinhasConsulta linhas) =>
      linhas.map((r) => Map<String, dynamic>.from(r)).toList();
}
