import 'package:libsql_dart/libsql_dart.dart';
import 'galpao_config.dart';
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
  });

  static const vazio = ModoConferenciaResultado(
    estruturas: {},
    galpao: {},
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
}) {
  final estruturas    = <String, List<ItemPendente>>{};
  final posicoes      = <int, List<ItemPendente>>{};
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
      if (noGalpao.isEmpty) filtradosDeposito++;
      continue;
    }

    totalLoja++;
    if (!temEnderecoNaLoja) {
      // "Sem endereço" é sem endereço NENHUM: com rack no galpão o item já
      // tem para onde mandar quem vai conferir.
      if (noGalpao.isEmpty) semEndereco.add(item);
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

  /// Busca os pendentes de contagem_itens e cruza com gondola_layout,
  /// estante_layout e galpao_racks numa única passada — 4 queries no total (ou
  /// poucas mais, se o lote de códigos precisar ser quebrado), nunca uma por
  /// estrutura.
  ///
  /// As três consultas recebem TODOS os códigos pendentes: o filtro de
  /// categorias de depósito não é mais aplicado antes de perguntar ao banco,
  /// porque é o próprio endereço que decide se ele vale (ver a nota no topo do
  /// arquivo). O cruzamento em si é de [montarConferencia].
  Future<ModoConferenciaResultado> buscarConferenciaDoDia() async {
    final client = await _conexao();
    if (client == null) return ModoConferenciaResultado.vazio;

    try {
      final pendentes = await _buscarPendentes(client);
      if (pendentes.isEmpty) return ModoConferenciaResultado.vazio;

      final codigosTodos = pendentes.map((p) => p.codigo).toList();

      final resultados = await Future.wait([
        _buscarEnderecosGondola(client, codigosTodos),
        _buscarEnderecosEstante(client, codigosTodos),
        _buscarEnderecosGalpao(client, codigosTodos),
      ]);

      return montarConferencia(
        pendentes:         pendentes,
        gondolasPorCodigo: resultados[0],
        estantesPorCodigo: resultados[1],
        galpaoPorCodigo:   resultados[2],
      );
    } catch (_) {
      return ModoConferenciaResultado.vazio;
    }
  }

  Future<List<ItemPendente>> _buscarPendentes(LibsqlClient client) async {
    final stmt = await client.prepare(
      "SELECT codigo, produto, categoria, qtd_estoque FROM contagem_itens "
      "WHERE status = 'pendente'",
    );
    final rows = await stmt.query();
    return (rows as List<dynamic>).map((dynamic row) {
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
        'SELECT DISTINCT produto_codigo, posicao FROM galpao_racks '
        'WHERE produto_codigo IN ($placeholders)',
      );
      final rows = await stmt.query(positional: lote);
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
}
