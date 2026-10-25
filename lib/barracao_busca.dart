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

/// Uma gaiola achada pela busca: o endereço e o nível dela na pilha.
class ResultadoBuscaBarracao {
  final EnderecoBarracao endereco;
  final int nivel;
  final String produtoCodigo;
  final String produtoNome;
  final double quantidade;

  const ResultadoBuscaBarracao({
    required this.endereco,
    required this.nivel,
    required this.produtoCodigo,
    required this.produtoNome,
    required this.quantidade,
  });

  int get id => endereco.id;

  /// 'BAR-07' para a gaiola do chão, 'BAR-07 · N3' para uma empilhada.
  String get rotulo =>
      nivel > 1 ? '${endereco.rotulo} · N$nivel' : endereco.rotulo;
}

/// Gaiolas que casam com [query] — uma linha por GAIOLA, porque a mesma pilha
/// pode levar o produto em mais de um nível —, em ordem de nome, rótulo e
/// nível, no máximo [max]. Consulta com menos de 2 caracteres úteis devolve
/// vazio.
List<ResultadoBuscaBarracao> buscarPaletesBarracao(
  String query,
  List<EnderecoBarracao> enderecos, {
  int max = 8,
}) {
  final limpa = query.trim().toLowerCase();
  if (limpa.length < 2) return const [];
  final termos = limpa.split(RegExp(r'\s+'));

  final achados = [
    for (final e in enderecos)
      for (final g in e.gaiolas)
        if (_casa(e.rotulo, g.codigo, g.nome, termos))
          ResultadoBuscaBarracao(
            endereco:      e,
            nivel:         g.nivel,
            produtoCodigo: g.codigo,
            produtoNome:   g.nome,
            quantidade:    g.quantidade,
          ),
  ]..sort((a, b) {
      final n = a.produtoNome.compareTo(b.produtoNome);
      if (n != 0) return n;
      final r = a.endereco.rotulo.compareTo(b.endereco.rotulo);
      return r != 0 ? r : a.nivel.compareTo(b.nivel);
    });
  return achados.length > max ? achados.sublist(0, max) : achados;
}

bool _casa(String rotulo, String codigo, String nome, List<String> termos) {
  final n = nome.toLowerCase();
  final c = codigo.toLowerCase();
  final r = rotulo.toLowerCase();
  return termos.every((t) => n.contains(t) || c.contains(t) || r.contains(t));
}
