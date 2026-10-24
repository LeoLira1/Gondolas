import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:libsql_dart/libsql_dart.dart';
import 'galpao_config.dart';
import 'gravacao_lote.dart' show sqlProdutosGalpao;
import 'models.dart' show estantesRemovidas;
import 'turso_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Filtro de categorias de depósito (Fase 3.1)
// ─────────────────────────────────────────────────────────────────────────────
//
// O mapa 3D da LOJA representa gôndolas/estantes de equipamentos e itens de
// balcão — produtos destas categorias moram no GALPÃO e nunca terão endereço
// de loja cadastrado, então só inflariam a lista "sem endereço". Ficam de
// fora do Modo Conferência DA LOJA por completo (nem estrutura, nem sem
// endereço), mas continuam contados à parte pro total bater com o dashboard.
//
// ⚠️ Endereço cadastrado na loja vence a categoria. A premissa acima é "nunca
// terão endereço de loja"; quando o produto TEM face de gôndola ou prateleira
// de estante, a premissa caiu e a estrutura acende normalmente — foi assim que
// a engraxadeira (ACESSORIOS DE LUBRIFICACAO, pega por 'LUBRIFIC') sumia da
// gôndola 1. O filtro só decide o destino de quem não tem endereço na loja.
//
// ⚠️ O filtro vale só para o lado da LOJA. O cruzamento com o galpão é feito
// com TODOS os pendentes do dia, sem filtro nenhum: é justamente nos racks
// do galpão que herbicida, adubo e óleo têm endereço, e filtrá-los ali
// apagaria o Modo Conferência do galpão inteiro. Um pendente de categoria de
// depósito só continua "oculto" (contado em
// [ModoConferenciaResultado.totalFiltradosDeposito]) quando também não tem
// rack no galpão — aí não há mesmo onde mostrá-lo.
//
// Edite esta lista livremente — é o único lugar que precisa mudar.
const List<String> categoriasExcluidasKeywords = [
  'HERBICID',      // herbicidas
  'FUNGICID',      // fungicidas
  'INSETICID',     // inseticidas
  'INOCULANTE',
  'LUBRIFIC',      // óleos lubrificantes (categoria LUBRIFICANTES)
  'OLEO MINERAL',
  'OLEO VEGETAL',
  'ADUBO',         // pega ADUBOS, ADUBOS FOLIARES etc.
  'RACAO',
  'MATURADOR',
  'FORMICID',
  'NEMATICID',
];

// Keywords cuja categoria pode variar/estar errada no cadastro: além da
// categoria, testamos também o nome do produto normalizado.
const List<String> _keywordsTambemNoNomeProduto = [
  'OLEO MINERAL',
  'OLEO VEGETAL',
];

// Categorias que uma keyword acima pega por engano — acessório é produto de
// gôndola, não de depósito. 'ACESSORIOS DE LUBRIFICACAO' (engraxadeira, bico
// de graxa) casava com 'LUBRIFIC' e sumia do mapa da loja mesmo tendo face de
// gôndola cadastrada. Testado antes das keywords, vence todas elas.
const List<String> _categoriasNuncaDeDeposito = [
  'ACESSORIO',
];

/// Uppercase + remoção de acentos, pra comparar categoria/nome sem depender
/// de como foram digitados no cadastro (Ó vs O, Ç vs C etc.).
String normalizarTexto(String s) {
  const comAcento = 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ';
  const semAcento  = 'AAAAAEEEEIIIIOOOOOUUUUCN';
  final upper  = s.toUpperCase();
  final buffer = StringBuffer();
  for (final ch in upper.split('')) {
    final idx = comAcento.indexOf(ch);
    buffer.write(idx == -1 ? ch : semAcento[idx]);
  }
  return buffer.toString();
}

/// Um item pendente de conferência — linha de contagem_itens (tabela do
/// dashboard Streamlit, SOMENTE LEITURA aqui) ainda não confirmada hoje.
class ItemPendente {
  final String codigo;
  final String produto;
  final String categoria;
  final double qtdEstoque;

  const ItemPendente({
    required this.codigo,
    required this.produto,
    required this.categoria,
    required this.qtdEstoque,
  });
}

/// Verifica se um pendente pertence a uma categoria de depósito (ver
/// [categoriasExcluidasKeywords]) e por isso deve ficar fora do Modo
/// Conferência por completo.
bool ehCategoriaDeDeposito(ItemPendente item) {
  final categoriaNorm = normalizarTexto(item.categoria);
  if (_categoriasNuncaDeDeposito.any(categoriaNorm.contains)) return false;
  if (categoriasExcluidasKeywords.any(categoriaNorm.contains)) return true;

  // OLEO MINERAL/VEGETAL podem estar cadastrados numa categoria diferente:
  // testa também o nome do produto antes de descartar.
  final produtoNorm = normalizarTexto(item.produto);
  return _keywordsTambemNoNomeProduto.any(produtoNorm.contains);
}

/// Uma estrutura do mapa (gôndola ou estante) que contém pendentes de hoje.
class EstruturaConferencia {
  final String tipo; // 'gondola' ou 'estante'
  final int numero;
  final List<ItemPendente> itens;

  const EstruturaConferencia({
    required this.tipo,
    required this.numero,
    required this.itens,
  });

  Set<String> get codigos => itens.map((i) => i.codigo).toSet();
}

/// Uma posição do galpão (1–129) que guarda pendentes de hoje.
///
/// O irmão de [EstruturaConferencia] do outro lado da rua: lá a chave é
/// tipo + número da estrutura da loja, aqui é o número global da posição de
/// chão. Não guarda nível de propósito — o rack pendente pode estar em
/// qualquer altura da pilha, e a pilha desce quando alguém esvazia um nível
/// (ver galpao_config.dart). Quem acende é o CÓDIGO do produto, então a cena
/// reencontra o rack certo mesmo depois de uma renumeração.
class PosicaoConferencia {
  final int posicao; // 1–129
  final List<ItemPendente> itens;

  const PosicaoConferencia({
    required this.posicao,
    required this.itens,
  });

  Set<String> get codigos => itens.map((i) => i.codigo).toSet();
}

/// Resultado pronto do cruzamento entre os pendentes de contagem_itens e os
/// endereços cadastrados: estruturas da loja (gôndola/estante) e posições do
/// galpão que precisam de conferência hoje + itens cujo código não aparece em
/// endereço nenhum.
class ModoConferenciaResultado {
  final Map<String, EstruturaConferencia> estruturas; // chave '$tipo:$numero'
  // Posições do galpão com pendentes, por número global (1–129).
  final Map<int, PosicaoConferencia> galpao;
  final Map<int, PosicaoConferencia> barracao;
  final List<ItemPendente> semEndereco;
  final int totalProdutos; // pendentes únicos de hoje relevantes à loja
  // Pendentes de categorias de depósito (ver categoriasExcluidasKeywords) que
  // também não têm rack no galpão: não há onde mostrá-los, então ficam
  // ocultos e contados à parte pro total bater com o dashboard.
  final int totalFiltradosDeposito;

  const ModoConferenciaResultado({
    required this.estruturas,
    required this.semEndereco,
    required this.totalProdutos,
    required this.totalFiltradosDeposito,
    this.galpao = const {},
    this.barracao = const {},
  });

  static const vazio = ModoConferenciaResultado(
    estruturas: {},
    galpao: {},
    barracao: {},
    semEndereco: [],
    totalProdutos: 0,
    totalFiltradosDeposito: 0,
  );

  int get totalEstruturas => estruturas.length;
  bool get vazioHoje => totalProdutos == 0;

  // ── Lado do galpão ─────────────────────────────────────────────────────────

  /// Quantas posições de chão acendem no galpão hoje.
  int get totalPosicoesGalpao => galpao.length;

  /// Códigos pendentes com rack no galpão — é o conjunto que a cena consulta
  /// para decidir qual cubo fica ciano.
  Set<String> get codigosGalpao => {
        for (final p in galpao.values) ...p.codigos,
      };

  /// Produtos distintos pendentes no galpão. Distintos, não a soma dos itens
  /// das posições: o mesmo produto pode estar em vários racks e contaria
  /// várias vezes.
  int get totalProdutosGalpao => codigosGalpao.length;

  bool get galpaoVazioHoje => galpao.isEmpty;

  int get totalPosicoesBarracao => barracao.length;
  Set<String> get codigosBarracao => {
        for (final p in barracao.values) ...p.codigos,
      };
  int get totalProdutosBarracao => codigosBarracao.length;
  bool get barracaoVazioHoje => barracao.isEmpty;
}

/// Cruza os pendentes do dia com os endereços já lidos do banco.
///
/// Pura de propósito: é aqui que vive a regra de qual balde recebe cada
/// pendente (estrutura da loja, posição do galpão, sem endereço, filtrado), e
/// é o que os testes exercitam sem precisar de banco. [pendentes] são TODOS
/// os pendentes do dia, inclusive as categorias de depósito — o filtro delas
/// é aplicado aqui, e só do lado da loja.
ModoConferenciaResultado montarConferencia({
  required List<ItemPendente> pendentes,
  required Map<String, Set<int>> gondolasPorCodigo,
  required Map<String, Set<int>> estantesPorCodigo,
  required Map<String, Set<int>> galpaoPorCodigo,
  Map<String, Set<int>> barracaoPorCodigo = const {},
}) {
  final estruturas    = <String, List<ItemPendente>>{};
  final posicoes      = <int, List<ItemPendente>>{};
  final paletesBarracao = <int, List<ItemPendente>>{};
  final semEndereco   = <ItemPendente>[];
  var totalLoja       = 0;
  var filtradosDeposito = 0;

  for (final item in pendentes) {
    // O galpão vale para todo pendente, filtrado ou não: é o prédio onde as
    // categorias de depósito moram.
    final noGalpao = galpaoPorCodigo[item.codigo] ?? const <int>{};
    for (final numero in noGalpao) {
      posicoes.putIfAbsent(numero, () => []).add(item);
    }
    final noBarracao = barracaoPorCodigo[item.codigo] ?? const <int>{};
    for (final id in noBarracao) {
      paletesBarracao.putIfAbsent(id, () => []).add(item);
    }

    final gondolas = gondolasPorCodigo[item.codigo] ?? const <int>{};
    final estantes = estantesPorCodigo[item.codigo] ?? const <int>{};
    final temEnderecoNaLoja = gondolas.isNotEmpty || estantes.isNotEmpty;

    // O filtro de categorias existe pra não inflar o "sem endereço" com
    // produto que mora no galpão — face de gôndola cadastrada desmente essa
    // premissa. Endereço na loja vence a categoria: a estrutura acende, mesmo
    // que a keyword tenha pego a categoria (certa ou por engano).
    if (!temEnderecoNaLoja && ehCategoriaDeDeposito(item)) {
      // Sem rack no galpão o item não tem onde aparecer — segue oculto, como
      // antes de o galpão existir no app.
      if (noGalpao.isEmpty && noBarracao.isEmpty) filtradosDeposito++;
      continue;
    }

    totalLoja++;
    if (!temEnderecoNaLoja) {
      // "Sem endereço" é sem endereço NENHUM: com rack no galpão o item já
      // tem para onde mandar quem vai conferir.
      if (noGalpao.isEmpty && noBarracao.isEmpty) semEndereco.add(item);
      continue;
    }
    for (final g in gondolas) {
      estruturas.putIfAbsent('gondola:$g', () => []).add(item);
    }
    for (final e in estantes) {
      estruturas.putIfAbsent('estante:$e', () => []).add(item);
    }
  }

  return ModoConferenciaResultado(
    estruturas: {
      for (final entry in estruturas.entries)
        entry.key: EstruturaConferencia(
          tipo:   entry.key.split(':')[0],
          numero: int.parse(entry.key.split(':')[1]),
          itens:  entry.value,
        ),
    },
    galpao: {
      for (final entry in posicoes.entries)
        entry.key: PosicaoConferencia(
          posicao: entry.key,
          itens:   entry.value,
        ),
    },
    barracao: {
      for (final entry in paletesBarracao.entries)
        entry.key: PosicaoConferencia(
          posicao: entry.key,
          itens: entry.value,
        ),
    },
    semEndereco:            semEndereco,
    totalProdutos:          totalLoja,
    totalFiltradosDeposito: filtradosDeposito,
  );
}

class ModoConferenciaService {
  static final ModoConferenciaService _instance =
      ModoConferenciaService._internal();
  factory ModoConferenciaService() => _instance;
  ModoConferenciaService._internal();

  // Limite de placeholders por IN(...): mantém a query bem abaixo do teto de
  // variáveis do SQLite (999) mesmo num dia com muitos pendentes.
  static const int _maxCodigosPorConsulta = 400;

  Future<LibsqlClient?> _conexao() async {
    if (!await TursoService().garantirConexao()) return null;
    return TursoService().client;
  }

  // ── Conferência guardada ──────────────────────────────────────────────────
  //
  // Cada pedido varria contagem_itens (a tabela do app de contagem, que só
  // cresce) e mais quatro consultas: ligar o modo, voltar de cada gôndola,
  // ir e voltar do galpão pelo banner, e cada aviso de dados novos no galpão
  // e no barracão. Numa sessão de conferência eram dezenas de varreduras para
  // o mesmo resultado. Agora o resultado vale um minuto, e pedidos
  // simultâneos dividem a mesma leitura.

  /// Quanto vale a conferência guardada para quem não força.
  static const Duration validade = Duration(seconds: 60);

  ModoConferenciaResultado? _guardada;
  DateTime? _guardadaEm;
  String? _guardadaDoBanco;
  int? _guardadaNaInvalidacao;
  Future<ModoConferenciaResultado>? _emAndamento;
  int _geracao = 0;

  /// Troca a leitura do banco (testes).
  @visibleForTesting
  Future<ModoConferenciaResultado> Function()? leitorParaTeste;

  /// Esquece a conferência guardada: a próxima busca vai ao banco. É o que a
  /// volta ao app chama — a confirmação é feita no app de contagem, então
  /// quem confere sai daqui e volta.
  void esquecer() {
    _guardada = null;
    _guardadaEm = null;
    _emAndamento = null;
    _geracao++;
  }

  /// Os pendentes do dia cruzados com os endereços (ver [_consultar]).
  ///
  /// Sem [forcar], serve a conferência guardada há menos de [validade], ou
  /// pega carona na leitura em andamento. Com [forcar] (ligar o modo, o botão
  /// de atualizar, o Sincronizar), lê o banco na hora, sem pegar carona numa
  /// leitura iniciada antes do pedido. Falha de leitura devolve vazio e não
  /// fica guardada.
  Future<ModoConferenciaResultado> buscarConferenciaDoDia({
    bool forcar = false,
  }) {
    // Outro banco, ou um Sincronizar (de qualquer tela) desde a guardada:
    // ela não vale mais.
    final banco = TursoService().identidadeAtiva;
    final invalidacao = TursoService().leiturasInvalidadas;
    if (banco != _guardadaDoBanco || invalidacao != _guardadaNaInvalidacao) {
      esquecer();
      _guardadaDoBanco = banco;
      _guardadaNaInvalidacao = invalidacao;
    }
    if (!forcar) {
      final guardada = _guardada;
      final em = _guardadaEm;
      if (guardada != null &&
          em != null &&
          DateTime.now().difference(em) < validade) {
        return Future.value(guardada);
      }
      final andamento = _emAndamento;
      if (andamento != null) return andamento;
    }
    final geracao = ++_geracao;
    late final Future<ModoConferenciaResultado> futuro;
    futuro = (leitorParaTeste ?? _consultar)()
        .then((resultado) {
          if (geracao == _geracao) {
            _guardada = resultado;
            _guardadaEm = DateTime.now();
          }
          return resultado;
        }, onError: (Object _) => ModoConferenciaResultado.vazio)
        .whenComplete(() {
          if (identical(_emAndamento, futuro)) _emAndamento = null;
        });
    _emAndamento = futuro;
    return futuro;
  }

  /// Busca os pendentes de contagem_itens e cruza com gondola_layout,
  /// estante_layout, galpao_racks e barracao_enderecos numa única passada —
  /// 5 queries no total (ou
  /// poucas mais, se o lote de códigos precisar ser quebrado), nunca uma por
  /// estrutura. Lança em falha (sem conexão inclusive), para a falha não
  /// ficar guardada como "nada pendente".
  ///
  /// As três consultas recebem TODOS os códigos pendentes: o filtro de
  /// categorias de depósito não é mais aplicado antes de perguntar ao banco,
  /// porque é o próprio endereço que decide se ele vale (ver a nota no topo do
  /// arquivo). O cruzamento em si é de [montarConferencia].
  Future<ModoConferenciaResultado> _consultar() async {
    final client = await _conexao();
    if (client == null) throw StateError('Sem conexão com o banco');

    final pendentes = await _buscarPendentes(client);
    if (pendentes.isEmpty) return ModoConferenciaResultado.vazio;

    final codigosTodos = pendentes.map((p) => p.codigo).toList();

    final resultados = await Future.wait([
      _buscarEnderecosGondola(client, codigosTodos),
      _buscarEnderecosEstante(client, codigosTodos),
      _buscarEnderecosGalpao(client, codigosTodos),
      _buscarEnderecosBarracao(client, codigosTodos),
    ]);

    return montarConferencia(
      pendentes:         pendentes,
      gondolasPorCodigo: resultados[0],
      estantesPorCodigo: resultados[1],
      galpaoPorCodigo:   resultados[2],
      barracaoPorCodigo: resultados[3],
    );
  }

  Future<List<ItemPendente>> _buscarPendentes(LibsqlClient client) async {
    final stmt = await client.prepare(
      "SELECT codigo, produto, categoria, qtd_estoque FROM contagem_itens "
      "WHERE status = 'pendente'",
    );
    final rows = await stmt.query();
    TursoService().contarLeitura(
      'conferencia_pendentes',
      (rows as List<dynamic>).length,
    );
    return rows.map((dynamic row) {
      final r = row as Map<String, dynamic>;
      return ItemPendente(
        codigo:     r['codigo']       as String? ?? '',
        produto:    r['produto']      as String? ?? '',
        categoria:  r['categoria']    as String? ?? '',
        qtdEstoque: (r['qtd_estoque'] as num?)?.toDouble() ?? 0,
      );
    }).where((i) => i.codigo.isNotEmpty).toList();
  }

  Future<Map<String, Set<int>>> _buscarEnderecosGondola(
      LibsqlClient client, List<String> codigos) async {
    final mapa = <String, Set<int>>{};
    for (var i = 0; i < codigos.length; i += _maxCodigosPorConsulta) {
      final fim = (i + _maxCodigosPorConsulta < codigos.length)
          ? i + _maxCodigosPorConsulta
          : codigos.length;
      final lote = codigos.sublist(i, fim);
      final placeholders = List.filled(lote.length, '?').join(', ');
      final stmt = await client.prepare(
        'SELECT DISTINCT produto_codigo, gondola_num FROM gondola_layout '
        'WHERE produto_codigo IN ($placeholders)',
      );
      final rows = await stmt.query(positional: lote);
      TursoService().contarLeitura(
        'conferencia_enderecos',
        (rows as List<dynamic>).length,
      );
      for (final dynamic row in rows as List<dynamic>) {
        final r       = row as Map<String, dynamic>;
        final codigo  = r['produto_codigo'] as String? ?? '';
        final gondola = r['gondola_num']    as int?    ?? 0;
        if (codigo.isEmpty) continue;
        mapa.putIfAbsent(codigo, () => <int>{}).add(gondola);
      }
    }
    return mapa;
  }

  Future<Map<String, Set<int>>> _buscarEnderecosEstante(
      LibsqlClient client, List<String> codigos) async {
    final mapa = <String, Set<int>>{};
    for (var i = 0; i < codigos.length; i += _maxCodigosPorConsulta) {
      final fim = (i + _maxCodigosPorConsulta < codigos.length)
          ? i + _maxCodigosPorConsulta
          : codigos.length;
      final lote = codigos.sublist(i, fim);
      final placeholders = List.filled(lote.length, '?').join(', ');
      // Estantes removidas (3/4) ficam fora: produto que só tem endereço
      // antigo cai na lista "sem endereço" e é conferido no braço.
      final stmt = await client.prepare(
        'SELECT DISTINCT produto_codigo, estante_num FROM estante_layout '
        'WHERE produto_codigo IN ($placeholders) '
        'AND estante_num NOT IN (${estantesRemovidas.join(', ')})',
      );
      final rows = await stmt.query(positional: lote);
      TursoService().contarLeitura(
        'conferencia_enderecos',
        (rows as List<dynamic>).length,
      );
      for (final dynamic row in rows as List<dynamic>) {
        final r       = row as Map<String, dynamic>;
        final codigo  = r['produto_codigo'] as String? ?? '';
        final estante = r['estante_num']    as int?    ?? 0;
        if (codigo.isEmpty) continue;
        mapa.putIfAbsent(codigo, () => <int>{}).add(estante);
      }
    }
    return mapa;
  }

  /// Posições do galpão (1–129) que têm rack de cada código.
  ///
  /// Lê galpao_racks — a ocupação, autoridade do galpão — e não o espelho em
  /// estoque_localizado: o espelho é derivado dela (ver GalpaoService) e pode
  /// estar um passo atrás. A ORDEM na pilha não é consultada de propósito: ela
  /// muda quando alguém esvazia um nível abaixo, e o que a cena precisa saber é
  /// qual posição acende.
  Future<Map<String, Set<int>>> _buscarEnderecosGalpao(
      LibsqlClient client, List<String> codigos) async {
    final mapa = <String, Set<int>>{};
    for (var i = 0; i < codigos.length; i += _maxCodigosPorConsulta) {
      final fim = (i + _maxCodigosPorConsulta < codigos.length)
          ? i + _maxCodigosPorConsulta
          : codigos.length;
      final lote = codigos.sublist(i, fim);
      final placeholders = List.filled(lote.length, '?').join(', ');
      final stmt = await client.prepare(
        'SELECT DISTINCT produto_codigo, posicao FROM $sqlProdutosGalpao '
        'WHERE produto_codigo IN ($placeholders)',
      );
      final rows = await stmt.query(positional: lote);
      TursoService().contarLeitura(
        'conferencia_enderecos',
        (rows as List<dynamic>).length,
      );
      for (final dynamic row in rows as List<dynamic>) {
        final r       = row as Map<String, dynamic>;
        final codigo  = r['produto_codigo'] as String? ?? '';
        final posicao = r['posicao']        as int?    ?? 0;
        if (codigo.isEmpty) continue;
        // Linha órfã (posição que saiu da planta) é ignorada, como a cena e o
        // carregarPilhas fazem — badge numa posição inexistente não desenha.
        if (GalpaoConfig.porNumero(posicao) == null) continue;
        mapa.putIfAbsent(codigo, () => <int>{}).add(posicao);
      }
    }
    return mapa;
  }

  Future<Map<String, Set<int>>> _buscarEnderecosBarracao(
      LibsqlClient client, List<String> codigos) async {
    final mapa = <String, Set<int>>{};
    for (var i = 0; i < codigos.length; i += _maxCodigosPorConsulta) {
      final fim = (i + _maxCodigosPorConsulta < codigos.length)
          ? i + _maxCodigosPorConsulta : codigos.length;
      final lote = codigos.sublist(i, fim);
      final placeholders = List.filled(lote.length, '?').join(', ');
      final stmt = await client.prepare(
        // As gaiolas empilhadas também: produto no nível 3 é produto naquele
        // palete, e o palete tem de acender.
        'SELECT DISTINCT produto_codigo, id FROM ('
        'SELECT produto_codigo, id FROM barracao_enderecos UNION ALL '
        'SELECT produto_codigo, endereco_id AS id FROM barracao_gaiolas) '
        'WHERE produto_codigo IN ($placeholders)',
      );
      final rows = await stmt.query(positional: lote);
      TursoService().contarLeitura(
        'conferencia_enderecos',
        (rows as List<dynamic>).length,
      );
      for (final dynamic row in rows as List<dynamic>) {
        final r = row as Map<String, dynamic>;
        final codigo = r['produto_codigo'] as String? ?? '';
        final id = r['id'] as int? ?? 0;
        if (codigo.isEmpty || id <= 0) continue;
        mapa.putIfAbsent(codigo, () => <int>{}).add(id);
      }
    }
    return mapa;
  }
}
