import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/loja_scene.dart';
import 'package:gondola_camda/models.dart';
import 'package:gondola_camda/mostruario_scene.dart';

void main() {
  test('número do mostruário não colide com outra estrutura', () {
    expect(mostruarioNum, isNot(balcaoNum));
    expect(mostruarioNum, isNot(ilhaPaletesNum));
    expect(ehPalete(mostruarioNum), isFalse);
    expect(estantesRemovidas.contains(mostruarioNum), isFalse);
    expect(ordemNavegacaoBase.where((n) => n == mostruarioNum).length, 1);
  });

  test('grade: 20 posições, uma coluna no banco', () {
    expect(niveisProdutoPara(mostruarioNum), 20);
    expect(numColunasPara(mostruarioNum), 1);
    expect(MostruarioGeometry.celulas().length, 20);
    for (var i = 0; i < posicoesMostruario; i++) {
      expect(MostruarioGeometry.celulas()[i].nivel, i);
      expect(MostruarioGeometry.celulas()[i].coluna, 0);
    }
  });

  test('endereço é a posição 1–20', () {
    expect(letraEstanteCelula(mostruarioNum, 0, 0), '1');
    expect(letraEstanteCelula(mostruarioNum, 0, 6), '7');
    expect(letraEstanteCelula(mostruarioNum, 0, 19), '20');
    expect(rotuloCurtoEstrutura('estante', mostruarioNum), 'Mostruário');
    expect(nomeEstrutura('estante', mostruarioNum), 'Mostruário');
  });

  test('1–5 na frente (corredor), 16–20 no fundo (parede), esquerda → direita',
      () {
    final p1 = MostruarioGeometry.origemPosicao(0);
    final p2 = MostruarioGeometry.origemPosicao(1);
    final p6 = MostruarioGeometry.origemPosicao(5);
    final p20 = MostruarioGeometry.origemPosicao(19);
    expect(p2.x0, greaterThan(p1.x0));
    expect(p2.z0, p1.z0);
    expect(p6.x0, p1.x0);
    expect(p6.z0, lessThan(p1.z0));
    expect(p1.z0 + MostruarioGeometry.dCelula,
        closeTo(MostruarioGeometry.profundidade, 1e-9));
    expect(p20.z0, closeTo(0, 1e-9));
    expect(p20.x0 + MostruarioGeometry.wCelula,
        closeTo(MostruarioGeometry.largura, 1e-9));
  });

  test('as posições não se sobrepõem e a caixa cabe na célula', () {
    final cs = MostruarioGeometry.celulas();
    for (var i = 0; i < cs.length; i++) {
      for (var j = i + 1; j < cs.length; j++) {
        final sobrepoe = cs[i].xMin < cs[j].xMax - 1e-9 &&
            cs[j].xMin < cs[i].xMax - 1e-9 &&
            cs[i].zMin < cs[j].zMax - 1e-9 &&
            cs[j].zMin < cs[i].zMax - 1e-9;
        expect(sobrepoe, isFalse, reason: 'posições ${i + 1} e ${j + 1}');
      }
    }
    expect(MostruarioGeometry.wCaixa, lessThan(MostruarioGeometry.wCelula));
    expect(MostruarioGeometry.dCaixa, lessThan(MostruarioGeometry.dCelula));
  });

  test('no mapa fica na parede da direita, entre a E1 e a cozinha, sem '
      'encostar em nada', () {
    final m = itensLoja.singleWhere((i) => i.numero == mostruarioNum);
    expect(m.tipo, 'estante');
    // Dentro da loja, encostado (quase) na parede da direita.
    expect(m.x + m.w / 2, lessThan(lojaW));
    expect(lojaW - (m.x + m.w / 2), lessThan(0.3));
    // Depois da Estante 1 e antes do rótulo da cozinha.
    final e1 = itensLoja.singleWhere((i) => i.tipo == 'estante' && i.numero == 1);
    expect(m.z - m.d / 2, greaterThan(e1.z + e1.d / 2));
    final cozinha = referenciasLoja.singleWhere((r) => r.nome == 'COZINHA');
    expect(m.z + m.d / 2, lessThan(cozinha.z));
    // Sem encostar em gôndola.
    for (final g in itensLoja.where((i) => i.tipo == 'gondola')) {
      final dx = math.max(0.0, (g.x - m.x).abs() - m.w / 2);
      final dz = math.max(0.0, (g.z - m.z).abs() - m.d / 2);
      final dist = math.sqrt(dx * dx + dz * dz) - LojaGeometry.gondolaR;
      expect(dist, greaterThan(0.2), reason: 'encosta na gôndola ${g.numero}');
    }
    // A rota do cliente (corredor da direita, x = 8.4) passa pela frente
    // dele sem atravessar.
    expect(m.x - m.w / 2, greaterThan(8.4 + 0.2));
  });

  testWidgets('MostruarioScene renderiza e o toque acha uma posição',
      (tester) async {
    ({int coluna, int nivel})? tocado;
    await tester.pumpWidget(MaterialApp(
      home: MostruarioScene(
        caixas: const [
          CaixaColocadaEstante(produtoId: 'p1', coluna: 0, nivel: 7, slot: 0),
        ],
        corPorProduto: const {'p1': Color(0xFF2c5fb0)},
        onTapCelulaVisualizar: (c, n, _) => tocado = (coluna: c, nivel: n),
      ),
    ));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(MostruarioScene));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tocado, isNotNull);
    expect(tocado!.coluna, 0);
    expect(tocado!.nivel, inInclusiveRange(0, posicoesMostruario - 1));
  });
}
