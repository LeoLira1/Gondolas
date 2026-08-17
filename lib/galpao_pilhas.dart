import 'galpao_config.dart';
import 'galpao_scene.dart' show RackGalpao;

// ─────────────────────────────────────────────────────────────────────────────
// Operações de pilha do galpão — as duas regras que não podem quebrar
// ─────────────────────────────────────────────────────────────────────────────
//
// 1. Produto novo entra SEMPRE no topo da pilha. Não existe rack flutuando
//    com vazio embaixo — no galpão físico o rack é apoiado sobre o de baixo.
// 2. Esvaziar pode ser em qualquer nível, e a pilha DESCE: os racks acima
//    descem um nível cada e a ordem é renumerada. É o comportamento real do
//    galpão (tira-se o rack e os de cima são reapoiados), e é o motivo de o
//    nível nunca ser gravado como identidade.
//
// As funções são puras (lista nova, nunca mutação) para a página animar a
// transição comparando antes/depois e para a etapa 6 embrulhá-las na
// transação do banco sem reescrever nada.

/// Pilha com um rack novo no topo, ou null se a pilha já está cheia.
List<RackGalpao>? pilhaAposLancar(
  List<RackGalpao> pilha, {
  required int    posicao,
  required String produtoCodigo,
  required String produtoNome,
  required double quantidade,
}) {
  if (pilha.length >= GalpaoConfig.niveisMax) return null;
  return [
    ...pilha,
    RackGalpao(
      posicao:       posicao,
      ordem:         pilha.length + 1,
      produtoCodigo: produtoCodigo,
      produtoNome:   produtoNome,
      quantidade:    quantidade,
    ),
  ];
}

/// Pilha após esvaziar o rack de [ordem]: ele sai e os de cima descem um
/// nível cada, com a ordem renumerada — contínua de 1 a n, sem buraco.
/// Ordem inexistente devolve a pilha como está.
List<RackGalpao> pilhaAposEsvaziar(List<RackGalpao> pilha, int ordem) {
  if (!pilha.any((r) => r.ordem == ordem)) return pilha;
  return [
    for (final r in pilha)
      if (r.ordem < ordem)
        r
      else if (r.ordem > ordem)
        RackGalpao(
          posicao:       r.posicao,
          ordem:         r.ordem - 1,
          produtoCodigo: r.produtoCodigo,
          produtoNome:   r.produtoNome,
          quantidade:    r.quantidade,
        ),
  ];
}
