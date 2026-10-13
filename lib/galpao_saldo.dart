import 'codigos_vinculados.dart';

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
//
// Os dois lados da conta estão em UNIDADE (ver unidades.dart) e somam TODOS os
// códigos do mesmo produto (ver codigos_vinculados.dart) — as duas coisas que
// faziam o galpão discordar do app do scanner.

/// Saldo de um produto entre o sistema e os endereços físicos.
class SaldoProduto {
  final String codigo;

  /// estoque_mestre.qtd_sistema — o que o ERP diz que existe, em unidades,
  /// somando todos os códigos do produto.
  final double qtdSistema;

  /// Soma de estoque_localizado.quantidade do produto, em TODOS os locais e
  /// em todos os códigos do produto.
  final double enderecado;

  /// Os códigos que entraram nas duas somas, em ordem. Vazio ou com um item
  /// só = o produto tem código único; mais de um é o que a tela mostra para
  /// explicar um número maior que o da linha do código lido.
  final List<String> codigosSomados;

  const SaldoProduto({
    required this.codigo,
    required this.qtdSistema,
    required this.enderecado,
    this.codigosSomados = const [],
  });

  /// Folga para não pintar o galpão inteiro por causa de arredondamento de
  /// ponto flutuante (as quantidades são double e passam por somas de várias
  /// linhas de estoque_localizado).
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

  /// True quando o saldo somou mais de um código — o que a tarja explicita.
  bool get temCodigosSomados => codigosSomados.length > 1;

  /// O mesmo saldo com [delta] a mais (ou a menos) de endereçado.
  ///
  /// É o que deixa a cor do rack responder no ato do lançamento: a tela grava
  /// otimista e só depois relê o saldo do banco, e sem isso o cubo recém-posto
  /// continuaria vermelho até a releitura chegar.
  SaldoProduto comDelta(double delta) => SaldoProduto(
        codigo:         codigo,
        qtdSistema:     qtdSistema,
        enderecado:     enderecado + delta,
        codigosSomados: codigosSomados,
      );

  @override
  bool operator ==(Object other) =>
      other is SaldoProduto &&
      other.codigo == codigo &&
      other.qtdSistema == qtdSistema &&
      other.enderecado == enderecado &&
      other.codigosSomados.join(',') == codigosSomados.join(',');

  @override
  int get hashCode =>
      Object.hash(codigo, qtdSistema, enderecado, codigosSomados.join(','));
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

/// Monta o saldo de cada código a partir das leituras cruas do banco, somando
/// os códigos irmãos de cada produto ([gruposDeCodigos]).
///
/// [sistemaPorCodigo] é o `qtd_sistema` do estoque_mestre e
/// [enderecadoPorCodigo] a soma de estoque_localizado, ambos por código
/// (linhas que o banco devolveu, nem todo código está nos dois). Produto sem
/// NENHUMA linha em estoque_mestre fica de fora do mapa: sem qtd_sistema não
/// dá para dizer se falta ou sobra, e chutar zero pintaria de azul todo rack
/// de produto fora do cadastro.
///
/// A CHAVE do mapa é o código como ele veio em [codigos] — o mesmo texto que
/// está em galpao_racks.produto_codigo, porque é por ele que a cena procura a
/// cor do cubo. A normalização vale só para cruzar as somas.
Map<String, SaldoProduto> montarSaldos({
  required Iterable<String> codigos,
  required Map<String, Set<String>> grupos,
  required Map<String, double> sistemaPorCodigo,
  required Map<String, double> enderecadoPorCodigo,
}) {
  final saldos = <String, SaldoProduto>{};
  for (final bruto in codigos) {
    final codigo = normalizarCodigo(bruto);
    if (codigo == null || saldos.containsKey(bruto)) continue;

    final grupo = (grupos[codigo] ?? {codigo}).toList()..sort();
    if (!grupo.any(sistemaPorCodigo.containsKey)) continue;

    var sistema = 0.0, enderecado = 0.0;
    for (final c in grupo) {
      sistema    += sistemaPorCodigo[c]    ?? 0;
      enderecado += enderecadoPorCodigo[c] ?? 0;
    }
    saldos[bruto] = SaldoProduto(
      codigo:         bruto,
      qtdSistema:     sistema,
      enderecado:     enderecado,
      codigosSomados: grupo,
    );
  }
  return saldos;
}
