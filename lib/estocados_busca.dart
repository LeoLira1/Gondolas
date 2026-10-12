// ─────────────────────────────────────────────────────────────────────────────
// Produtos estocados (material de cooperado guardado na CAMDA)
// ─────────────────────────────────────────────────────────────────────────────
//
// A lista vem de `materiais_terceiros`, a mesma tabela que o app Estocados lê.
// Esse material já foi faturado e saiu do sistema: NADA daqui entra em
// `estoque_localizado`, no saldo ou na baixa pela contagem. É só consulta.

/// Uma linha de `materiais_terceiros` com saldo a entregar.
class ItemEstocado {
  final String cooperado;
  final String produto;
  final String codigo;
  final String armazem;
  final String documento;
  final String emissao;
  final double saldo;

  const ItemEstocado({
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
