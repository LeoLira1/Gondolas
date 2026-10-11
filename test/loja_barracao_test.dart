import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/loja_scene.dart';
import 'package:gondola_camda/models.dart'
    show barracaoMapaNum, localTipoBarracao;

void main() {
  group('barracão no mapa da loja', () {
    final barracao =
        itensLoja.where((it) => it.tipo == localTipoBarracao).toList();

    test('é uma peça só, fora das paredes da loja', () {
      expect(barracao.length, 1);
      final b = barracao.single;
      expect(b.numero, barracaoMapaNum);
      // Inteiro à direita da parede de x = lojaW, sem encostar nela.
      expect(b.x - b.w / 2, greaterThan(lojaW));
    });

    test('qualquer endereço do barracão cai na peça única', () {
      expect(numeroNoMapaLoja(localTipoBarracao, 1), barracaoMapaNum);
      expect(numeroNoMapaLoja(localTipoBarracao, 87), barracaoMapaNum);
      expect(
        itensLoja.indexWhere((it) =>
            it.tipo == localTipoBarracao &&
            it.numero == numeroNoMapaLoja(localTipoBarracao, 42)),
        isNonNegative,
      );
    });

    test('não mexe nos números das outras estruturas', () {
      expect(numeroNoMapaLoja('estante', 1), 1);
      expect(numeroNoMapaLoja('gondola', 7), 7);
    });

    testWidgets('a cena renderiza com o barracão, em conferência também',
        (tester) async {
      final idx = itensLoja.indexWhere((it) => it.tipo == localTipoBarracao);
      for (final conferencia in [false, true]) {
        await tester.pumpWidget(MaterialApp(
          home: LojaScene(
            selecionadoIdx: conferencia ? null : idx,
            modoConferencia: conferencia,
            contagemConferencia: conferencia ? {idx: 3} : const {},
            onSelecionado: (_) {},
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });
  });
}
