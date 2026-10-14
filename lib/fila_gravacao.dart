import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import 'gravacao_lote.dart';
import 'turso_service.dart';

/// O que aconteceu com uma operação que saiu da fila.
class EventoFila {
  final OperacaoPendente operacao;

  /// Null = gravada no servidor. Preenchida = descartada por conflito ou
  /// recusa (reenviar não resolveria).
  final FalhaGravacao? falha;

  const EventoFila(this.operacao, [this.falha]);

  bool get gravada => falha == null;
}

/// Fila das gravações do galpão e do barracão: a tela aplica na hora e a fila
/// leva ao banco, em ordem, quando der.
///
/// Antes cada lançamento esperava a ida ao banco, e um segundo lançamento
/// feito durante essa espera era IGNORADO em silêncio — era o "às vezes nem
/// lança" da rede ruim. E uma falha de rede desfazia o rack na tela e pedia
/// para a pessoa refazer tudo.
///
/// Agora:
///
/// - **Nada se perde.** A operação é gravada no aparelho (preferências) ANTES
///   de qualquer tentativa de rede, e sobrevive a fechar o app. Ela sai da
///   fila só quando o servidor confirma — ou quando o servidor diz que ela
///   não cabe mais (ver [TipoFalhaGravacao.conflito]).
/// - **Uma por vez, na ordem.** Um ajuste feito logo depois de um lançamento
///   precisa do rack que o lançamento cria; mandar em paralelo inverteria a
///   ordem na rede.
/// - **Reenvio sozinho.** Falha de rede → espera crescente (1 s, 2 s, 4 s…
///   até 20 s) e tenta de novo com o MESMO UUID. O lote é idempotente (ver
///   gravacao_lote.dart), então uma resposta perdida nunca vira rack em
///   dobro.
/// - **Uma requisição por operação.** O lote inteiro vai num pipeline só.
class FilaGravacao extends ChangeNotifier {
  FilaGravacao.para({
    required Future<void> Function(OperacaoPendente) executar,
    required Future<String?> Function() ler,
    required Future<void> Function(String) gravar,
    Future<void> Function(Duration)? esperar,
  })  : _executar = executar,
        _ler = ler,
        _gravar = gravar,
        _esperarFn = esperar;

  static FilaGravacao? _instancia;

  /// A fila do app. Uma só para os dois prédios: a ordem entre elas é a
  /// ordem em que a pessoa agiu.
  factory FilaGravacao() => _instancia ??= FilaGravacao.para(
        executar: executarOperacao,
        ler: () async =>
            (await SharedPreferences.getInstance()).getString(chaveDisco),
        gravar: (texto) async {
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setString(chaveDisco, texto)) {
            throw StateError('fila não persistida');
          }
        },
      );

  static const String chaveDisco = chaveFilaGravacao;

  final Future<void> Function(OperacaoPendente) _executar;
  final Future<String?> Function() _ler;
  final Future<void> Function(String) _gravar;
  final Future<void> Function(Duration)? _esperarFn;

  final List<OperacaoPendente> _fila = [];
  Future<void>? _carregando;
  bool _carregada = false;
  bool _processando = false;
  bool _enviando = false;
  int _tentativas = 0;
  String? _ultimoErro;
  Completer<void>? _espera;
  final _eventos = StreamController<EventoFila>.broadcast();

  /// O que ainda não foi confirmado pelo servidor, na ordem em que foi feito.
  List<OperacaoPendente> get pendentes => List.unmodifiable(_fila);

  bool get vazia => _fila.isEmpty;

  /// True enquanto uma requisição está no ar.
  bool get enviando => _enviando;

  /// Tentativas seguidas que falharam por rede. Zero = a última deu certo.
  int get tentativas => _tentativas;

  /// Por que a última tentativa falhou (texto cru), ou null.
  String? get ultimoErro => _ultimoErro;

  /// Cada operação que saiu da fila — gravada ou descartada.
  Stream<EventoFila> get eventos => _eventos.stream;

  /// Lê do aparelho o que ficou pendente (de uma sessão anterior, inclusive)
  /// e começa a enviar. Pode ser chamada quantas vezes for: só a primeira lê.
  Future<void> carregar() => _carregando ??= _carregarDoDisco();

  Future<void> _carregarDoDisco() async {
    try {
      final salvas = OperacaoPendente.decodificarLista(await _ler());
      final jaNaFila = {for (final o in _fila) o.uuid};
      _fila.insertAll(0, salvas.where((o) => !jaNaFila.contains(o.uuid)));
    } catch (_) {
      // Sem leitura do disco a fila segue com o que entrar nesta sessão.
    }
    _carregada = true;
    notifyListeners();
    unawaited(_processar());
  }

  /// Põe a operação na fila (e no disco) e dispara o envio. Volta assim que
  /// ela está guardada no aparelho — a ida ao banco acontece por trás.
  Future<void> enfileirar(OperacaoPendente op) async {
    // Na memória já: a tela desenha por cima do banco o que está aqui.
    _fila.add(op);
    notifyListeners();
    // O disco é lido ANTES de ser escrito. Gravar primeiro trocaria o que uma
    // sessão anterior deixou pendente por esta operação sozinha — a leitura
    // põe as antigas na frente desta, e só então a lista inteira é gravada.
    await carregar();
    await _persistir();
    tentarAgora();
    unawaited(_processar());
  }

  /// Interrompe a espera entre tentativas e tenta já — o botão da barra, a
  /// volta do app para a frente, uma gravação nova.
  void tentarAgora() {
    final espera = _espera;
    if (espera != null && !espera.isCompleted) espera.complete();
  }

  /// Joga fora tudo o que não foi confirmado. Só por pedido explícito da
  /// pessoa (a fila nunca descarta sozinha o que pode ter conserto).
  Future<List<OperacaoPendente>> descartarTodas() async {
    final descartadas = List<OperacaoPendente>.of(_fila);
    _fila.clear();
    _tentativas = 0;
    _ultimoErro = null;
    notifyListeners();
    await _persistir();
    return descartadas;
  }

  /// Completa quando a fila esvaziar (ou na hora, se já está vazia) — por
  /// confirmação, conflito ou descarte.
  Future<void> esvaziada() {
    if (_fila.isEmpty) return Future<void>.value();
    final pronto = Completer<void>();
    void ouvir() {
      if (_fila.isNotEmpty || pronto.isCompleted) return;
      removeListener(ouvir);
      pronto.complete();
    }

    addListener(ouvir);
    return pronto.future;
  }

  Future<void> _persistir() async {
    try {
      await _gravar(OperacaoPendente.codificarLista(_fila));
    } catch (_) {
      // Sem disco a operação ainda vale nesta sessão; perder a cópia é
      // menos grave do que recusar o lançamento.
    }
  }

  /// Espera entre tentativas: 1, 2, 4, 8, 16 e depois 20 s. Curta no começo
  /// porque o comum na loja é o sinal voltar em segundos.
  static Duration atrasoParaTentativa(int tentativa) =>
      Duration(seconds: min(20, 1 << min(tentativa - 1, 5)));

  Future<void> _aguardar(Duration atraso) async {
    final espera = _espera = Completer<void>();
    final fn = _esperarFn;
    if (fn != null) {
      await Future.any([fn(atraso), espera.future]);
    } else {
      final timer = Timer(atraso, () {
        if (!espera.isCompleted) espera.complete();
      });
      await espera.future;
      timer.cancel();
    }
    _espera = null;
  }

  Future<void> _processar() async {
    if (_processando || !_carregada) return;
    _processando = true;
    try {
      while (_fila.isNotEmpty) {
        final op = _fila.first;
        _enviando = true;
        notifyListeners();
        FalhaGravacao? falha;
        try {
          await _executar(op);
        } catch (e) {
          falha = classificarFalhaGravacao(e);
        }
        _enviando = false;
        // Descartada pela pessoa enquanto estava no ar: nada a fazer com ela.
        if (_fila.isEmpty || !identical(_fila.first, op)) continue;
        if (falha != null && falha.transitoria) {
          _tentativas++;
          _ultimoErro = falha.detalhe;
          notifyListeners();
          await _aguardar(atrasoParaTentativa(_tentativas));
          continue;
        }
        _fila.removeAt(0);
        _tentativas = 0;
        _ultimoErro = null;
        notifyListeners();
        await _persistir();
        _eventos.add(EventoFila(op, falha));
      }
    } finally {
      _processando = false;
      _enviando = false;
      notifyListeners();
    }
  }
}

/// Manda UMA operação ao banco: um lote, uma requisição (ver
/// [TursoService.executarLote]). Lança [FalhaGravacao].
Future<void> executarOperacao(OperacaoPendente op) async {
  final turso = TursoService();
  // Antes da conferência do banco: é a conexão que define qual é o ativo.
  await turso.garantirConexao();
  // O banco da operação é o banco em que a pessoa a fez. Se as credenciais
  // mudaram, ela não vai para o banco novo de jeito nenhum.
  final ativo = turso.identidadeAtiva;
  if (ativo != null && op.banco.isNotEmpty && op.banco != ativo) {
    throw const FalhaGravacao(
      TipoFalhaGravacao.recusada,
      'Gravação feita em outro banco (a URL foi trocada em ⚙️).',
    );
  }
  await turso.executarLote(
    op.comandos(
      aplicadaEm: DateTime.now().toIso8601String(),
      dispositivo: await turso.dispositivo(),
    ),
  );
  // O espelho em estoque_localizado só mudou neste local: é só ele que a
  // próxima leitura de quantidades relê (antes a cópia inteira expirava, e
  // cada palete custava o estoque_localizado inteiro de novo no Turso).
  turso.marcarLocalGravado(
    op.tipo.doGalpao ? localTipoGalpaoSql : localTipoBarracaoSql,
    op.local,
  );
  // Expira as cópias de leitura que dependem do que mudou (busca do
  // barracão) e impede consulta antiga de desfazer o commit.
  await turso.marcarGravacaoLocal(quantidadesPorLocal: true);
}
