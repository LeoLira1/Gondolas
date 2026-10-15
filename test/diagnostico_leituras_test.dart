import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/diagnostico_leituras_page.dart';
import 'package:gondola_camda/leituras_turso.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Um contador novo lendo o disco simulado (o do app é um só por processo).
ContadorDeLeituras _contador() => ContadorDeLeituras(
  carregarDisco: () async =>
      (await SharedPreferences.getInstance()).getString('leituras_turso_v1'),
  gravarDisco: (t) async =>
      (await SharedPreferences.getInstance()).setString('leituras_turso_v1', t),
);

void main() {
  testWidgets('mostra o dia com a estimativa das linhas varridas', (
    tester,
  ) async {
    final hoje = ContadorDeLeituras.diaDe(DateTime.now());
    SharedPreferences.setMockInitialValues({
      'leituras_turso_v1': jsonEncode({
        hoje: {
          'quantidades_detalhes_v2': [2, 8000],
          'ultima_contagem_ciclico_v1': [3, 900],
          'galpao': [10, 300],
        },
        '2026-01-01': {
          'galpao': [1, 30],
        },
      }),
      'tamanho_tabelas_v1': jsonEncode({
        'em': '2026-10-15T09:00:00',
        'tabelas': {'inventario_cicli': 10000, 'estoque_localizado': 4000},
      }),
    });

    await tester.pumpWidget(
      MaterialApp(home: DiagnosticoLeiturasPage(contador: _contador())),
    );
    await tester.pumpAndSettle();

    // 8000 + 3 × 10000 (agrupa o inventário cíclico inteiro) + 300.
    expect(find.text('≈ 38.300 linhas lidas'), findsOneWidget);
    expect(find.text('15 consultas · 9.200 linhas devolvidas'), findsOneWidget);
    expect(find.text('Hoje'), findsOneWidget);
    expect(find.text('Inventário cíclico'), findsOneWidget);
    expect(find.text('30.000'), findsOneWidget);
    expect(find.text('Quantidades (estoque_localizado inteiro)'), findsOneWidget);
    expect(find.text('10.000'), findsOneWidget); // tamanho medido

    // O dia antigo continua guardado.
    await tester.tap(find.text('01/01'));
    await tester.pumpAndSettle();
    expect(find.text('≈ 30 linhas lidas'), findsOneWidget);
  });

  testWidgets('sem medida das tabelas, avisa que o real é maior', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'leituras_turso_v1': jsonEncode({
        ContadorDeLeituras.diaDe(DateTime.now()): {
          'ultima_contagem_itens_confirmado_em': [2, 500],
        },
      }),
    });
    await tester.pumpWidget(
      MaterialApp(home: DiagnosticoLeiturasPage(contador: _contador())),
    );
    await tester.pumpAndSettle();
    expect(find.text('≈ 500 linhas lidas'), findsOneWidget);
    expect(find.textContaining('o real é maior'), findsOneWidget);
    expect(find.text('Tamanho das tabelas: ainda não medido'), findsOneWidget);
  });
}
