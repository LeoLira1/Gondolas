// ─────────────────────────────────────────────────────────────────────────────
// Layouts de gôndola e estante servidos de UMA cópia por tabela
// ─────────────────────────────────────────────────────────────────────────────
//
// Antes, a mesma tabela era lida por dois caminhos: uma cópia por estrutura
// (gondola_N / estante_N, ~35 consultas na abertura do app) e uma cópia da
// busca (SELECT DISTINCT da tabela inteira). A abertura e o Sincronizar liam
// as duas, e a volta ao app relia todas as estruturas já abertas na sessão.
//
// Agora há uma cópia completa por tabela (todas as colunas que a cena usa). A
// busca filtra dela, a cena de cada estrutura sai dela, e abrir uma estrutura
// relê só ela, pelo índice do número, corrigindo a cópia no lugar — o mesmo
// que o galpão faz com as posições gravadas. Sem banco e sem Flutter, de
// propósito: é o que deixa testar as regras de corrida abaixo.

typedef LinhasLayout = List<Map<String, dynamic>>;

/// Como terminou um "Salvar layout".
enum ResultadoSalvarLayout {
  salvo,

  /// Outro aparelho mudou a estrutura depois que esta tela a carregou: nada
  /// foi gravado.
  conflito,
  falhou,
}

/// O resultado e os códigos que a estrutura tinha no banco logo antes do
/// salvamento (lidos dentro da própria transação): é deles que sai quais
/// produtos a edição tirou.
typedef SalvamentoLayout = ({
  ResultadoSalvarLayout resultado,
  Set<String> codigosAntes,
});

/// Colunas que dizem ONDE está cada caixa. Nome e cor ficam de fora: o
/// salvamento os atualiza do catálogo, e isso não é mudança de layout.
const colunasConteudoGondola = ['andar', 'produto_codigo', 'pos_x', 'pos_z'];
const colunasConteudoEstante = ['coluna', 'nivel', 'slot', 'produto_codigo'];

/// O conteúdo de um layout como texto comparável: o multiconjunto das caixas
/// nas [colunas], sem depender da ordem das linhas. Números comparados como
/// double (o banco devolve 1 ou 1.0 conforme a coluna e a cópia passa por
/// JSON).
String assinaturaLayout(
  Iterable<Map<String, dynamic>> linhas,
  List<String> colunas,
) {
  String valor(Object? v) => v is num ? v.toDouble().toString() : '$v';
  final caixas = [
    for (final r in linhas) colunas.map((c) => valor(r[c])).join('|'),
  ]..sort();
  return caixas.join('\n');
}

/// Uma tabela de layout (gondola_layout ou estante_layout) servida de uma
/// cópia completa, com releitura por estrutura.
class LayoutsDaCopia {
  LayoutsDaCopia({
    required this.coluna,
    required this.janelaEstrutura,
    required this.lerEstrutura,
    required this.corrigirCopia,
    required this.copiaEmMemoria,
    required this.carregarCopia,
    required this.copiaVencida,
  });

  /// Coluna do número da estrutura (`gondola_num` ou `estante_num`).
  final String coluna;

  /// Idade a partir da qual abrir a estrutura a relê do banco.
  final Duration janelaEstrutura;

  /// Lê do banco as linhas de UMA estrutura (pelo índice do número).
  final Future<LinhasLayout> Function(int numero) lerEstrutura;

  /// Troca na cópia completa as linhas que [pertence] aceita por [novas].
  /// Devolve null quando ainda não há cópia completa.
  final Future<LinhasLayout?> Function(
    bool Function(Map<String, dynamic>) pertence,
    LinhasLayout novas,
  )
  corrigirCopia;

  /// A cópia completa em memória (o objeto muda a cada atualização), ou null.
  final LinhasLayout? Function() copiaEmMemoria;

  /// Traz a cópia completa do disco para a memória. True quando há cópia.
  final Future<bool> Function() carregarCopia;

  /// True quando a cópia completa não foi lida inteira dentro de [janela].
  final Future<bool> Function(Duration janela) copiaVencida;

  final _relidaEm = <int, DateTime>{};
  final _geracao = <int, int>{};
  final _sujas = <int>{};
  final _emAndamento = <int, Future<LinhasLayout>>{};

  // Estruturas lidas quando ainda não havia cópia completa (instalação nova,
  // dados apagados): sem cópia para corrigir, as linhas ficam aqui.
  final _semCopia = <int, LinhasLayout>{};

  LinhasLayout? _agrupadaDe;
  Map<int, LinhasLayout> _agrupada = const {};

  /// As linhas de [numero] que já estão em memória, sem ir ao banco: a fatia
  /// da cópia completa (lista vazia se a estrutura não tem nenhuma linha), ou
  /// a leitura avulsa de quando não havia cópia. Null quando nada se sabe —
  /// e "nada se sabe" nunca pode virar uma estrutura vazia na tela, porque um
  /// "Salvar layout" em cima dela apagaria o layout de verdade.
  LinhasLayout? linhasEmMemoria(int numero) {
    final copia = copiaEmMemoria();
    if (copia == null) return _semCopia[numero];
    if (!identical(copia, _agrupadaDe)) {
      final grupos = <int, LinhasLayout>{};
      for (final r in copia) {
        final n = r[coluna];
        if (n is int) (grupos[n] ??= []).add(r);
      }
      _agrupada = grupos;
      _agrupadaDe = copia;
    }
    return _agrupada[numero] ?? const [];
  }

  /// As linhas de [numero] em dia: relidas do banco (só a estrutura) quando
  /// passaram de [janelaEstrutura] desde a última leitura dela ou da cópia
  /// inteira, ou com [forcar]. Sem rede, a cópia que houver; sem rede e sem
  /// cópia, lança — quem chamou mostra que não carregou.
  Future<LinhasLayout> linhas(int numero, {bool forcar = false}) async {
    final temCopia = await carregarCopia();
    if (!forcar && !_sujas.contains(numero)) {
      final relida = _relidaEm[numero];
      final emDia =
          (relida != null &&
              DateTime.now().difference(relida) <= janelaEstrutura) ||
          (temCopia && !await copiaVencida(janelaEstrutura));
      final conhecidas = linhasEmMemoria(numero);
      if (emDia && conhecidas != null) return conhecidas;
      final andamento = _emAndamento[numero];
      if (andamento != null) return andamento;
    }
    final futuro = _reler(numero);
    _emAndamento[numero] = futuro;
    try {
      return await futuro;
    } finally {
      if (identical(_emAndamento[numero], futuro)) _emAndamento.remove(numero);
    }
  }

  Future<LinhasLayout> _reler(int numero) async {
    final geracao = _geracao[numero] ?? 0;
    final inicio = DateTime.now();
    final LinhasLayout lidas;
    try {
      lidas = await lerEstrutura(numero);
    } catch (_) {
      final conhecidas = linhasEmMemoria(numero);
      if (conhecidas != null) return conhecidas;
      rethrow;
    }
    // Uma gravação deste aparelho passou na frente: a leitura pode ter saído
    // antes do commit, e a cópia já tem o que foi gravado.
    if ((_geracao[numero] ?? 0) != geracao) {
      return linhasEmMemoria(numero) ?? lidas;
    }
    _relidaEm[numero] = inicio;
    _sujas.remove(numero);
    final corrigida = await corrigirCopia((r) => r[coluna] == numero, lidas);
    if (corrigida == null) _semCopia[numero] = lidas;
    return lidas;
  }

  /// Depois de um commit deste aparelho: as linhas gravadas SÃO o estado da
  /// estrutura. Leituras dela que estavam no ar não valem mais.
  Future<void> salva(int numero, LinhasLayout linhas) async {
    _geracao[numero] = (_geracao[numero] ?? 0) + 1;
    _emAndamento.remove(numero);
    _relidaEm[numero] = DateTime.now();
    _sujas.remove(numero);
    final corrigida = await corrigirCopia((r) => r[coluna] == numero, linhas);
    if (corrigida == null) _semCopia[numero] = List.of(linhas);
  }

  /// Gravação que falhou sem saber se chegou ao banco (resposta perdida): a
  /// próxima leitura da estrutura vai ao banco, mesmo com a cópia em dia.
  void suja(int numero) {
    _geracao[numero] = (_geracao[numero] ?? 0) + 1;
    _emAndamento.remove(numero);
    _sujas.add(numero);
  }

  /// Troca de banco ou reconexão: nada do que se sabia das estruturas vale.
  void esquecer() {
    _relidaEm.clear();
    _semCopia.clear();
    _sujas.clear();
    _emAndamento.clear();
    for (final n in _geracao.keys.toList()) {
      _geracao[n] = _geracao[n]! + 1;
    }
  }
}
