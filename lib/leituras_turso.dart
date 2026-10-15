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
// só as devolvidas. Para leitura sem agrupamento (tabela inteira ou pelo
// índice) as duas são a mesma coisa. Para as consultas que agrupam a tabela
// (a última contagem de cada produto), o banco varre a tabela inteira e
// devolve uma linha por produto: aí a estimativa usa o tamanho da tabela,
// medido sob pedido (ver [tabelaVarridaPor]).
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
/// menos linhas (agrupa), ou null quando devolvido = varrido.
String? tabelaVarridaPor(String tipo) {
  if (tipo.startsWith('ultima_contagem_itens')) return 'contagem_itens';
  if (tipo.startsWith('ultima_contagem_ciclico')) return 'inventario_cicli';
  if (tipo == 'baixa_divergencias') return 'divergencias';
  return null;
}

/// Conta as leituras por dia (data local) e por tipo. Guarda no aparelho os
/// últimos [diasGuardados] dias, gravando no máximo a cada [respiro] — cada
/// gravação no SharedPreferences reescreve o arquivo inteiro no Android.
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

  /// Uma leitura feita agora: [linhas] devolvidas por uma consulta de [tipo].
  void registrar(String tipo, int linhas) {
    final dia = _dias.putIfAbsent(diaDe(_agora()), () => {});
    final l = dia.putIfAbsent(tipo, LeiturasDoTipo.new);
    l.consultas++;
    l.linhas += linhas;
    _agendarGravacao();
  }

  /// Os dias guardados (mais novo primeiro), cada um com os tipos lidos.
  /// Junta o que já estava no disco com o desta sessão.
  Future<List<({String dia, Map<String, LeiturasDoTipo> tipos})>> dias() async {
    await _carregar();
    final chaves = _dias.keys.toList()..sort((a, b) => b.compareTo(a));
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
    _gravacaoPendente ??= Timer(respiro, () {
      _gravacaoPendente = null;
      unawaited(_gravar().catchError((_) {}));
    });
  }

  Future<void> _gravar() async {
    await _carregar();
    final dias = _dias.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final velho in dias.skip(diasGuardados)) {
      _dias.remove(velho);
    }
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
