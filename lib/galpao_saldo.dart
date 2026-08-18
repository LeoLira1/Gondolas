// ─────────────────────────────────────────────────────────────────────────────
// Saldo por produto: o que o sistema tem × o que já está endereçado
// ─────────────────────────────────────────────────────────────────────────────
//
// O galpão é onde a carga chega e vai sendo distribuída em paletes. A pergunta
// de quem está com o rack na mão é sempre a mesma: "o sistema diz 145 — quanto
// disso eu já coloquei em algum endereço?". Este arquivo é a resposta em forma
// de dado, sem tela e sem banco, para poder ser conferida em teste.
//
// O que entra na conta é a MESMA soma que [EstoqueLocalizadoService.
// concluirContagem] usa para fechar o inventário cíclico: todos os endereços do
// produto em estoque_localizado (galpão + gôndolas + estantes) contra
// estoque_mestre.qtd_sistema. Contar só os racks do galpão daria falta falsa em
// todo produto que também está na loja.

/// Saldo de um produto entre o sistema e os endereços físicos.
class SaldoProduto {
  final String codigo;

  /// estoque_mestre.qtd_sistema — o que o ERP diz que existe.
  final double qtdSistema;

  /// Soma de estoque_localizado.quantidade do produto, em TODOS os locais.
  final double enderecado;

  const SaldoProduto({
    required this.codigo,
    required this.qtdSistema,
    required this.enderecado,
  });

  /// Folga para não pintar o galpão inteiro por causa de arredondamento de
  /// ponto flutuante (as quantidades são double e passam por divisões por 20
  /// na conversão de baldes/caixas).
  static const double tolerancia = 0.001;

  /// Endereçado − sistema: negativo falta endereçar, positivo sobra.
  double get diferenca => enderecado - qtdSistema;

  /// Ainda há carga do sistema sem endereço — o rack fica VERMELHO.
  bool get falta => diferenca < -tolerancia;

  /// Há mais endereçado do que o sistema registra — o rack fica AZUL.
  bool get sobra => diferenca > tolerancia;

  /// Bate com o sistema: o rack mantém a cor da categoria do produto.
  bool get fecha => !falta && !sobra;

  /// Quanto falta endereçar (0 quando não falta).
  double get quantoFalta => falta ? -diferenca : 0;

  /// Quanto sobra endereçado (0 quando não sobra).
  double get quantoSobra => sobra ? diferenca : 0;

  /// O mesmo saldo com [delta] a mais (ou a menos) de endereçado.
  ///
  /// É o que deixa a cor do rack responder no ato do lançamento: a tela grava
  /// otimista e só depois relê o saldo do banco, e sem isso o cubo recém-posto
  /// continuaria vermelho até a releitura chegar.
  SaldoProduto comDelta(double delta) => SaldoProduto(
        codigo:     codigo,
        qtdSistema: qtdSistema,
        enderecado: enderecado + delta,
      );

  @override
  bool operator ==(Object other) =>
      other is SaldoProduto &&
      other.codigo == codigo &&
      other.qtdSistema == qtdSistema &&
      other.enderecado == enderecado;

  @override
  int get hashCode => Object.hash(codigo, qtdSistema, enderecado);
}

/// Mapa de saldos com [delta] aplicado ao produto [codigo].
///
/// Devolve um mapa NOVO de propósito: o painter da cena decide o repaint por
/// identidade do mapa (`identical`), então mutar o de dentro não repintaria.
/// Produto que ainda não está no mapa (primeiro rack de um produto que nunca
/// teve endereço) fica de fora — sem qtd_sistema não há saldo a mostrar, e a
/// releitura do banco logo em seguida traz a linha completa.
Map<String, SaldoProduto> saldosComDelta(
  Map<String, SaldoProduto> saldos, {
  required String codigo,
  required double delta,
}) {
  final atual = saldos[codigo];
  if (atual == null) return saldos;
  return {...saldos, codigo: atual.comDelta(delta)};
}

/// Quantos produtos do galpão estão com falta e quantos com sobra — o resumo
/// da faixa de saldo, calculado sobre os códigos que realmente têm rack.
({int comFalta, int comSobra}) resumoSaldos(
  Map<String, SaldoProduto> saldos,
  Iterable<String> codigosComRack,
) {
  var comFalta = 0, comSobra = 0;
  for (final codigo in codigosComRack.toSet()) {
    final saldo = saldos[codigo];
    if (saldo == null) continue;
    if (saldo.falta) comFalta++;
    if (saldo.sobra) comSobra++;
  }
  return (comFalta: comFalta, comSobra: comSobra);
}
