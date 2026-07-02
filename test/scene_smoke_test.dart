import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/gondola_scene.dart';
import 'package:gondola_camda/loja_scene.dart';
import 'package:gondola_camda/models.dart';

void main() {
  test('faceAngle segue a convenção: face 1 = +90° (entrada), horária', () {
    expect(faceAngle(1), closeTo(math.pi / 2, 1e-9));
    expect(faceAngle(2), closeTo(math.pi / 6, 1e-9));
    expect(faceAngle(4), closeTo(-math.pi / 2, 1e-9));
  });

  test('sectorToFace concorda com faceFromPos no centro de cada setor', () {
    for (var i = 0; i < 6; i++) {
      final a = (30 + i * 60) * math.pi / 180;
      expect(faceFromPos(2 * math.cos(a), 2 * math.sin(a)), sectorToFace(i));
    }
  });

  test('faceFromPos: +Z é a face 1 (entrada), -Z é a face 4 (fundo)', () {
    expect(faceFromPos(0, 3), 1);
    expect(faceFromPos(0, -3), 4);
  });

  test('clampAoAndar traz caixas do octógono antigo para dentro do hexágono', () {
    // Ponto no meio de uma borda do octógono antigo (0.924·r), fora do
    // apótema do hexágono (0.866·r).
    final ang = math.pi / 6;
    final fora = (x: 3.14 * math.cos(ang), z: 3.14 * math.sin(ang));
    final c = GondolaGeometry.clampAoAndar(0, fora.x, fora.z);
    final proj = c.x * math.cos(ang) + c.z * math.sin(ang);
    expect(proj, lessThanOrEqualTo(3.4 * math.cos(math.pi / 6) - 0.2 + 1e-9));
    // A face derivada não muda com o clamp.
    expect(faceFromPos(c.x, c.z), faceFromPos(fora.x, fora.z));
    // Ponto interno permanece intacto.
    final dentro = GondolaGeometry.clampAoAndar(0, 1.0, -1.5);
    expect(dentro.x, 1.0);
    expect(dentro.z, -1.5);
  });

  test('geometria da gôndola é hexagonal (6 pés, prismas de 6 lados)', () {
    final faces = GondolaGeometry.buildFaces();
    // 6 pés + 2 colunas = 8 prismas de coluna; 3 andares × 2 prismas = 6.
    // Cada prisma de 6 lados = 6 laterais + 1 tampa = 7 faces.
    expect(faces.length, (6 + 2 + 6) * 7);
  });

  test('face selecionada recebe tint laranja nos 3 andares', () {
    final semSel = GondolaGeometry.buildFaces();
    final comSel = GondolaGeometry.buildFaces(faceSelecionada: 3);
    final mudadas = <int>[];
    for (var i = 0; i < semSel.length; i++) {
      if (semSel[i].color != comSel[i].color) mudadas.add(i);
    }
    // 1 setor × 2 prismas (corpo + borda) × 3 andares = 6 faces laterais.
    expect(mudadas.length, 6);
  });

  testWidgets('GondolaScene renderiza com face selecionada e labels',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: GondolaScene(
        gondolaAtual: 9,
        faceSelecionada: 3,
        faceParaCamera: 3,
        caixas: [
          CaixaColocada(andar: 0, produtoId: 'p1', x: 2.9, z: 1.6),
          CaixaColocada(andar: 2, produtoId: 'p2', x: 0.2, z: -0.4),
        ],
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('LojaScene renderiza labels de face e referências no chão',
      (tester) async {
    final idxGondola9 =
        itensLoja.indexWhere((it) => it.tipo == 'gondola' && it.numero == 9);
    await tester.pumpWidget(MaterialApp(
      home: LojaScene(
        selecionadoIdx: idxGondola9,
        onSelecionado: (_) {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    // Descarta a cena para encerrar o ticker antes do fim do teste.
    await tester.pumpWidget(const SizedBox());
  });
}
