import 'barracao_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Busca de paletes dentro do barracão
// ─────────────────────────────────────────────────────────────────────────────
//
// Diferente da busca do painel (que procura no CATÁLOGO o que lançar), esta
// procura nos PALETES o que já está no chão: responde "onde está o produto X?".
// Lê só a lista em memória da página — são ~100 endereços — então não há ida ao
// banco por tecla digitada.
//
// Mesma regra de termos da busca do galpão e da loja: cada palavra da consulta
// (separada por espaço) precisa aparecer no nome OU no código, em qualquer
// ordem ('boral 20' acha 'HERBICIDA BORAL 500 SC 20L'). O rótulo também vale,
// para quem digita 'BAR-07' e quer ver o que há lá.

/// Paletes ocupados que casam com [query], em ordem de nome e depois de rótulo,
/// no máximo [max]. Consulta com menos de 2 caracteres úteis devolve vazio.
List<EnderecoBarracao> buscarPaletesBarracao(
  String query,
  List<EnderecoBarracao> enderecos, {
  int max = 8,
}) {
  final limpa = query.trim().toLowerCase();
  if (limpa.length < 2) return const [];
  final termos = limpa.split(RegExp(r'\s+'));

  final achados = [
    for (final e in enderecos)
      if (e.ocupado && _casa(e, termos)) e,
  ]..sort((a, b) {
      final n = a.produtoNome.compareTo(b.produtoNome);
      return n != 0 ? n : a.rotulo.compareTo(b.rotulo);
    });
  return achados.length > max ? achados.sublist(0, max) : achados;
}

bool _casa(EnderecoBarracao e, List<String> termos) {
  final nome   = e.produtoNome.toLowerCase();
  final codigo = e.produtoCodigo.toLowerCase();
  final rotulo = e.rotulo.toLowerCase();
  return termos.every(
      (t) => nome.contains(t) || codigo.contains(t) || rotulo.contains(t));
}
