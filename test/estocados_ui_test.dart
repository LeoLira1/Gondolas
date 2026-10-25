import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/estocados_sheet.dart';
import 'package:gondola_camda/galpao_page.dart';
import 'package:gondola_camda/galpao_scene.dart';

void main() {
  Widget painel(RackGalpao rack, {VoidCallback? onEsvaziar}) => MaterialApp(
        home: Scaffold(
          body: PainelEnderecoGalpao(
            toque: const ToqueGalpao(posicao: 40, ordem: 1, ocupado: true),
            pilhas: {40: [rack]},
            onFechar: () {},
            onEsvaziar: onEsvaziar,
          ),
        ),
      );

  group('Retirar do endereço', () {
    const estocado = RackGalpao(
      posicao: 40, ordem: 1, produtoCodigo: 'EST:254185',
      produtoNome: 'BORAL 20L · JOÃO', quantidade: 10,
    );
    const loja = RackGalpao(
      posicao: 40, ordem: 1, produtoCodigo: '254185',
      produtoNome: 'BORAL 20L', quantidade: 10,
    );

    testWidgets('aparece só no palete de estocado', (tester) async {
      await tester.pumpWidget(painel(estocado, onEsvaziar: () {}));
      expect(find.text('Retirar do endereço'), findsOneWidget);

      await tester.pumpWidget(painel(loja, onEsvaziar: () {}));
      expect(find.text('Retirar do endereço'), findsNothing);
    });

    testWidgets('pede confirmação e só então esvazia', (tester) async {
      var esvaziou = 0;
      await tester.pumpWidget(painel(estocado, onEsvaziar: () => esvaziou++));

      await tester.tap(find.text('Retirar do endereço'));
      await tester.pumpAndSettle();
      expect(find.text('Retirar 40 · N1?'), findsOneWidget);
      expect(esvaziou, 0);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(esvaziou, 0);

      await tester.tap(find.text('Retirar do endereço'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retirar'));
      await tester.pumpAndSettle();
      expect(esvaziou, 1);
    });
  });

  testWidgets('botão de estocados cabe na barra do galpão em tela estreita',
      (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
        home: GalpaoPage(catalogoInicial: [], pilhasIniciais: {})));
    await tester.pump();

    expect(find.byType(BotaoEstocados), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Cabeçalho novo: só livres quando não há racks.
    expect(find.text('552 livres'), findsOneWidget);
  });
}
