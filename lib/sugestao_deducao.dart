import 'estoque_localizado_service.dart';

/// Uma dedução sugerida para um endereço: de [qtdAnterior] (persistida) para
/// [qtdSugerida], nunca abaixo de 0.
class DeducaoSugerida {
  final EnderecoLocalizado endereco;
  final double qtdAnterior;
  final double qtdSugerida;

  const DeducaoSugerida({
    required this.endereco,
    required this.qtdAnterior,
    required this.qtdSugerida,
  });

  double get deduzido => qtdAnterior - qtdSugerida;
}

/// Resultado de [sugerirDeducao]: as deduções propostas (só endereços que
/// perdem quantidade) e o excesso que não coube em nenhum endereço.
class ResultadoSugestao {
  final List<DeducaoSugerida> deducoes;
  final double restante;

  const ResultadoSugestao({required this.deducoes, required this.restante});
}

/// Sugere de onde saíram [excesso] unidades vendidas, na regra "gôndola
/// primeiro": o cliente pega da gôndola, então o abatimento começa pelas
/// gôndolas e só transborda pra estante se elas não cobrirem o excesso.
/// Dentro de cada grupo, esvazia o slot mais cheio primeiro; empates são
/// resolvidos por (localNum, faceOuColuna, andarOuNivel) pra ordem ser
/// determinística. Nenhum endereço fica negativo — o que não couber volta
/// em [ResultadoSugestao.restante].
ResultadoSugestao? sugerirDeducao({
  required List<EnderecoLocalizado> enderecos,
  required double excesso,
}) {
  if (excesso <= 0 || enderecos.isEmpty) return null;

  final ordenados = List<EnderecoLocalizado>.of(enderecos)
    ..sort((a, b) {
      if (a.ehGondola != b.ehGondola) return a.ehGondola ? -1 : 1;
      final porQtd = b.quantidade.compareTo(a.quantidade);
      if (porQtd != 0) return porQtd;
      final porNum = a.localNum.compareTo(b.localNum);
      if (porNum != 0) return porNum;
      final porFace = a.faceOuColuna.compareTo(b.faceOuColuna);
      if (porFace != 0) return porFace;
      return a.andarOuNivel.compareTo(b.andarOuNivel);
    });

  final deducoes = <DeducaoSugerida>[];
  var restante = excesso;
  for (final e in ordenados) {
    if (restante <= 0) break;
    if (e.quantidade <= 0) continue;
    final tira = restante < e.quantidade ? restante : e.quantidade;
    deducoes.add(DeducaoSugerida(
      endereco:    e,
      qtdAnterior: e.quantidade,
      qtdSugerida: e.quantidade - tira,
    ));
    restante -= tira;
  }

  return ResultadoSugestao(deducoes: deducoes, restante: restante);
}
