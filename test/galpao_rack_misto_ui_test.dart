import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_page.dart';
import 'package:gondola_camda/galpao_scene.dart';
import 'package:gondola_camda/models.dart' show Produto;

const _rack = RackGalpao(
  rackUuid: 'r1',
  posicao: 8,
  ordem: 1,
  produtoCodigo: 'P1',
  produtoNome: 'HERBICIDA BROWSER 5L',
  quantidade: 14,
);

const _misto = RackGalpao(
  rackUuid: 'r1',
  posicao: 8,
  ordem: 1,
  produtoCodigo: 'P1',
  produtoNome: 'HERBICIDA BROWSER 5L',
  quantidade: 14,
  itens: [
    ProdutoNoRack(
      itemUuid: 'i1',
      produtoCodigo: 'P2',
      produtoNome: 'ADJUVANTE 1L',
      quantidade: 6,
    ),
  ],
);

const _catalogo = [
  Produto(codigo: 'P1', nome: 'HERBICIDA BROWSER 5L', categoria: 'h', corHex: '#336699'),
  Produto(codigo: 'P2', nome: 'ADJUVANTE 1L', categoria: 'a', corHex: '#336699'),
  Produto(codigo: 'P3', nome: 'ADUBO FOLIAR 1L', categoria: 'a', corHex: '#336699'),
  Produto(codigo: 'EST:9', nome: 'ADUBO DO ZÉ', categoria: 'e', corHex: '#336699'),
];

Widget _montar(
  RackGalpao rack, {
  void Function(Produto, double)? onAdicionar,
  void Function(ProdutoNoRack, double)? onAjustarProduto,
  void Function(ProdutoNoRack)? onRemover,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: PainelEnderecoGalpao(
        toque: const ToqueGalpao(posicao: 8, ordem: 1, ocupado: true),
        pilhas: {8: [rack]},
        catalogo: _catalogo,
        onFechar: () {},
        onEsvaziar: () {},
        onAjustarQuantidade: (_) {},
        onAdicionarProduto: onAdicionar,
        onAjustarProduto: onAjustarProduto,
        onRemoverProduto: onRemover,
      ),
    ),
  ),
);

final _campoBusca = find.widgetWithText(
  TextField,
  'Buscar produto por nome ou código…',
);
final _campoQuantidade = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == 'Unidades',
);

void main() {
  testWidgets('rack comum oferece adicionar outro produto (1/5)', (
    tester,
  ) async {
    await tester.pumpWidget(_montar(_rack, onAdicionar: (_, __) {}));
    expect(find.text('Adicionar outro produto neste rack (1/5)'), findsOneWidget);
  });

  testWidgets('sem callback (barracão) não há botão de adicionar', (
    tester,
  ) async {
    await tester.pumpWidget(_montar(_rack));
    expect(find.textContaining('Adicionar outro produto'), findsNothing);
  });

  testWidgets('adicionar: busca sem os que já estão no rack nem estocado', (
    tester,
  ) async {
    Produto? adicionado;
    double? quantidade;
    await tester.pumpWidget(
      _montar(
        _misto,
        onAdicionar: (p, q) {
          adicionado = p;
          quantidade = q;
        },
      ),
    );
    await tester.tap(find.textContaining('Adicionar outro produto'));
    await tester.pumpAndSettle();

    await tester.enterText(_campoBusca, 'ad');
    await tester.pumpAndSettle();
    expect(find.text('ADUBO FOLIAR 1L'), findsOneWidget);
    // Já está no rack, e estocado não se mistura com a loja.
    expect(find.text('ADJUVANTE 1L'), findsNothing);
    expect(find.text('ADUBO DO ZÉ'), findsNothing);

    await tester.tap(find.text('ADUBO FOLIAR 1L'));
    await tester.pumpAndSettle();
    await tester.enterText(_campoQuantidade, '3');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adicionar em 8 · N1'));
    await tester.pumpAndSettle();

    expect(adicionado?.codigo, 'P3');
    expect(quantidade, 3);
  });

  testWidgets('rack misto lista cada produto com a sua quantidade', (
    tester,
  ) async {
    await tester.pumpWidget(
      _montar(_misto, onAjustarProduto: (_, __) {}, onRemover: (_) {}),
    );
    expect(find.text('RACK MISTO · 2 produtos'), findsOneWidget);
    expect(find.text('HERBICIDA BROWSER 5L'), findsOneWidget);
    expect(find.text('ADJUVANTE 1L'), findsOneWidget);
    expect(find.text('14 unidades'), findsOneWidget);
    expect(find.text('6 unidades'), findsOneWidget);
  });

  testWidgets('0 num produto do rack misto tira só ele', (tester) async {
    ProdutoNoRack? removido;
    await tester.pumpWidget(
      _montar(
        _misto,
        onAjustarProduto: (_, __) {},
        onRemover: (p) => removido = p,
      ),
    );
    await tester.tap(find.text('6 unidades'));
    await tester.pumpAndSettle();
    expect(find.text('Quantidade em 8 · N1'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '0',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Os outros continuam no palete'), findsOneWidget);
    await tester.tap(find.text('Tirar'));
    await tester.pumpAndSettle();
    expect(removido?.itemUuid, 'i1');
  });

  testWidgets('corrigir um produto do rack misto devolve o item e o número', (
    tester,
  ) async {
    ProdutoNoRack? ajustado;
    double? nova;
    await tester.pumpWidget(
      _montar(
        _misto,
        onAjustarProduto: (p, q) {
          ajustado = p;
          nova = q;
        },
        onRemover: (_) {},
      ),
    );
    await tester.tap(find.text('6 unidades'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '8',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(ajustado?.produtoCodigo, 'P2');
    expect(nova, 8);
  });
}
