/// Um rack ocupado numa posição do galpão.
///
/// [ordem] é a posição do rack DENTRO da pilha (1 = o de baixo) e é o que a
/// tela mostra como nível. Não é identidade: esvaziar um rack faz os de cima
/// descerem, e a ordem de todos eles muda. Ver a discussão em
/// galpao_config.dart.
class RackGalpao {
  final String? rackUuid;
  final int posicao; // 1–129
  final int ordem; // 1–GalpaoConfig.niveisMax
  final String produtoCodigo;
  final String produtoNome;
  final double quantidade;

  const RackGalpao({
    this.rackUuid,
    required this.posicao,
    required this.ordem,
    required this.produtoCodigo,
    this.produtoNome = '',
    this.quantidade = 0,
  });
}
