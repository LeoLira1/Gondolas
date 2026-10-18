import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/ilha_paletes_scene.dart';
import 'package:gondola_camda/loja_scene.dart';
import 'package:gondola_camda/models.dart';

void main() {
  test('número da ilha não colide com estante, expositor, balcão nem palete', () {
    expect(ilhaPaletesNum, isNot(balcaoNum));
    expect(ehPalete(ilhaPaletesNum), isFalse);
    expect(estantesRemovidas.contains(ilhaPaletesNum), isFalse);
    expect(ordemNavegacaoBase.where((n) => n == ilhaPaletesNum).length, 1);
  });

  test('grade: 12 espaços × 5 produtos', () {
    expect(niveisProdutoPara(ilhaPaletesNum), 12);
    expect(numColunasPara(ilhaPaletesNum), 5);
    expect(IlhaPaletesGeometry.celulas().length, 60);
  });

  test('endereço é espaço-produto', () {
    expect(letraEstanteCelula(ilhaPaletesNum, 0, 0), '1-1');
    expect(letraEstanteCelula(ilhaPaletesNum, 4, 0), '1-5');
    expect(letraEstanteCelula(ilhaPaletesNum, 1, 2), '3-2');
    expect(letraEstanteCelula(ilhaPaletesNum, 4, 11), '12-5');
    expect(rotuloCurtoEstrutura('estante', ilhaPaletesNum), 'Ilha');
    expect(nomeEstrutura('estante', ilhaPaletesNum), 'Ilha de paletes');
  });

  test('espaços numerados como no croqui: 2 por fileira, do caixa à entrada', () {
    // Espaço 1 no canto do caixa (z menor) à esquerda (x menor); 2 ao lado;
    // 3 na fileira seguinte; 12 no canto da entrada à direita.
    final e1 = IlhaPaletesGeometry.origemEspaco(0);
    final e2 = IlhaPaletesGeometry.origemEspaco(1);
    final e3 = IlhaPaletesGeometry.origemEspaco(2);
    final e12 = IlhaPaletesGeometry.origemEspaco(11);
    expect(e2.x0, greaterThan(e1.x0));
    expect(e2.z0, e1.z0);
    expect(e3.x0, e1.x0);
    expect(e3.z0, greaterThan(e1.z0));
    expect(e12.x0, e2.x0);
    expect(e12.z0, closeTo(
        IlhaPaletesGeometry.profundidade - IlhaPaletesGeometry.profundidadePalete,
        1e-9));
  });

  test('as 5 posições de um espaço não se sobrepõem e cabem no palete', () {
    for (var e = 0; e < espacosIlhaPaletes; e++) {
      final o = IlhaPaletesGeometry.origemEspaco(e);
      final doEspaco = IlhaPaletesGeometry.celulas()
          .where((c) => c.nivel == e)
          .toList()
        ..sort((a, b) => a.coluna.compareTo(b.coluna));
      expect(doEspaco.length, produtosPorEspacoIlha);
      expect(doEspaco.first.xMin, closeTo(o.x0, 1e-9));
      expect(doEspaco.last.xMax,
          closeTo(o.x0 + IlhaPaletesGeometry.larguraPalete, 1e-9));
      for (var i = 1; i < doEspaco.length; i++) {
        expect(doEspaco[i].xMin, closeTo(doEspaco[i - 1].xMax, 1e-9));
      }
      // A caixa cabe na célula.
      expect(IlhaPaletesGeometry.wCaixa,
          lessThan(IlhaPaletesGeometry.larguraPalete / produtosPorEspacoIlha));
    }
  });

  test('no mapa, a ilha fica no corredor central sem encostar em gôndola', () {
    final ilha = itensLoja.singleWhere((i) => i.numero == ilhaPaletesNum);
    expect(ilha.tipo, 'estante');
    for (final g in itensLoja.where((i) => i.tipo == 'gondola')) {
      final dx = math.max(0.0, (g.x - ilha.x).abs() - ilha.w / 2);
      final dz = math.max(0.0, (g.z - ilha.z).abs() - ilha.d / 2);
      final dist = math.sqrt(dx * dx + dz * dz) - LojaGeometry.gondolaR;
      expect(dist, greaterThan(0.2), reason: 'encosta na gôndola ${g.numero}');
    }
    // Entre a Gôndola 7 (caixa) e a 6 (entrada).
    final g7 = itensLoja.singleWhere((i) => i.tipo == 'gondola' && i.numero == 7);
    final g6 = itensLoja.singleWhere((i) => i.tipo == 'gondola' && i.numero == 6);
    expect(ilha.z - ilha.d / 2, greaterThan(g7.z));
    expect(ilha.z + ilha.d / 2, lessThan(g6.z));
  });

  testWidgets('IlhaPaletesScene renderiza e o toque acha uma posição',
      (tester) async {
    ({int coluna, int nivel})? tocado;
    await tester.pumpWidget(MaterialApp(
      home: IlhaPaletesScene(
        caixas: const [
          CaixaColocadaEstante(
              produtoId: 'p1', coluna: 2, nivel: 4, slot: 0),
        ],
        corPorProduto: const {'p1': Color(0xFF2c5fb0)},
        onTapCelulaVisualizar: (c, n, _) => tocado = (coluna: c, nivel: n),
      ),
    ));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(IlhaPaletesScene));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // O centro da tela cai sobre a ilha (o pivô da câmera é o centro dela).
    expect(tocado, isNotNull);
    expect(tocado!.coluna, inInclusiveRange(0, produtosPorEspacoIlha - 1));
    expect(tocado!.nivel, inInclusiveRange(0, espacosIlhaPaletes - 1));
  });
}
