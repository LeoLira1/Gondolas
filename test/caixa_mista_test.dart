import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/caixa_mista.dart';
import 'package:gondola_camda/estante_edr300_scene.dart';
import 'package:gondola_camda/estante_parede_scene.dart';
import 'package:gondola_camda/estante_scene.dart';
import 'package:gondola_camda/galpao_config.dart';
import 'package:gondola_camda/galpao_saldo.dart';
import 'package:gondola_camda/gondola_scene.dart'
    show Face, corEnderecoDivergente, corEnderecoDivergentePositiva;
import 'package:gondola_camda/models.dart';

const _p1 = CaixaColocadaEstante(coluna: 0, nivel: 2, slot: 1, produtoId: 'P1');
const _p2 = CaixaColocadaEstante(coluna: 0, nivel: 2, slot: 1, produtoId: 'P2');
const _p3 = CaixaColocadaEstante(coluna: 0, nivel: 2, slot: 1, produtoId: 'P3');
const _outra = CaixaColocadaEstante(coluna: 1, nivel: 0, slot: 0, produtoId: 'Q');

SaldoProduto _saldo(String c, double sistema, double enderecado) =>
    SaldoProduto(codigo: c, qtdSistema: sistema, enderecado: enderecado);

void main() {
  group('agrupar e editar caixas', () {
    test('linhas do mesmo slot viram UMA caixa, na ordem das linhas', () {
      final caixas = agruparCaixas(const [_p1, _outra, _p2, _p3]);
      expect(caixas, hasLength(2));
      final mista = caixas.first;
      expect(mista.mista, isTrue);
      expect(mista.codigos, ['P1', 'P2', 'P3']);
      expect(mista.principal, 'P1');
      expect(caixas.last.mista, isFalse);
    });

    test('o limite é o mesmo do rack misto do galpão (5)', () {
      expect(produtosMaxPorCaixa, GalpaoConfig.produtosMaxPorRack);
      expect(produtosMaxPorCaixa, 5);
    });

    test('não aceita repetido nem o 6º produto, com as frases do galpão', () {
      final caixa = caixaNoEndereco(const [_p1, _p2], 0, 2, 1)!;
      expect(motivoParaNaoAdicionar(caixa, 'P2'),
          contains('já está nesta caixa'));
      expect(motivoParaNaoAdicionar(caixa, 'P9'), isNull);

      var linhas = const [_p1, _p2];
      for (final c in ['P3', 'P4', 'P5']) {
        linhas = comProdutoNaCaixa(linhas, caixaNoEndereco(linhas, 0, 2, 1)!, c);
      }
      final cheia = caixaNoEndereco(linhas, 0, 2, 1)!;
      expect(cheia.cheia, isTrue);
      expect(motivoParaNaoAdicionar(cheia, 'P6'), 'A caixa já tem 5 produtos.');
    });

    test('produto novo entra no fim da caixa e herda o nome dela', () {
      final linhas = comNomeDaCaixa(
          const [_p1, _outra], caixaNoEndereco(const [_p1], 0, 2, 1)!,
          '  Peças Hoppner ');
      final caixa = caixaNoEndereco(linhas, 0, 2, 1)!;
      expect(caixa.nome, 'Peças Hoppner');

      final depois = comProdutoNaCaixa(linhas, caixa, 'P2');
      final nova = caixaNoEndereco(depois, 0, 2, 1)!;
      expect(nova.codigos, ['P1', 'P2']);
      expect(nova.linhas.every((l) => l.nomeCaixa == 'Peças Hoppner'), isTrue);
      // A outra caixa não ganha nome.
      expect(caixaNoEndereco(depois, 1, 0, 0)!.nome, isNull);
    });

    test('nome vazio apaga o nome da caixa', () {
      final comNome = comNomeDaCaixa(
          const [_p1, _p2], caixaNoEndereco(const [_p1], 0, 2, 1)!, 'X');
      final sem = comNomeDaCaixa(
          comNome, caixaNoEndereco(comNome, 0, 2, 1)!, '   ');
      expect(caixaNoEndereco(sem, 0, 2, 1)!.nome, isNull);
    });

    test('tirar produtos até sobrar um volta à caixa comum; o último tira a caixa',
        () {
      var linhas = const [_p1, _p2, _outra];
      linhas = semProdutoNaCaixa(linhas, caixaNoEndereco(linhas, 0, 2, 1)!, 'P1');
      final sobrou = caixaNoEndereco(linhas, 0, 2, 1)!;
      expect(sobrou.mista, isFalse);
      expect(sobrou.principal, 'P2');
      linhas = semProdutoNaCaixa(linhas, sobrou, 'P2');
      expect(caixaNoEndereco(linhas, 0, 2, 1), isNull);
      expect(linhas, [_outra]);
    });

    test('o mesmo produto em outra caixa da posição não sai junto', () {
      const outroSlot =
          CaixaColocadaEstante(coluna: 0, nivel: 2, slot: 3, produtoId: 'P1');
      final linhas = semProdutoNaCaixa(
          const [_p1, _p2, outroSlot], caixaNoEndereco(const [_p1, _p2], 0, 2, 1)!,
          'P1');
      expect(linhas, contains(outroSlot));
    });
  });

  group('cor das fatias', () {
    const categoria = Color(0xFF123456);

    test('vermelho falta endereçar, azul acima do saldo, branco fecha', () {
      expect(corDaFatia(_saldo('a', 24, 18), corSemSaldo: categoria),
          corEnderecoDivergente);
      expect(corDaFatia(_saldo('a', 4, 6), corSemSaldo: categoria),
          corEnderecoDivergentePositiva);
      expect(corDaFatia(_saldo('a', 12, 12), corSemSaldo: categoria),
          corFatiaOk);
    });

    test('sem saldo conhecido fica a cor da categoria, como no galpão', () {
      expect(corDaFatia(null, corSemSaldo: categoria), categoria);
    });

    test('destaque de busca ou conferência pinta a caixa mista inteira', () {
      final caixa = caixaNoEndereco(const [_p1, _p2], 0, 2, 1)!;
      final normal = pinturaDaCaixa(caixa,
          corComum: (_) => Colors.grey,
          saldos: {'P1': _saldo('P1', 10, 4)},
          corCategoria: categoria);
      expect(normal.fatias, [corEnderecoDivergente, categoria]);

      final destacada = pinturaDaCaixa(caixa,
          corComum: (_) => Colors.grey,
          saldos: const {},
          corCategoria: categoria,
          destaque: (c) => c == 'P2' ? Colors.cyan : null);
      expect(destacada.fatias, isNull);
      expect(destacada.lisa, Colors.cyan);
    });
  });

  group('geometria das fatias', () {
    test('uma fatia por produto, de cima para baixo, com filete entre elas', () {
      final faixas = fatiasDaCaixa(0, 1, const [Colors.red, Colors.blue, Colors.white]);
      final fatias = faixas.where((f) => f.cor != corFileteFatia).toList();
      final filetes = faixas.where((f) => f.cor == corFileteFatia).toList();
      expect(fatias.map((f) => f.cor), [Colors.red, Colors.blue, Colors.white]);
      expect(filetes, hasLength(2));
      expect(fatias.first.y1, 1); // a primeira é a de cima
      expect(fatias.last.y0, 0);
      for (var i = 1; i < fatias.length; i++) {
        expect(fatias[i].y1, lessThanOrEqualTo(fatias[i - 1].y0 + 1e-9));
      }
    });

    test('a caixa listrada ocupa o mesmo volume da caixa comum', () {
      final faces = <Face>[];
      addCaixaListrada(faces,
          x0: 0, x1: 0.2, y0: 0.5, y1: 0.8, z0: -0.2, z1: 0.2,
          cores: const [Colors.red, Colors.white]);
      final ys = faces.expand((f) => f.verts).map((v) => v.y);
      final xs = faces.expand((f) => f.verts).map((v) => v.x);
      expect(ys.reduce((a, b) => a < b ? a : b), closeTo(0.5, 1e-9));
      expect(ys.reduce((a, b) => a > b ? a : b), closeTo(0.8, 1e-9));
      expect(xs.reduce((a, b) => a < b ? a : b), closeTo(0, 1e-9));
      expect(xs.reduce((a, b) => a > b ? a : b), closeTo(0.2, 1e-9));
    });
  });

  group('regras de endereço', () {
    test('só estruturas com vários slots e caixas aceitam caixa mista', () {
      for (final n in [1, 6, 8, 13, 18]) {
        expect(estanteAceitaCaixaMista(n), isTrue, reason: 'E$n');
      }
      for (final n in [expositorMagnojetNum, expositorNelloreNum,
          expositorMonitorNum, expositorMadeiraNum, paleteNumMin]) {
        expect(estanteAceitaCaixaMista(n), isFalse, reason: 'E$n');
      }
    });

    test('quantidade na posição soma estoque_localizado sem olhar o slot', () {
      final linhas = [
        {'produto_codigo': 'P1', 'local_tipo': 'estante', 'local_num': 13,
         'face_ou_coluna': 0, 'andar_ou_nivel': 2, 'quantidade': 24},
        // A cópia passa por JSON: número volta double.
        {'produto_codigo': 'P1', 'local_tipo': 'estante', 'local_num': 13.0,
         'face_ou_coluna': 0.0, 'andar_ou_nivel': 2.0, 'quantidade': 1.0},
        {'produto_codigo': 'P1', 'local_tipo': 'estante', 'local_num': 14,
         'face_ou_coluna': 0, 'andar_ou_nivel': 2, 'quantidade': 99},
        {'produto_codigo': 'P1', 'local_tipo': 'gondola', 'local_num': 13,
         'face_ou_coluna': 0, 'andar_ou_nivel': 2, 'quantidade': 99},
      ];
      expect(
        quantidadeNaPosicao(linhas,
            codigo: 'P1', estanteNum: 13, coluna: 0, nivel: 2),
        25,
      );
      expect(
        quantidadeNaPosicao(linhas,
            codigo: 'P2', estanteNum: 13, coluna: 0, nivel: 2),
        isNull,
      );
    });

    test('E13·4 é a coluna 0, nível 2 da Estante Parede', () {
      expect(letraEstanteCelula(13, 0, 2), '4');
    });
  });

  group('cenas', () {
    const linhas = [
      CaixaColocadaEstante(coluna: 0, nivel: 2, slot: 0, produtoId: 'A'),
      CaixaColocadaEstante(coluna: 0, nivel: 2, slot: 1, produtoId: 'P1'),
      CaixaColocadaEstante(coluna: 0, nivel: 2, slot: 1, produtoId: 'P2'),
      CaixaColocadaEstante(coluna: 0, nivel: 2, slot: 1, produtoId: 'P3'),
    ];
    final saldos = {
      'P1': _saldo('P1', 24, 18), // falta
      'P2': _saldo('P2', 4, 6), // sobra
      'P3': _saldo('P3', 12, 12), // ok
    };

    test('montarCaixasDaEstante: caixa comum lisa, mista listrada com selo', () {
      final faces = <Face>[];
      final lisas = <String>[];
      final selos = montarCaixasDaEstante(
        faces,
        linhas: linhas,
        estanteNum: 13,
        corPorProduto: const {'A': Colors.green},
        saldos: saldos,
        destacadoCodigo: null,
        destacadosCodigos: const {},
        divergentes: const {},
        divergentesPositivas: const {},
        desatualizados: const {},
        corConferencia: Colors.cyan,
        volume: (c) => (
          x0: c.slot * 0.3, x1: c.slot * 0.3 + 0.2,
          y0: 0, y1: 0.3, z0: -0.2, z1: 0.2, tamanhoBadge: 0.08,
        ),
        caixaLisa: (c, cor, _) => lisas.add('${c.principal}:${cor.toARGB32()}'),
      );
      expect(lisas, ['A:${Colors.green.toARGB32()}']);
      final cores = faces.map((f) => f.color).toSet();
      expect(cores, containsAll([
        corEnderecoDivergente, corEnderecoDivergentePositiva, corFatiaOk,
        corFileteFatia,
      ]));
      expect(selos, hasLength(1));
      expect(selos.single.texto, '+3');
    });

    Future<void> pump(WidgetTester tester, Widget cena) async {
      await tester.pumpWidget(MaterialApp(home: cena));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    testWidgets('Estante Parede desenha a caixa mista listrada e o selo',
        (tester) async {
      await pump(tester, EstanteParedeScene(
        estanteAtual: 13,
        caixas: linhas,
        corPorProduto: const {'A': Colors.green},
        saldos: saldos,
      ));
      final painter = tester.widget<CustomPaint>(find.descendant(
        of: find.byType(EstanteParedeScene),
        matching: find.byType(CustomPaint),
      )).painter as EstanteParedePainter;
      expect(painter.selos.map((s) => s.texto), ['+3']);
      expect(painter.extraFaces.any((f) => f.color == corEnderecoDivergente),
          isTrue);
      expect(painter.extraFaces.any((f) => f.color == corFatiaOk), isTrue);
    });

    testWidgets('estante de madeira e EDR-300 também listram a caixa mista',
        (tester) async {
      await pump(tester, EstanteScene(
        estanteAtual: 1,
        caixas: const [
          CaixaColocadaEstante(coluna: 0, nivel: 0, slot: 0, produtoId: 'P1'),
          CaixaColocadaEstante(coluna: 0, nivel: 0, slot: 0, produtoId: 'P2'),
        ],
        saldos: saldos,
      ));
      final madeira = tester.widget<CustomPaint>(find.descendant(
        of: find.byType(EstanteScene),
        matching: find.byType(CustomPaint),
      )).painter as EstantePainter;
      expect(madeira.selos.map((s) => s.texto), ['+2']);

      await pump(tester, Edr300Scene(
        geometry: Edr300Geometry(showFloor: false),
        estanteNum: 8,
        autoRotate: false,
        caixas: const [
          CaixaColocadaEstante(coluna: 0, nivel: 1, slot: 0, produtoId: 'P1'),
          CaixaColocadaEstante(coluna: 0, nivel: 1, slot: 0, produtoId: 'P3'),
        ],
        saldos: saldos,
      ));
      final edr = tester.widget<CustomPaint>(find.descendant(
        of: find.byType(Edr300Scene),
        matching: find.byType(CustomPaint),
      )).painter as Edr300Painter;
      expect(edr.selos.map((s) => s.texto), ['+2']);
      expect(edr.extraFaces.any((f) => f.color == corEnderecoDivergente), isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
