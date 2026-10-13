import 'galpao_config.dart';
import 'gravacao_lote.dart';
import 'rack_model.dart';

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
///
/// [rackUuid] é a identidade que o rack terá no banco — a tela já a conhece
/// porque é ela que a sorteia (ver OperacaoPendente.uuid), e é com ela que um
/// ajuste feito logo em seguida, antes de o lançamento chegar ao servidor,
/// acha o rack certo.
List<RackGalpao>? pilhaAposLancar(
  List<RackGalpao> pilha, {
  required int posicao,
  required String produtoCodigo,
  required String produtoNome,
  required double quantidade,
  String? rackUuid,
}) {
  if (pilha.length >= GalpaoConfig.niveisMax) return null;
  return [
    ...pilha,
    RackGalpao(
      rackUuid: rackUuid,
      posicao: posicao,
      ordem: pilha.length + 1,
      produtoCodigo: produtoCodigo,
      produtoNome: produtoNome,
      quantidade: quantidade,
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
          rackUuid: r.rackUuid,
          posicao: r.posicao,
          ordem: r.ordem - 1,
          produtoCodigo: r.produtoCodigo,
          produtoNome: r.produtoNome,
          quantidade: r.quantidade,
        ),
  ];
}

/// Pilha com a quantidade do rack de [ordem] trocada por [quantidade] — o
/// resto (produto, nível, ordem dos outros racks) fica exatamente como estava.
///
/// É a correção de contagem: o palete está lá, o produto é o certo, só o
/// número é que estava errado. Antes disso a única saída era esvaziar e lançar
/// de novo, o que derrubava a pilha inteira em cima (regra 2) e trocava um
/// erro de digitação por uma remontagem.
///
/// Ordem inexistente ou quantidade não positiva devolve a pilha como está —
/// zerar é [pilhaAposEsvaziar], que é outra operação (o rack SAI e os de cima
/// descem).
List<RackGalpao> pilhaAposAjustar(
  List<RackGalpao> pilha,
  int ordem,
  double quantidade,
) {
  if (quantidade <= 0) return pilha;
  if (!pilha.any((r) => r.ordem == ordem)) return pilha;
  return [
    for (final r in pilha)
      if (r.ordem != ordem)
        r
      else
        RackGalpao(
          rackUuid: r.rackUuid,
          posicao: r.posicao,
          ordem: r.ordem,
          produtoCodigo: r.produtoCodigo,
          produtoNome: r.produtoNome,
          quantidade: quantidade,
        ),
  ];
}

/// O galpão como a pessoa o vê: o que veio do banco com as gravações ainda na
/// fila aplicadas por cima, na ordem em que foram feitas.
///
/// É o que deixa a tela recarregar do banco a qualquer momento — sincronização
/// de outro aparelho, volta do app, fim da fila — sem um rack lançado offline
/// sumir até a rede deixar enviá-lo. Cada operação é aplicada pelo rack que
/// ela nomeia (o UUID), nunca pelo nível: o nível do banco pode já ser outro.
///
/// Operação que já está no banco não é aplicada duas vezes: o lançamento cujo
/// rack já veio na leitura é pulado, e ajuste/esvaziamento são absolutos (o
/// rack ausente simplesmente não é tocado).
Map<int, List<RackGalpao>> aplicarPendentesGalpao(
  Map<int, List<RackGalpao>> pilhas,
  Iterable<OperacaoPendente> pendentes,
) {
  final resultado = {
    for (final e in pilhas.entries) e.key: List<RackGalpao>.of(e.value),
  };
  for (final op in pendentes) {
    if (!op.tipo.doGalpao) continue;
    final pilha = resultado[op.local] ?? const <RackGalpao>[];
    switch (op.tipo) {
      case TipoOperacao.galpaoLancar:
        if (pilha.any((r) => r.rackUuid == op.uuid)) continue;
        final nova = pilhaAposLancar(
          pilha,
          posicao: op.local,
          produtoCodigo: op.produtoCodigo,
          produtoNome: op.produtoNome,
          quantidade: op.quantidade,
          rackUuid: op.uuid,
        );
        if (nova != null) resultado[op.local] = nova;
      case TipoOperacao.galpaoAjustar:
        final i = pilha.indexWhere((r) => r.rackUuid == op.rackUuid);
        if (i < 0) continue;
        resultado[op.local] = pilhaAposAjustar(
          pilha,
          pilha[i].ordem,
          op.quantidade,
        );
      case TipoOperacao.galpaoEsvaziar:
        final i = pilha.indexWhere((r) => r.rackUuid == op.rackUuid);
        if (i < 0) continue;
        final nova = pilhaAposEsvaziar(pilha, pilha[i].ordem);
        if (nova.isEmpty) {
          resultado.remove(op.local);
        } else {
          resultado[op.local] = nova;
        }
      default:
        continue;
    }
  }
  return resultado;
}
