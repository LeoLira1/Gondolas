import 'dart:async';
import 'dart:convert';

typedef LinhasConsulta = List<Map<String, dynamic>>;

/// Cópias de respostas confirmadas pelo servidor. Nunca recebe SQL de escrita.
/// A geração impede uma leitura iniciada antes de um commit de desfazê-lo.
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
  final _ultimaTentativa = <String, DateTime>{};
  final _persistencias = <String, Future<void>>{};
  int _geracao = 0;
  bool atualizando = false;

  Future<LinhasConsulta> ler(
    String chave,
    Future<LinhasConsulta> Function() consultar, {
    bool usarCache = true,
    bool forceRefresh = false,
    bool falharSemCache = false,
  }) async {
    _consultas[chave] = consultar;
    if (usarCache && !_valores.containsKey(chave)) {
      try {
        final texto = await lerDisco(chave);
        if (texto != null && !_valores.containsKey(chave)) {
          _valores[chave] = (jsonDecode(texto) as List)
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList();
        }
      } catch (_) {
        /* Cópia inválida: buscar no banco. */
      }
    }
    final atual = _valores[chave];
    if (usarCache && !forceRefresh && atual != null) {
      final ultima = _ultimaTentativa[chave];
      if (ultima == null ||
          DateTime.now().difference(ultima) > const Duration(seconds: 30)) {
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

  Future<LinhasConsulta> _atualizar(String chave) {
    final existente = _emAndamento[chave];
    if (existente != null) return existente;
    final geracao = _geracao;
    _ultimaTentativa[chave] = DateTime.now();
    late final Future<LinhasConsulta> futuro;
    futuro =
        Future<LinhasConsulta>(() async {
          final novo = await _consultas[chave]!();
          if (geracao != _geracao) return _valores[chave] ?? novo;
          final anterior = _valores[chave];
          final mudou = jsonEncode(anterior) != jsonEncode(novo);
          _valores[chave] = _copiar(novo);
          await _persistir(chave, novo);
          if (anterior != null && mudou) aoAtualizar();
          return novo;
        }).whenComplete(() {
          if (identical(_emAndamento[chave], futuro))
            _emAndamento.remove(chave);
        });
    _emAndamento[chave] = futuro;
    return futuro;
  }

  Future<void> confirmar(String chave, LinhasConsulta linhas) async {
    _geracao++;
    _valores[chave] = _copiar(linhas);
    _ultimaTentativa[chave] = DateTime.now();
    await _persistir(chave, linhas);
  }

  /// Atualiza uma estrutura confirmada sem apagar posições de outras estruturas.
  /// Se a cópia completa ainda não existe, não cria um índice parcial.
  Future<void> atualizarParte(
    String chave,
    bool Function(Map<String, dynamic>) pertence,
    LinhasConsulta novas,
  ) async {
    if (!_valores.containsKey(chave)) {
      try {
        final texto = await lerDisco(chave);
        if (texto == null) return;
        _valores.putIfAbsent(
          chave,
          () => (jsonDecode(texto) as List)
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList(),
        );
      } catch (_) {
        return;
      }
    }
    await confirmar(chave, [
      ..._valores[chave]!.where((r) => !pertence(r)),
      ...novas,
    ]);
  }

  void expirar(String chave) => _ultimaTentativa.remove(chave);

  void invalidarConsultasEmAndamento() => _geracao++;

  Future<void> atualizar() async {
    if (atualizando) return;
    atualizando = true;
    try {
      await Future.wait(_consultas.keys.toList().map(_atualizar));
    } finally {
      atualizando = false;
    }
  }

  Future<void> _persistir(String chave, LinhasConsulta linhas) {
    final texto = jsonEncode(linhas);
    final futuro = (_persistencias[chave] ?? Future<void>.value()).then((
      _,
    ) async {
      try {
        await gravarDisco(chave, texto);
      } catch (_) {
        // O commit online continua confirmado mesmo se o disco estiver cheio.
      }
    });
    _persistencias[chave] = futuro;
    return futuro;
  }

  static LinhasConsulta _copiar(LinhasConsulta linhas) =>
      linhas.map((r) => Map<String, dynamic>.from(r)).toList();
}
