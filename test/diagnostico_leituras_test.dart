import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/diagnostico_leituras_page.dart';
import 'package:gondola_camda/leituras_turso.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Um "agora" fixo: o "Hoje" e os dias guardados não dependem do relógio.
DateTime _agora() => DateTime(2026, 10, 15, 12);

/// Um contador novo lendo o disco simulado (o do app é um só por processo).
ContadorDeLeituras _contador() => ContadorDeLeituras(
  carregarDisco: () async =>
      (await SharedPreferences.getInstance()).getString('leituras_turso_v1'),
  gravarDisco: (t) async =>
      (await SharedPreferences.getInstance()).setString('leituras_turso_v1', t),
  agora: _agora,
);

Widget _pagina() => MaterialApp(
  home: DiagnosticoLeiturasPage(contador: _contador(), agora: _agora),
);

void main() {
  testWidgets('mostra o dia com a estimativa das linhas varridas', (
    tester,
  ) async {
    const hoje = '2026-10-15';
    SharedPreferences.setMockInitialValues({
      'leituras_turso_v1': jsonEncode({
        hoje: {
          'quantidades_detalhes_v2': [2, 8000],
          'ultima_contagem_ciclico_v1': [3, 900],
          'galpao': [10, 300],
        },
        '2026-10-09': {
          'galpao': [1, 30],
        },
      }),
      'tamanho_tabelas_v1': jsonEncode({
        'em': '2026-10-15T09:00:00',
        // estoque_localizado é de uma versão que media mais tabelas.
        'tabelas': {'inventario_cicli': 10000, 'estoque_localizado': 4000},
      }),
    });

    await tester.pumpWidget(_pagina());
    await tester.pumpAndSettle();

    // 8000 + 3 × 10000 (agrupa o inventário cíclico inteiro) + 300.
    expect(find.text('≈ 38.300 linhas lidas'), findsOneWidget);
    expect(find.text('15 consultas · 9.200 linhas devolvidas'), findsOneWidget);
    expect(find.text('Hoje'), findsOneWidget);
    expect(find.text('Inventário cíclico'), findsOneWidget);
    expect(find.text('30.000'), findsOneWidget);
    expect(find.text('Quantidades (estoque_localizado inteiro)'), findsOneWidget);
    expect(find.text('10.000'), findsOneWidget); // tamanho medido
    expect(find.text('4.000'), findsNothing); // não conta mais
    expect(
      find.text('3 consultas · varre a tabela inventario_cicli'),
      findsOneWidget,
    );

    // O dia antigo continua guardado.
    await tester.tap(find.text('09/10'));
    await tester.pumpAndSettle();
    expect(find.text('≈ 30 linhas lidas'), findsOneWidget);
  });

  testWidgets('sem medida das tabelas, avisa que o real é maior', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'leituras_turso_v1': jsonEncode({
        '2026-10-15': {
          'ultima_contagem_itens_confirmado_em': [2, 500],
        },
      }),
    });
    await tester.pumpWidget(_pagina());
    await tester.pumpAndSettle();
    expect(find.text('≈ 500 linhas lidas'), findsOneWidget);
    expect(find.textContaining('o real é maior'), findsOneWidget);
    expect(find.text('Tamanho das tabelas: ainda não medido'), findsOneWidget);
  });

  testWidgets('zerar pergunta antes de apagar', (tester) async {
    SharedPreferences.setMockInitialValues({
      'leituras_turso_v1': jsonEncode({
        '2026-10-15': {
          'galpao': [4, 120],
        },
      }),
    });
    await tester.pumpWidget(_pagina());
    await tester.pumpAndSettle();
    expect(find.text('≈ 120 linhas lidas'), findsOneWidget);

    await tester.tap(find.byTooltip('Zerar a contagem'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('≈ 120 linhas lidas'), findsOneWidget);

    await tester.tap(find.byTooltip('Zerar a contagem'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zerar'));
    await tester.pumpAndSettle();
    expect(find.text('Nenhuma leitura contada ainda.'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('leituras_turso_v1'),
      '{}',
    );
  });
}
