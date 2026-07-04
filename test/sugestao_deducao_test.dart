import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/estoque_localizado_service.dart';
import 'package:gondola_camda/sugestao_deducao.dart';

EnderecoLocalizado gondola(int num, double qtd,
        {int face = 1, int andar = 0}) =>
    EnderecoLocalizado(
      produtoCodigo: 'P1',
      localTipo:     'gondola',
      localNum:      num,
      faceOuColuna:  face,
      andarOuNivel:  andar,
      quantidade:    qtd,
    );

EnderecoLocalizado estante(int num, double qtd,
        {int coluna = 1, int nivel = 0}) =>
    EnderecoLocalizado(
      produtoCodigo: 'P1',
      localTipo:     'estante',
      localNum:      num,
      faceOuColuna:  coluna,
      andarOuNivel:  nivel,
      quantidade:    qtd,
    );

void main() {
  test('excesso <= 0 ou lista vazia não gera sugestão', () {
    expect(sugerirDeducao(enderecos: [gondola(1, 5)], excesso: 0), isNull);
    expect(sugerirDeducao(enderecos: [gondola(1, 5)], excesso: -2), isNull);
    expect(sugerirDeducao(enderecos: [], excesso: 3), isNull);
  });

  test('uma gôndola cobre todo o excesso', () {
    final r = sugerirDeducao(
      enderecos: [gondola(9, 10), estante(3, 4)],
      excesso:   2,
    )!;
    expect(r.restante, 0);
    expect(r.deducoes, hasLength(1));
    expect(r.deducoes.single.endereco.localNum, 9);
    expect(r.deducoes.single.qtdSugerida, 8);
    expect(r.deducoes.single.deduzido, 2);
  });

  test('gôndola é esvaziada antes de transbordar pra estante', () {
    final r = sugerirDeducao(
      enderecos: [estante(3, 10), gondola(9, 4)],
      excesso:   6,
    )!;
    expect(r.restante, 0);
    expect(r.deducoes, hasLength(2));
    expect(r.deducoes[0].endereco.ehGondola, isTrue);
    expect(r.deducoes[0].qtdSugerida, 0); // gôndola 4 → 0
    expect(r.deducoes[1].endereco.ehGondola, isFalse);
    expect(r.deducoes[1].qtdSugerida, 8); // estante 10 → 8
  });

  test('entre gôndolas, a de maior quantidade sai primeiro', () {
    final r = sugerirDeducao(
      enderecos: [gondola(1, 3), gondola(2, 7)],
      excesso:   2,
    )!;
    expect(r.deducoes.single.endereco.localNum, 2);
    expect(r.deducoes.single.qtdSugerida, 5);
  });

  test('quantidades iguais desempatam pelo menor localNum', () {
    final r = sugerirDeducao(
      enderecos: [gondola(5, 4), gondola(2, 4)],
      excesso:   1,
    )!;
    expect(r.deducoes.single.endereco.localNum, 2);
  });

  test('excesso maior que o total zera tudo e reporta restante', () {
    final r = sugerirDeducao(
      enderecos: [gondola(1, 3), estante(2, 2)],
      excesso:   9,
    )!;
    expect(r.deducoes, hasLength(2));
    expect(r.deducoes.every((d) => d.qtdSugerida == 0), isTrue);
    expect(r.restante, 4);
  });

  test('endereço com quantidade 0 não entra na sugestão', () {
    final r = sugerirDeducao(
      enderecos: [gondola(1, 0), estante(2, 5)],
      excesso:   3,
    )!;
    expect(r.deducoes, hasLength(1));
    expect(r.deducoes.single.endereco.localNum, 2);
    expect(r.deducoes.single.qtdSugerida, 2);
  });

  test('funciona com quantidades fracionadas', () {
    final r = sugerirDeducao(
      enderecos: [gondola(1, 2.5)],
      excesso:   1.5,
    )!;
    expect(r.restante, 0);
    expect(r.deducoes.single.qtdSugerida, 1.0);
    expect(r.deducoes.single.deduzido, 1.5);
  });
}
