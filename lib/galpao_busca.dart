import 'models.dart' show Produto;

// ─────────────────────────────────────────────────────────────────────────────
// Busca de produto para lançar no galpão
// ─────────────────────────────────────────────────────────────────────────────
//
// Diferente do autocomplete das outras telas (um termo, contains simples),
// aqui a busca aceita DOIS termos soltos cruzados ('boral 20') — e continua
// casando qualquer parte do nome, nunca só o começo: os nomes cadastrados têm
// a categoria na frente e a concentração/embalagem no fim, então a parte que
// a pessoa lembra quase nunca é o início ('boral' tem de achar 'HERBICIDA
// BORAL 500 SC 20L'). Código do produto também vale.

/// Produtos do catálogo que casam com [query], no máximo [max].
///
/// Cada termo da consulta (separado por espaço) precisa aparecer em alguma
/// parte do nome OU do código — termos independentes, cada um pode casar num
/// campo diferente. Consulta com menos de 2 caracteres úteis devolve vazio
/// (convenção das outras telas: 1 letra casa com o catálogo inteiro).
List<Produto> buscarProdutosGalpao(
  String query,
  List<Produto> catalogo, {
  int max = 4,
}) {
  final limpa = query.trim().toLowerCase();
  if (limpa.length < 2) return const [];
  final termos = limpa.split(RegExp(r'\s+'));

  final achados = <Produto>[];
  for (final p in catalogo) {
    final nome   = p.nome.toLowerCase();
    final codigo = p.codigo.toLowerCase();
    if (termos.every((t) => nome.contains(t) || codigo.contains(t))) {
      achados.add(p);
      if (achados.length >= max) break;
    }
  }
  return achados;
}
