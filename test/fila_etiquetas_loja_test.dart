import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/fila_etiquetas_loja.dart';
import 'package:gondola_camda/fila_etiquetas_tab.dart';

void main() {
  test('montarFilaEtiquetas: impressos (recentes) e depois pendentes', () {
    final itens = montarFilaEtiquetas([
      {
        'id': 'p2',
        'codigo': '43184',
        'nome': 'CATRACAO CORDOALHA',
        'pares': 1,
        'status': 'pendente',
        'criado_em': '2026-11-02 17:10:00',
      },
      {
        'id': 'i1',
        'codigo': ' 219487 ',
        'nome': 'MASCARA PFF1 C/ VALVULA',
        'pares': 2,
        'status': 'impresso',
        'criado_em': '2026-11-02 08:00:00',
        'impresso_em': '2026-11-02 09:15:00',
      },
      {
        'id': 'i2',
        'codigo': '271210',
        'nome': 'ISOLADOR CASTANHA 900KGF',
        'pares': null,
        'status': 'impresso',
        'criado_em': '2026-11-02 08:00:00',
        'impresso_em': '2026-11-02 17:37:00',
      },
      {
        'id': 'p1',
        'codigo': '106615',
        'nome': 'ISOLADOR PARAF. ISOFENCE',
        'status': 'pendente',
        'criado_em': '2026-11-02 07:00:00',
        'impresso_em': '',
      },
    ]);
    expect(itens.map((i) => i.id), ['i2', 'i1', 'p1', 'p2']);
    expect(itens[1].codigo, '219487');
    expect(itens[1].pares, 2);
    expect(itens[0].pares, 1);
    expect(itens[0].hora, '17:37');
    expect(itens[2].impressoEm, isNull);
    expect(itens[2].hora, '07:00');
  });

  test('hojeBrt usa UTC-3', () {
    expect(hojeBrt(DateTime.utc(2026, 11, 3, 2, 30)), '2026-11-02');
    expect(hojeBrt(DateTime.utc(2026, 11, 3, 3, 0)), '2026-11-03');
  });

  test('marcasValidas descarta ids que saíram da fila', () {
    const itens = [ItemFilaEtiqueta(id: 'a', codigo: '1', nome: 'X')];
    expect(marcasValidas({'a', 'velho'}, itens), {'a'});
  });

  const itens = [
    ItemFilaEtiqueta(
        id: 'i1',
        codigo: '219487',
        nome: 'MASCARA PFF1 C/ VALVULA',
        impresso: true,
        impressoEm: '2026-11-02 17:37:00'),
    ItemFilaEtiqueta(
        id: 'p1',
        codigo: '43184',
        nome: 'CATRACAO CORDOALHA',
        criadoEm: '2026-11-02 17:10:00'),
  ];

  testWidgets('seções, ✓ grava a marca e o toque abre o onde está',
      (t) async {
    Set<String>? gravado;
    var abriu = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilaEtiquetasTab(
          buscar: () async => itens,
          lerColocadas: () async => {'sumiu'},
          gravarColocadas: (s) async => gravado = {...s},
          abrirEndereco: (_, __) async => abriu++,
        ),
      ),
    ));
    await t.pumpAndSettle();
    // A marca velha foi limpa ao carregar.
    expect(gravado, <String>{});
    expect(find.text('1 impressas hoje · 0/1 colocadas · 1 pendente(s)'),
        findsOneWidget);
    expect(find.text('IMPRESSAS HOJE'), findsOneWidget);
    expect(find.text('PENDENTES (AINDA NÃO IMPRESSAS)'), findsOneWidget);
    expect(find.text(' onde está'), findsNWidgets(2));
    // Pendente não tem ✓.
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);

    await t.tap(find.byIcon(Icons.radio_button_unchecked));
    await t.pump();
    expect(gravado, {'i1'});
    expect(find.text('1 impressas hoje · 1/1 colocadas · 1 pendente(s)'),
        findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(abriu, 0);

    await t.enterText(find.byType(TextField), 'catracao');
    await t.pump();
    expect(find.text('MASCARA PFF1 C/ VALVULA'), findsNothing);
    expect(find.text('CATRACAO CORDOALHA'), findsOneWidget);
  });
}
