// ─────────────────────────────────────────────────────────────────────────────
// Diagnóstico de leituras: quanto ESTE aparelho leu do Turso, por tipo
// ─────────────────────────────────────────────────────────────────────────────
//
// O gráfico de Rows Read do Turso é da conta inteira: os dashboards, o app
// Contagem e todos os aparelhos somados. Para saber se uma mudança aqui
// funcionou, cada aparelho conta o que ele mesmo pediu, por tipo de consulta,
// dia a dia.
//
// O cliente do libsql não devolve as linhas VARRIDAS (o que o Turso cobra),
// só as devolvidas. Para leitura de tabela inteira as duas são a mesma coisa;
// pelo índice, o Turso soma ainda a busca no índice (o real fica um pouco
// acima). Para as consultas que agrupam a tabela (a última contagem de cada
// produto) ou filtram sem índice (os estocados com saldo), o banco varre a
// tabela inteira e devolve menos linhas: aí a estimativa usa o tamanho da
// tabela, medido sob pedido (ver [tabelaVarridaPor]).
//
// Sem banco e sem Flutter, de propósito: a persistência entra por função.

import 'dart:async';
import 'dart:convert';

/// Consultas e linhas devolvidas de um tipo, num dia.
class LeiturasDoTipo {
  LeiturasDoTipo([this.consultas = 0, this.linhas = 0]);
  int consultas;
  int linhas;

  List<int> paraJson() => [consultas, linhas];
}

/// A tabela que uma consulta do tipo [tipo] varre inteira para devolver
/// menos linhas (agrupa, ou filtra sem índice), ou null quando devolvido =
/// varrido.
String? tabelaVarridaPor(String tipo) {
  if (tipo.startsWith('ultima_contagem_itens')) return 'contagem_itens';
  if (tipo.startsWith('ultima_contagem_ciclico')) return 'inventario_cicli';
  if (tipo == 'baixa_divergencias') return 'divergencias';
  // `WHERE saldo > 0`, sem índice: a tabela do app Estocados inteira.
  if (tipo == 'estocados') return 'materiais_terceiros';
  return null;
}

/// Todas as tabelas que [tabelaVarridaPor] devolve: só o tamanho delas entra
/// na estimativa, então só elas são medidas.
const List<String> tabelasVarridas = [
  'contagem_itens',
  'inventario_cicli',
  'divergencias',
  'materiais_terceiros',
];

/// Conta as leituras por dia (data local) e por tipo. Guarda no aparelho os
/// últimos [diasGuardados] dias (pela data, não pela quantidade), gravando no
/// máximo a cada [respiro] — cada gravação no SharedPreferences reescreve o
/// arquivo inteiro no Android. Com o app em segundo plano
/// ([emPrimeiroPlano] falso) grava logo: o Android pode matar o processo.
class ContadorDeLeituras {
  ContadorDeLeituras({
    required this.carregarDisco,
    required this.gravarDisco,
    DateTime Function()? agora,
    this.respiro = const Duration(seconds: 60),
    this.diasGuardados = 8,
  }) : _agora = agora ?? DateTime.now;

  final Future<String?> Function() carregarDisco;
  final Future<void> Function(String) gravarDisco;
  final DateTime Function() _agora;
  final Duration respiro;
  final int diasGuardados;

  final Map<String, Map<String, LeiturasDoTipo>> _dias = {};
  bool _carregado = false;
  Future<void>? _carregando;
  Timer? _gravacaoPendente;

  static String diaDe(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// Falso com o app em segundo plano: aí cada leitura grava logo, em vez de
  /// esperar o [respiro]. Ao passar para falso, grava o que estava pendente.
  bool get emPrimeiroPlano => _emPrimeiroPlano;
  bool _emPrimeiroPlano = true;
  set emPrimeiroPlano(bool valor) {
    _emPrimeiroPlano = valor;
    if (!valor) unawaited(gravarJa().catchError((_) {}));
  }

  /// [linhas] lidas por [consultas] consultas de [tipo], agora. [consultas] 0
  /// é para somar linhas a uma consulta já anotada.
  void registrar(String tipo, int linhas, {int consultas = 1}) {
    final dia = _dias.putIfAbsent(diaDe(_agora()), () => {});
    final l = dia.putIfAbsent(tipo, LeiturasDoTipo.new);
    l.consultas += consultas;
    l.linhas += linhas;
    _agendarGravacao();
  }

  /// O dia mais antigo que ainda fica guardado.
  String get _primeiroDiaGuardado {
    final hoje = _agora();
    return diaDe(
      DateTime(hoje.year, hoje.month, hoje.day - (diasGuardados - 1)),
    );
  }

  /// Os dias guardados (mais novo primeiro), cada um com os tipos lidos.
  /// Junta o que já estava no disco com o desta sessão.
  Future<List<({String dia, Map<String, LeiturasDoTipo> tipos})>> dias() async {
    await _carregar();
    final primeiro = _primeiroDiaGuardado;
    final chaves = _dias.keys.where((d) => d.compareTo(primeiro) >= 0).toList()
      ..sort((a, b) => b.compareTo(a));
    return [
      for (final d in chaves) (dia: d, tipos: Map.unmodifiable(_dias[d]!)),
    ];
  }

  /// Apaga tudo (no aparelho também).
  Future<void> zerar() async {
    await _carregar();
    _dias.clear();
    _gravacaoPendente?.cancel();
    _gravacaoPendente = null;
    await gravarDisco(jsonEncode({}));
  }

  /// Grava agora o que estiver pendente (o app indo para segundo plano).
  Future<void> gravarJa() async {
    if (_gravacaoPendente == null) return;
    _gravacaoPendente!.cancel();
    _gravacaoPendente = null;
    await _gravar();
  }

  void _agendarGravacao() {
    _gravacaoPendente ??= Timer(
      _emPrimeiroPlano ? respiro : Duration.zero,
      () {
        _gravacaoPendente = null;
        unawaited(_gravar().catchError((_) {}));
      },
    );
  }

  Future<void> _gravar() async {
    await _carregar();
    final primeiro = _primeiroDiaGuardado;
    _dias.removeWhere((d, _) => d.compareTo(primeiro) < 0);
    await gravarDisco(
      jsonEncode({
        for (final e in _dias.entries)
          e.key: {for (final t in e.value.entries) t.key: t.value.paraJson()},
      }),
    );
  }

  /// Junta o disco (sessões anteriores) ao que já foi contado nesta sessão.
  Future<void> _carregar() {
    if (_carregado) return Future.value();
    return _carregando ??= () async {
      try {
        final texto = await carregarDisco();
        if (texto != null && texto.isNotEmpty) {
          final json = jsonDecode(texto) as Map<String, dynamic>;
          for (final d in json.entries) {
            final dia = _dias.putIfAbsent(d.key, () => {});
            for (final t in (d.value as Map<String, dynamic>).entries) {
              final par = (t.value as List).cast<num>();
              final l = dia.putIfAbsent(t.key, LeiturasDoTipo.new);
              l.consultas += par[0].toInt();
              l.linhas += par[1].toInt();
            }
          }
        }
      } catch (_) {
        // Arquivo ilegível: começa do zero.
      }
      _carregado = true;
    }();
  }
}

/// Estimativa das linhas VARRIDAS de um dia: as devolvidas, trocando as dos
/// tipos que agrupam uma tabela por consultas × tamanho da tabela (quando o
/// tamanho é conhecido). [semTamanho] recebe os tipos que ficaram só com o
/// devolvido por falta da medida.
int estimarVarridas(
  Map<String, LeiturasDoTipo> tipos,
  Map<String, int> tamanhos, {
  Set<String>? semTamanho,
}) {
  var total = 0;
  for (final e in tipos.entries) {
    final tabela = tabelaVarridaPor(e.key);
    final tamanho = tabela == null ? null : tamanhos[tabela];
    if (tabela != null && tamanho == null) semTamanho?.add(e.key);
    total += tamanho == null ? e.value.linhas : e.value.consultas * tamanho;
  }
  return total;
}
