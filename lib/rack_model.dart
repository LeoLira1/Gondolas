/// Um produto dentro de um rack do galpão.
///
/// O rack misto (até [GalpaoConfig.produtosMaxPorRack] produtos no mesmo
/// palete) guarda o PRIMEIRO produto na própria linha de `galpao_racks` — o
/// principal — e os demais em `galpao_rack_itens`. [itemUuid] null é o
/// principal; os outros são achados pelo UUID do item, nunca pela posição na
/// lista.
class ProdutoNoRack {
  final String? itemUuid;
  final String produtoCodigo;
  final String produtoNome;
  final double quantidade;

  const ProdutoNoRack({
    this.itemUuid,
    required this.produtoCodigo,
    this.produtoNome = '',
    this.quantidade = 0,
  });

  bool get principal => itemUuid == null;

  ProdutoNoRack comQuantidade(double nova) => ProdutoNoRack(
    itemUuid: itemUuid,
    produtoCodigo: produtoCodigo,
    produtoNome: produtoNome,
    quantidade: nova,
  );
}

/// Um rack ocupado numa posição do galpão.
///
/// [ordem] é a posição do rack DENTRO da pilha (1 = o de baixo) e é o que a
/// tela mostra como nível. Não é identidade: esvaziar um rack faz os de cima
/// descerem, e a ordem de todos eles muda. Ver a discussão em
/// galpao_config.dart.
class RackGalpao {
  final String? rackUuid;
  final int posicao; // 1–138
  final int ordem; // 1–GalpaoConfig.niveisMax
  final String produtoCodigo;
  final String produtoNome;
  final double quantidade;

  /// Os produtos ALÉM do principal, num rack misto. Vazio no rack comum.
  final List<ProdutoNoRack> itens;

  const RackGalpao({
    this.rackUuid,
    required this.posicao,
    required this.ordem,
    required this.produtoCodigo,
    this.produtoNome = '',
    this.quantidade = 0,
    this.itens = const [],
  });

  bool get misto => itens.isNotEmpty;

  /// Todos os produtos do rack, o principal primeiro.
  List<ProdutoNoRack> get produtos => [
    ProdutoNoRack(
      produtoCodigo: produtoCodigo,
      produtoNome: produtoNome,
      quantidade: quantidade,
    ),
    ...itens,
  ];

  bool contem(String codigo) =>
      produtoCodigo == codigo || itens.any((i) => i.produtoCodigo == codigo);

  RackGalpao copiar({
    int? ordem,
    String? produtoCodigo,
    String? produtoNome,
    double? quantidade,
    List<ProdutoNoRack>? itens,
  }) => RackGalpao(
    rackUuid: rackUuid,
    posicao: posicao,
    ordem: ordem ?? this.ordem,
    produtoCodigo: produtoCodigo ?? this.produtoCodigo,
    produtoNome: produtoNome ?? this.produtoNome,
    quantidade: quantidade ?? this.quantidade,
    itens: itens ?? this.itens,
  );
}
