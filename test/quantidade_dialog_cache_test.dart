import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/quantidade_dialog.dart';
import '../lib/replica_local.dart';
import '../lib/turso_service.dart';

Future<void> abrir(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => mostrarQuantidadeDialog(
              context,
              produtoCodigo: '60801',
              produtoNome: 'Óleo',
              localTipo: 'gondola',
              localNum: 1,
              faceOuColuna: 0,
              andarOuNivel: 0,
            ),
            child: const Text('Abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Abrir'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'mostra quantidades sem conexão e preserva digitação na revisão',
    (tester) async {
      const url = 'libsql://teste-dialogo-cache';
      SharedPreferences.setMockInitialValues({
        TursoService.keyDbUrl: url,
        TursoService.keyCacheLocal: true,
        'consulta_v1_${idBanco(url)}_quantidades_detalhes_v2': jsonEncode([
          {
            'id': 1,
            'produto_codigo': '60801',
            'local_tipo': 'gondola',
            'local_num': 1,
            'face_ou_coluna': 0,
            'andar_ou_nivel': 0,
            'quantidade': 12,
            'atualizado_em': '2026-09-07T12:00:00',
          },
        ]),
      });
      // Sem token e sem cópia do saldo mestre: ele não pode bloquear os campos.
      await abrir(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '12',
      );
      await tester.enterText(find.byType(TextField), '19');
      TursoService().dataRevision.value++;
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '19',
      );
      await tester.pumpWidget(const SizedBox());
      TursoService().dataRevision.value++;
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sem cópia e sem conexão mostra erro e impede gravação', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await abrir(tester);
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    final salvar = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Salvar'),
    );
    expect(salvar.onPressed, isNull);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Concluir contagem'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();
    expect(find.text('Tentar novamente'), findsOneWidget);
  });
}
