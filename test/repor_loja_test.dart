import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/repor_loja.dart';
import 'package:gondola_camda/repor_loja_tab.dart';

void main() {
  test('montarReporLoja lê as colunas da consulta', () {
    final itens = montarReporLoja([
      {
        'codigo': ' 196320 ',
        'produto': 'BOTA PVC BRACOL CANO MEDIO PRETA',
        'categoria': 'EPI',
        'qtd_vendida': 4,
        'qtd_estoque': 25.0,
        'criado_em': '2026-10-24 05:33:49',
      },
      {'codigo': '1', 'produto': 'X', 'qtd_vendida': null, 'criado_em': null},
    ]);
    expect(itens.first.codigo, '196320');
    expect(itens.first.repor, 4);
    expect(itens.first.saldoSistema, 25);
    expect(itens.first.idade(DateTime(2026, 10, 29, 21)), '5d atrás');
    expect(itens.last.repor, 0);
    expect(itens.last.idade(DateTime(2026, 10, 29)), '');
  });

  test('categorias excluídas iguais às do camda-estoque', () {
    expect(categoriasExcluidasReposicao, contains('HERBICIDAS'));
    expect(categoriasExcluidasReposicao, contains('RATICIDAS'));
    expect(categoriasExcluidasReposicao, hasLength(32));
  });

  final itens = [
    ItemReporLoja(
        codigo: '196320',
        produto: 'BOTA PVC BRACOL CANO MEDIO PRETA',
        categoria: 'EPI',
        repor: 4,
        saldoSistema: 25,
        pendenteDesde: DateTime(2026, 10, 24)),
    const ItemReporLoja(
        codigo: '221090',
        produto: 'OLEO LUB TEXACO HIDRAULICO HD 68 4L',
        categoria: 'LUBRIFICANTES',
        repor: 2,
        saldoSistema: 7),
  ];

  testWidgets('lista, total e filtro', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: ReporLojaTab(buscar: () async => itens)),
    ));
    await t.pumpAndSettle();
    expect(find.text('2 produtos · 6 unidades a repor'), findsOneWidget);
    expect(find.text('BOTA PVC BRACOL CANO MEDIO PRETA'), findsOneWidget);

    await t.enterText(find.byType(TextField), 'lubrif');
    await t.pump();
    expect(find.text('BOTA PVC BRACOL CANO MEDIO PRETA'), findsNothing);
    expect(find.text('OLEO LUB TEXACO HIDRAULICO HD 68 4L'), findsOneWidget);
  });

  testWidgets('com abrirEndereco, cada produto mostra o "onde está"',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReporLojaTab(
          buscar: () async => itens,
          abrirEndereco: (_, __) async {},
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text(' onde está'), findsNWidgets(2));
  });
}
