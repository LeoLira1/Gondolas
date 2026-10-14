import 'dart:async';
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
  final _janelas = <String, Duration>{};
  final _somenteLeitura = <String>{};
  int _geracao = 0;
  bool atualizando = false;

  /// A janela de quem não pede outra: a das consultas pequenas, que custam
  /// poucas linhas e mudam a cada lançamento.
  static const Duration janelaPadrao = Duration(seconds: 30);

  /// [janela] é a idade a partir da qual a cópia servida dispara uma
  /// releitura em segundo plano.
  ///
  /// [somenteLeitura] marca tabela que ESTE app nunca grava (estoque_mestre,
  /// mapa de produtos): nenhum commit daqui a deixa velha, então a resposta
  /// que chega depois de um commit vale do mesmo jeito. Sem isso, um
  /// lançamento confirmado no meio da leitura do catálogo fazia a resposta
  /// nova ser jogada fora em troca da cópia de ontem.
  Future<LinhasConsulta> ler(
    String chave,
    Future<LinhasConsulta> Function() consultar, {
    bool usarCache = true,
    bool forceRefresh = false,
    bool falharSemCache = false,
    Duration janela = janelaPadrao,
    bool somenteLeitura = false,
  }) async {
    _consultas[chave] = consultar;
    _janelas[chave] = janela;
    if (somenteLeitura) {
      _somenteLeitura.add(chave);
    } else {
      _somenteLeitura.remove(chave);
    }
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

  Future<LinhasConsulta> _atualizar(String chave) {
    final existente = _emAndamento[chave];
    if (existente != null) return existente;
    final geracao = _geracao;
    _ultimaTentativa[chave] = DateTime.now();
    late final Future<LinhasConsulta> futuro;
    futuro =
        Future<LinhasConsulta>(() async {
          final novo = await _consultas[chave]!();
          if (geracao != _geracao && !_somenteLeitura.contains(chave)) {
            return _valores[chave] ?? novo;
          }
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

  /// Depois de um commit: a consulta que já estava no ar não pode mais
  /// sobrescrever a cópia, e quem pedir atualização daqui para frente ganha
  /// uma consulta NOVA — pegar carona na antiga devolveria o estado de antes
  /// da gravação para quem pediu justamente para conferir a gravação.
  void invalidarConsultasEmAndamento() {
    _geracao++;
    _emAndamento.clear();
  }

  /// Relê as consultas conhecidas. Com [soVencidas], só as que passaram da
  /// própria janela — é o que a volta ao app usa, para não reler o
  /// estoque_mestre inteiro a cada desbloqueio de tela. O Sincronizar pede
  /// tudo.
  Future<void> atualizar({bool soVencidas = false}) async {
    if (atualizando) return;
    atualizando = true;
    try {
      final agora = DateTime.now();
      await Future.wait(
        _consultas.keys
            .where((chave) => !soVencidas || _vencida(chave, agora))
            .toList()
            .map(_atualizar),
      );
    } finally {
      atualizando = false;
    }
  }

  bool _vencida(String chave, DateTime agora) {
    final ultima = _ultimaTentativa[chave];
    return ultima == null ||
        agora.difference(ultima) > (_janelas[chave] ?? janelaPadrao);
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
