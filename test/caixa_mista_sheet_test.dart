import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/caixa_mista_sheet.dart';
import 'package:gondola_camda/galpao_saldo.dart';
import 'package:gondola_camda/models.dart';

const _catalogo = [
  Produto(codigo: '90101', nome: 'BICO LECHLER LU 110-02', categoria: 'PEÇAS', corHex: '#95a5a6'),
  Produto(codigo: '90110', nome: 'REGISTRO ESFERA 3/4', categoria: 'PEÇAS', corHex: '#95a5a6'),
];

ItemCaixaVista _item(String codigo, {double? qtd, SaldoProduto? saldo}) =>
    ItemCaixaVista(
      codigo: codigo,
      nome: 'NOME $codigo',
      corCategoria: Colors.grey,
      qtdAqui: qtd,
      saldo: saldo,
    );

void main() {
  late ValueNotifier<CaixaMistaVista?> vista;
  late List<String> chamadas;

  setUp(() {
    chamadas = [];
    vista = ValueNotifier(CaixaMistaVista(
      endereco: 'E13·4 · slot 2',
      nome: 'Peças Hoppner',
      itens: [
        _item('90105', qtd: 6,
            saldo: const SaldoProduto(codigo: '90105', qtdSistema: 4, enderecado: 6)),
        _item('90108', qtd: 20,
            saldo: const SaldoProduto(codigo: '90108', qtdSistema: 26, enderecado: 20)),
        _item('90109'),
      ],
    ));
  });

  Future<void> abrir(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => mostrarCaixaMistaSheet(
                context,
                vista: vista,
                filtrar: (q) => _catalogo
                    .where((p) => p.nome.contains(q.toUpperCase()) ||
                        p.codigo.contains(q))
                    .toList(),
                onAdicionar: (p) async => chamadas.add('add:${p.codigo}'),
                onTirar: (c) async => chamadas.add('tirar:$c'),
                onQuantidade: (c) async => chamadas.add('qtd:$c'),
                onNome: (n) async => chamadas.add('nome:$n'),
                onRemoverCaixa: () async => chamadas.add('remover'),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('mostra endereço, contador, saldo e o selo +N', (tester) async {
    await abrir(tester);
    expect(find.textContaining('E13·4 · slot 2'), findsOneWidget);
    expect(find.textContaining('3/5 produtos'), findsOneWidget);
    expect(find.textContaining('26 un'), findsOneWidget); // 6 + 20
    expect(find.text('+3'), findsOneWidget);
    expect(find.textContaining('faltam 6'), findsOneWidget);
    expect(find.textContaining('+2 além do sistema'), findsOneWidget);
    expect(find.text('sem saldo no sistema'), findsOneWidget);
    // Nunca contado nesta posição: traço, não zero.
    expect(find.text('—'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('busca adiciona, quantidade e lixeira chamam a página',
      (tester) async {
    await abrir(tester);
    await tester.enterText(find.byKey(const Key('caixa_mista_busca')), 'REGISTRO');
    await tester.pump();
    await tester.tap(find.text('REGISTRO ESFERA 3/4'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('caixa_mista_qtd_90108')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('caixa_mista_tirar_90109')));
    await tester.pump();
    expect(chamadas, ['add:90110', 'qtd:90108', 'tirar:90109']);
  });

  testWidgets('caixa cheia trava a busca', (tester) async {
    vista.value = CaixaMistaVista(
      endereco: 'E13·4 · slot 2',
      nome: null,
      itens: [for (final c in ['1', '2', '3', '4', '5']) _item(c)],
    );
    await abrir(tester);
    final campo = tester.widget<TextField>(
        find.byKey(const Key('caixa_mista_busca')));
    expect(campo.enabled, isFalse);
    expect(find.textContaining('Caixa cheia (5/5)'), findsOneWidget);
  });

  testWidgets('remover a caixa pede um segundo toque', (tester) async {
    await abrir(tester);
    await tester.tap(find.byKey(const Key('caixa_mista_remover')));
    await tester.pump();
    expect(chamadas, isEmpty);
    expect(find.text('Toque de novo p/ remover'), findsOneWidget);
    await tester.tap(find.byKey(const Key('caixa_mista_remover')));
    await tester.pump();
    expect(chamadas, ['remover']);
  });

  testWidgets('o nome grava ao concluir, e a caixa que some fecha a folha',
      (tester) async {
    await abrir(tester);
    await tester.enterText(
        find.byKey(const Key('caixa_mista_nome')), 'Peças do pulverizador');
    await tester.tap(find.byKey(const Key('caixa_mista_concluir')));
    await tester.pumpAndSettle();
    expect(chamadas, ['nome:Peças do pulverizador']);
    expect(find.byType(CaixaMistaSheet), findsNothing);

    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.byType(CaixaMistaSheet), findsOneWidget);
    vista.value = null;
    await tester.pumpAndSettle();
    expect(find.byType(CaixaMistaSheet), findsNothing);
  });
}
