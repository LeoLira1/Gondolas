// ─────────────────────────────────────────────────────────────────────────────
// Produtos estocados (material de cooperado guardado na CAMDA)
// ─────────────────────────────────────────────────────────────────────────────
//
// A lista vem de `materiais_terceiros`, a mesma tabela que o app Estocados lê.
// Esse material já foi faturado e saiu do sistema: NADA daqui entra em
// `estoque_localizado`, no saldo ou na baixa pela contagem.

import 'models.dart' show Produto;

/// Prefixo do código de um palete de estocado em `galpao_racks` /
/// `barracao_enderecos`. É o que o distingue do estoque da loja: os serviços
/// NÃO espelham esses paletes em `estoque_localizado` (então não entram no
/// saldo, na baixa pela contagem nem no Modo Conferência), e o código não casa
/// com nenhuma linha de `estoque_mestre`.
const prefixoEstocado = 'EST:';

bool codigoEhEstocado(String codigo) => codigo.startsWith(prefixoEstocado);

/// Chave do destaque da busca (o laranja que acende os paletes do produto).
///
/// Da loja, é o código: todos os paletes do herbicida acendem juntos. De
/// estocado, o código sozinho não serve — dois cooperados com o mesmo produto
/// gravam o mesmo `EST:49000`, e buscar o ZAPP do João acendia também o da
/// Maria. Por isso entra o nome do palete, que traz o cooperado
/// (ver [nomeDoPalete]).
String chaveDestaque(String codigo, String nome) =>
    codigoEhEstocado(codigo) ? '$codigo|$nome' : codigo;

/// Uma linha de `materiais_terceiros` com saldo a entregar.
class ItemEstocado {
  final String cooperado;
  final String produto;
  final String codigo;
  final String armazem;
  final String documento;
  final String emissao;
  final double saldo;

  /// Quantas linhas do banco foram somadas neste item (1 = nenhuma).
  final int lancamentos;

  const ItemEstocado({
    this.lancamentos = 1,
    required this.cooperado,
    required this.produto,
    required this.codigo,
    required this.armazem,
    required this.documento,
    required this.emissao,
    required this.saldo,
  });

  /// Lê a linha tolerando os mesmos sinônimos de coluna do app Estocados.
  factory ItemEstocado.deLinha(Map<String, dynamic> linha) {
    final l = {
      for (final e in linha.entries) e.key.toLowerCase(): e.value,
    };
    String texto(List<String> nomes) {
      for (final n in nomes) {
        final v = l[n]?.toString() ?? '';
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    return ItemEstocado(
      cooperado: texto(['razao_social', 'cooperado', 'cliente']),
      produto: texto(['descricao', 'produto', 'descricao_produto']),
      codigo: texto(
        ['codigo', 'cod', 'codigo_produto', 'cod_produto', 'produto_codigo'],
      ),
      armazem: texto(['armazem', 'arm', 'cod_armazem', 'codigo_armazem']),
      documento: texto(
        ['documento', 'doc', 'num_doc', 'numero_documento', 'nota', 'num_nota'],
      ),
      emissao: texto(
        ['emissao', 'data_emissao', 'dt_emissao', 'data', 'data_entrada'],
      ),
      saldo: double.tryParse(texto(['saldo']).replaceAll(',', '.')) ?? 0,
    );
  }
}

/// Soma os itens iguais (mesmo cooperado, produto, código e armazém) numa
/// linha só, somando o saldo. Documentos diferentes viram `N docs` no lugar do
/// número. A ordem da primeira ocorrência é mantida.
List<ItemEstocado> somarEstocados(Iterable<ItemEstocado> itens) {
  final grupos = <String, List<ItemEstocado>>{};
  for (final i in itens) {
    final chave = _normalizar(
      '${i.cooperado}|${i.produto}|${i.codigo}|${i.armazem}',
    ).replaceAll(RegExp(r'\s+'), ' ');
    grupos.putIfAbsent(chave, () => []).add(i);
  }
  return [
    for (final g in grupos.values)
      if (g.length == 1)
        g.first
      else
        ItemEstocado(
          cooperado: g.first.cooperado,
          produto: g.first.produto,
          codigo: g.first.codigo,
          armazem: g.first.armazem,
          documento: '',
          emissao: g.first.emissao,
          saldo: g.fold<double>(0, (s, i) => s + i.saldo),
          lancamentos: g.length,
        ),
  ];
}

const _acentos = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
  'ç': 'c',
};

String _normalizar(String s) {
  final b = StringBuffer();
  for (final c in s.toLowerCase().split('')) {
    b.write(_acentos[c] ?? c);
  }
  return b.toString();
}

/// Itens que casam com [query]. Cada termo (separado por espaço) precisa
/// aparecer no cooperado, no produto OU no código — então 'joao boral' acha o
/// Boral do João. Sem acento e sem maiúscula. Consulta vazia devolve tudo.
List<ItemEstocado> buscarEstocados(String query, List<ItemEstocado> itens) {
  final termos = _normalizar(query.trim())
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (termos.isEmpty) return itens;
  return itens.where((i) {
    final alvo = _normalizar('${i.cooperado} ${i.produto} ${i.codigo}');
    return termos.every(alvo.contains);
  }).toList();
}

/// O item como "produto" lançável num palete: código com [prefixoEstocado] e
/// o cooperado no nome, para aparecer no mapa e na busca do painel do
/// endereço (`'ADUBO FOLIAR 5L · MARIA SOUZA'`). Cor própria (violeta), para
/// o estocado não se confundir com nenhuma categoria da loja.
Produto produtoDeEstocado(ItemEstocado i) => Produto(
      codigo: '$prefixoEstocado${i.codigo.isEmpty ? i.produto : i.codigo}',
      nome: nomeDoPalete(i),
      categoria: 'ESTOCADO',
      corHex: '#8B5CF6',
    );

/// Nome gravado no palete (`produto_nome`) para um item: o mesmo texto de
/// [produtoDeEstocado]. É a chave que liga o palete ao item da lista — o
/// código sozinho não serve, porque dois cooperados podem ter o mesmo produto.
String nomeDoPalete(ItemEstocado i) => '${i.produto} · ${i.cooperado}';

/// Endereços por nome de palete, só dos paletes de estocado.
///
/// [galpao] recebe (posição, ordem, código, nome) e [barracao] (rótulo, código,
/// nome) — o mínimo que as duas tabelas têm em comum, para a regra ser pura.
Map<String, List<String>> enderecosDosEstocados({
  required Iterable<({int posicao, int ordem, String codigo, String nome})>
      galpao,
  required Iterable<({String rotulo, String codigo, String nome})> barracao,
}) {
  final mapa = <String, List<String>>{};
  for (final r in galpao) {
    if (!codigoEhEstocado(r.codigo)) continue;
    mapa
        .putIfAbsent(r.nome, () => [])
        .add('Galpão ${r.posicao} · N${r.ordem}');
  }
  for (final e in barracao) {
    if (!codigoEhEstocado(e.codigo)) continue;
    mapa.putIfAbsent(e.nome, () => []).add(e.rotulo);
  }
  return mapa;
}

/// Texto do cabeçalho do galpão: vagas livres e quanto do ocupado é estocado
/// (cooperado) e quanto é da loja. Parte zerada some — `38 livres · 30
/// estocados` quando não há nada da loja — para a linha caber na barra.
///
/// [codigos] são os códigos de TODOS os racks ocupados.
String resumoOcupacao({required int totalVagas, required Iterable<String> codigos}) {
  var estocados = 0;
  var loja = 0;
  for (final c in codigos) {
    if (codigoEhEstocado(c)) {
      estocados++;
    } else {
      loja++;
    }
  }
  final livres = totalVagas - estocados - loja;
  return [
    '$livres livres',
    if (estocados > 0) '$estocados estocados',
    if (loja > 0) '$loja loja',
  ].join(' · ');
}
