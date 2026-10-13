import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/estante_scene.dart';
import 'package:gondola_camda/models.dart';

void main() {
  group('EstanteGeometry.celulasPara memoizada', () {
    test('devolve a mesma instância para a mesma estante', () {
      // É o ponto da memoização: build/_hitTest/_drawLabels chamam isto o tempo
      // todo e cada chamada realocava a grade inteira.
      expect(
        identical(
            EstanteGeometry.celulasPara(1), EstanteGeometry.celulasPara(1)),
        isTrue,
      );
    });

    test('estantes diferentes têm grades diferentes', () {
      expect(
        identical(
            EstanteGeometry.celulasPara(1), EstanteGeometry.celulasPara(19)),
        isFalse,
      );
    });

    test('a grade tem colunas × níveis de produto da estante', () {
      for (final estante in [1, 2, 19, 20]) {
        final celulas = EstanteGeometry.celulasPara(estante);
        expect(celulas.length,
            EstanteGeometry.numColunas * niveisProdutoPara(estante),
            reason: 'estante $estante');
        // Cada par (coluna, nível) aparece uma vez só — é o que o índice
        // montado no build assume.
        final chaves = celulas.map((c) => (c.coluna, c.nivel)).toSet();
        expect(chaves.length, celulas.length, reason: 'estante $estante');
      }
    });

    test('a grade em cache é imutável', () {
      // Compartilhada entre todos os chamadores: mutar corromperia as cenas.
      final celulas = EstanteGeometry.celulasPara(1);
      expect(() => celulas.add(celulas.first), throwsUnsupportedError);
    });
  });

  group('EstanteScene com layout fora da grade', () {
    testWidgets('caixa em endereço inexistente não derruba a cena',
        (tester) async {
      // Antes era um firstWhere sem orElse: uma linha antiga apontando para um
      // nível que a estante não tem mais estourava no build.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EstanteScene(
            estanteAtual: 1,
            caixas: const [
              CaixaColocadaEstante(
                  coluna: 0, nivel: 99, slot: 0, produtoId: 'FANTASMA'),
              CaixaColocadaEstante(
                  coluna: 0, nivel: 0, slot: 0, produtoId: 'REAL'),
            ],
            corPorProduto: const {'REAL': Color(0xFF2e7d4f)},
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.byType(EstanteScene), findsOneWidget);
    });
  });
}
