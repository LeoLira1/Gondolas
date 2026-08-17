import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_config.dart';
import 'package:gondola_camda/galpao_page.dart';
import 'package:gondola_camda/galpao_scene.dart';
import 'package:gondola_camda/gondola_scene.dart'
    show Camera, ProjecaoCamera, Vec3;

void main() {
  group('PainelEnderecoGalpao', () {
    Widget montar(ToqueGalpao toque, Map<int, List<RackGalpao>> pilhas) =>
        MaterialApp(
          home: Scaffold(
            body: PainelEnderecoGalpao(
              toque:    toque,
              pilhas:   pilhas,
              onFechar: () {},
            ),
          ),
        );

    testWidgets('endereço ocupado: produto e quantidade em baldes',
        (tester) async {
      await tester.pumpWidget(montar(
        const ToqueGalpao(posicao: 52, ordem: 2, ocupado: true),
        {
          52: const [
            RackGalpao(
                posicao: 52, ordem: 1, produtoCodigo: 'X',
                produtoNome: 'ADUBO 20L', quantidade: 400),
            RackGalpao(
                posicao: 52, ordem: 2, produtoCodigo: 'BORAL',
                produtoNome: 'HERBICIDA BORAL 500 SC 20L', quantidade: 1800),
          ],
        },
      ));

      expect(find.text('52 · N2'), findsOneWidget);
      expect(find.text('Rua 5 · 2 de 4 na pilha'), findsOneWidget);
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
      expect(find.text('90 baldes'), findsOneWidget);
      expect(find.text('1800 L'), findsOneWidget);
    });

    testWidgets('produto sem litragem no nome mostra o número cru',
        (tester) async {
      await tester.pumpWidget(montar(
        const ToqueGalpao(posicao: 10, ordem: 1, ocupado: true),
        {
          10: const [
            RackGalpao(
                posicao: 10, ordem: 1, produtoCodigo: 'LUVA001',
                produtoNome: 'LUVA NITRILICA PAR', quantidade: 35),
          ],
        },
      ));

      expect(find.text('35'), findsOneWidget);
      // Sem conversão não há texto secundário de litros.
      expect(find.text('35 L'), findsNothing);
    });

    testWidgets('vaga livre anuncia em qual nível a carga entraria',
        (tester) async {
      await tester.pumpWidget(montar(
        const ToqueGalpao(posicao: 37, ordem: 3, ocupado: false),
        {},
      ));

      expect(find.text('37 · N3'), findsOneWidget);
      expect(
        find.textContaining('carga nova entra como N3'),
        findsOneWidget,
      );
    });
  });

  group('GalpaoPage', () {
    testWidgets('tocar numa vaga abre o painel; fechar o painel o remove',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: GalpaoPage()));

      // Centro da vaga N1 da posição 1, pela mesma câmera de enquadramento
      // da cena (a página abre com o galpão todo vazio).
      final tela = tester.getSize(find.byType(GalpaoScene));
      final camera = GalpaoScene.enquadrar(tela);
      final p = GalpaoConfig.porNumero(1)!;
      final y = (GalpaoConfig.yBase(1) + GalpaoConfig.yTopo(1)) / 2;
      final ponto = _projetar(camera, tela, Vec3(p.x, y, p.z))!;

      await tester.tapAt(ponto);
      await tester.pump();

      expect(find.text('1 · N1'), findsOneWidget);
      expect(find.textContaining('carga nova entra como N1'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text('1 · N1'), findsNothing);
    });
  });
}

Offset? _projetar(Camera camera, Size size, Vec3 v) {
  final olho   = camera.position;
  final fwd    = (camera.target - olho).normalized;
  final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
  final up     = right.cross(fwd).normalized;
  final tanH   = math.tan(ProjecaoCamera.fovY / 2);
  final aspect = size.width / size.height;

  final d  = v - olho;
  final cz = d.dot(fwd);
  if (cz <= ProjecaoCamera.near) return null;
  final cx = d.dot(right) / (cz * tanH * aspect);
  final cy = d.dot(up) / (cz * tanH);
  return Offset((cx + 1) / 2 * size.width, (1 - cy) / 2 * size.height);
}
