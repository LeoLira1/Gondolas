import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_config.dart';
import 'package:gondola_camda/galpao_scene.dart';
import 'package:gondola_camda/gondola_scene.dart'
    show Camera, ProjecaoCamera, Vec3;
import 'package:gondola_camda/models.dart' show corConferenciaCiano;

/// Uma pilha de [altura] racks na posição [posicao], como a cena espera
/// receber: ordem 1..n, sem buraco.
List<RackGalpao> _pilha(int posicao, int altura) => [
      for (var ordem = 1; ordem <= altura; ordem++)
        RackGalpao(
          posicao:       posicao,
          ordem:         ordem,
          produtoCodigo: 'P$ordem',
          produtoNome:   'PRODUTO $ordem',
          quantidade:    100,
        ),
    ];

void main() {
  group('ordem de desenho (substitui o sort por profundidade)', () {
    test('vai da posição mais longe para a mais perto do olho', () {
      final rua = GalpaoConfig.ruas.firstWhere((r) => r.numero == 1);
      final posicoes = GalpaoConfig.posicoesDaRua(rua.numero);
      // Olho bem além da ponta de maior Z: a ordem tem de ser a lista inteira
      // de trás para frente.
      const olho = 40.0;
      final ordem = ordemDeDesenho(rua, olho);
      expect(ordem.length, posicoes.length);
      var anterior = double.infinity;
      for (final p in ordem) {
        final d = (p.z - olho).abs();
        expect(d, lessThanOrEqualTo(anterior),
            reason: 'posição ${p.numero} fora de ordem');
        anterior = d;
      }
    });

    test('com o olho NO MEIO da rua, as duas metades saem intercaladas', () {
      // É o caso que um percurso monotônico numa direção só erraria: a rua se
      // afasta do olho para os dois lados.
      final rua = GalpaoConfig.ruas.firstWhere((r) => r.numero == 1);
      final olho = rua.centro;
      final ordem = ordemDeDesenho(rua, olho);
      expect(ordem.length, GalpaoConfig.posicoesDaRua(rua.numero).length);
      var anterior = double.infinity;
      for (final p in ordem) {
        final d = (p.z - olho).abs();
        expect(d, lessThanOrEqualTo(anterior + 1e-9),
            reason: 'posição ${p.numero} fora de ordem');
        anterior = d;
      }
      // A última desenhada é a mais próxima do olho — a que fica por cima.
      expect((ordem.last.z - olho).abs(), lessThan(GalpaoConfig.passoPosicao));
    });

    test('nenhuma posição é desenhada duas vezes nem fica de fora', () {
      for (final rua in GalpaoConfig.ruas) {
        for (final olho in [-40.0, 0.0, 3.2, 40.0]) {
          final ordem = ordemDeDesenho(rua, olho);
          expect(ordem.map((p) => p.numero).toSet().length, rua.quantidade,
              reason: 'Rua ${rua.numero}, olho $olho');
        }
      }
    });

    test('as ruas saem da mais longe para a mais perto', () {
      // Olho do lado direito do galpão (+X), fora dele.
      const olho = Vec3(60, 20, 1);
      final ordem = ruasPorProfundidade(olho);
      expect(ordem.length, 8);
      var anterior = double.infinity;
      for (final r in ordem) {
        final cx = r.eixo == EixoRua.z ? r.coordFixa : r.centro;
        final cz = r.eixo == EixoRua.z ? r.centro : r.coordFixa;
        final d = (cx - olho.x) * (cx - olho.x) + (cz - olho.z) * (cz - olho.z);
        expect(d, lessThanOrEqualTo(anterior));
        anterior = d;
      }
      // Olhando de +X: a Rua 3 (x = -7,60) é a do outro extremo e a Rua 1
      // (x = 8,30) é a que fica na frente de todas.
      expect(ordem.first.numero, 3);
      expect(ordem.last.numero, 1);
    });

    test('a ordem das ruas acompanha o olho, não é fixa', () {
      // Vista do topo do croqui (Z bem negativo): a Rua 2 (que atravessa esse
      // topo) passa a ser a da frente e a Rua 8, no fundo oposto, a mais
      // distante. Se a ordem fosse pré-calculada uma vez, girar a câmera
      // pintaria as ruas na ordem errada.
      final doTopo = ruasPorProfundidade(const Vec3(0, 20, -50));
      expect(doTopo.first.numero, 8);
      expect(doTopo.last.numero, 2);
    });

    test('o filtro tira a rua da lista de desenho', () {
      // O mesmo conjunto vai alimentar a lista de alvos do hit-test na etapa
      // 5: o que some da tela não pode continuar recebendo toque.
      final ordem = ruasPorProfundidade(const Vec3(30, 20, 30), visiveis: {2, 5});
      expect(ordem.map((r) => r.numero).toSet(), {2, 5});
    });

    test('só as ruas da parte desenhada entram no percurso', () {
      final parte1 = ruasPorProfundidade(const Vec3(60, 20, 1));
      expect(parte1.map((r) => r.numero).toSet(), {1, 2, 3, 4, 5, 6, 7, 8});

      final parte2 = ruasPorProfundidade(const Vec3(60, 20, 1), parte: 2);
      expect(parte2.map((r) => r.numero).toSet(), {9, 10, 11, 12});

      // O filtro de rua NÃO atravessa a parte: pedir a Rua 2 desenhando a
      // parte 2 não traz a rua do outro bloco de volta para a tela.
      expect(
          ruasPorProfundidade(const Vec3(60, 20, 1),
              parte: 2, visiveis: {2, 9}).map((r) => r.numero),
          [9]);
    });
  });

  group('cor do rack (precedência das três leituras)', () {
    const corProduto = Color(0xFF2e7d4f);
    const corPor     = {'BORAL': corProduto};

    test('sem destaque nem conferência, vale a cor do produto', () {
      expect(
        corRackGalpao(produtoCodigo: 'BORAL', corPorProduto: corPor),
        corProduto,
      );
      // Produto fora do catálogo cai no cinza padrão, não some.
      expect(
        corRackGalpao(produtoCodigo: 'XPTO', corPorProduto: corPor),
        isNot(corProduto),
      );
    });

    test('o produto buscado acende, independente do endereço', () {
      // O ponto da mudança: quem casa é o CÓDIGO, então todo rack do produto
      // acende — não só o endereço escolhido na lista de resultados.
      expect(
        corRackGalpao(
            produtoCodigo:   'BORAL',
            corPorProduto:   corPor,
            destacadoCodigo: 'BORAL'),
        corCamda,
      );
      // Os outros produtos continuam na cor deles.
      expect(
        corRackGalpao(
            produtoCodigo:   'ADUBO',
            corPorProduto:   corPor,
            destacadoCodigo: 'BORAL'),
        isNot(corCamda),
      );
    });

    test('código destacado vazio não acende ninguém', () {
      // Rack gravado sem código casaria com '' e acenderia o galpão inteiro.
      expect(
        corRackGalpao(produtoCodigo: '', destacadoCodigo: ''),
        isNot(corCamda),
      );
    });

    test('Modo Conferência tem precedência sobre a busca', () {
      // Ligada a conferência, o galpão inteiro fala de rota do dia: um cubo
      // laranja de busca no meio seria uma quarta cor sem significado.
      expect(
        corRackGalpao(
          produtoCodigo:      'BORAL',
          corPorProduto:      corPor,
          destacadoCodigo:    'BORAL',
          modoConferencia:    true,
          codigosConferencia: const {'BORAL'},
        ),
        corConferenciaCiano,
      );
      expect(
        corRackGalpao(
          produtoCodigo:      'BORAL',
          corPorProduto:      corPor,
          destacadoCodigo:    'BORAL',
          modoConferencia:    true,
          codigosConferencia: const {'OUTRO'},
        ),
        isNot(corCamda),
      );
    });
  });

  group('enquadramento da câmera', () {
    test('a parte aberta cabe inteira na tela, em pé e deitado', () {
      // Cada parte enquadra sozinha: o mapa desenha um bloco de cada vez, e é
      // o envelope DELE que tem de caber.
      for (final parte in GalpaoConfig.partes) {
        for (final size in const [
          Size(400, 800),
          Size(800, 400),
          Size(600, 600),
        ]) {
          final camera = GalpaoScene.enquadrar(size, parte: parte);
          final proj = _projecao(camera, size);
          final lim = GalpaoConfig.limitesDaParte(parte);
          for (final x in [lim.minX, lim.maxX]) {
            for (final z in [lim.minZ, lim.maxZ]) {
              for (final y in [
                0.0,
                GalpaoConfig.yTopo(GalpaoConfig.niveisMax),
              ]) {
                final tela = proj(Vec3(x, y, z));
                expect(tela, isNotNull, reason: 'canto atrás da câmera');
                expect(tela!.dx, inInclusiveRange(0, size.width),
                    reason: 'parte $parte · canto ($x, $y, $z) fora de $size');
                expect(tela.dy, inInclusiveRange(0, size.height),
                    reason: 'parte $parte · canto ($x, $y, $z) fora de $size');
              }
            }
          }
        }
      }
    });

    test('a câmera olha para o centro da parte aberta, de cima', () {
      for (final parte in GalpaoConfig.partes) {
        final camera =
            GalpaoScene.enquadrar(const Size(400, 800), parte: parte);
        final lim = GalpaoConfig.limitesDaParte(parte);
        expect(camera.target.x, closeTo((lim.minX + lim.maxX) / 2, 1e-9),
            reason: 'parte $parte');
        expect(camera.target.z, closeTo((lim.minZ + lim.maxZ) / 2, 1e-9),
            reason: 'parte $parte');
        // Bem acima do topo da pilha mais alta: é um mapa, tem de ler o chão.
        expect(camera.position.y,
            greaterThan(GalpaoConfig.yTopo(GalpaoConfig.niveisMax) * 3),
            reason: 'parte $parte');
      }
      // Enquadramentos diferentes: as duas partes estão longe uma da outra.
      expect(GalpaoScene.enquadrar(const Size(400, 800), parte: 2).target.x,
          greaterThan(
              GalpaoScene.enquadrar(const Size(400, 800), parte: 1).target.x));
    });
  });

  group('GalpaoScene', () {
    testWidgets('pinta o galpão vazio sem exceção', (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: GalpaoScene())));
      expect(tester.takeException(), isNull);
      expect(find.byType(GalpaoScene), findsOneWidget);
    });

    testWidgets('pinta pilhas cheias, parciais e vazias juntas',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GalpaoScene(
            pilhas: {
              1:  _pilha(1, GalpaoConfig.niveisMax),
              15: _pilha(15, 2),
              52: _pilha(52, 1),
              78: _pilha(78, 3),
            },
            corPorProduto: const {
              'P1': Color(0xFF8b1a1a),
              'P2': Color(0xFF2e7d4f),
            },
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('pilha em posição inexistente não derruba a cena',
        (tester) async {
      // Linha órfã no banco (posição renumerada, importação errada): a cena
      // ignora, como as outras cenas fazem com endereço fora da grade.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GalpaoScene(pilhas: {999: _pilha(999, 2)}),
        ),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('gira e dá zoom sem exceção', (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: GalpaoScene())));
      final centro = tester.getCenter(find.byType(GalpaoScene));

      // Um dedo: pan.
      final dedo = await tester.startGesture(centro);
      await dedo.moveBy(const Offset(60, -40));
      await dedo.up();
      await tester.pump();

      // Dois dedos: órbita + zoom.
      final a = await tester.startGesture(centro - const Offset(40, 0));
      final b = await tester.startGesture(centro + const Offset(40, 0));
      await a.moveBy(const Offset(-30, 20));
      await b.moveBy(const Offset(30, -20));
      await a.up();
      await b.up();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('toque e seleção', () {
    // Tamanho da superfície padrão dos widget tests; a cena preenche tudo.
    const tela = Size(800, 600);

    /// Ponto de tela do centro do rack/vaga de [ordem] na posição [numero],
    /// pela mesma câmera de enquadramento que a cena usa ao abrir.
    Offset centroNaTela(int numero, int ordem) {
      final camera = GalpaoScene.enquadrar(tela);
      final p = GalpaoConfig.porNumero(numero)!;
      final y = (GalpaoConfig.yBase(ordem) + GalpaoConfig.yTopo(ordem)) / 2;
      return _projecao(camera, tela)(Vec3(p.x, y, p.z))!;
    }

    testWidgets('toque no contorno de vaga devolve a próxima ordem livre',
        (tester) async {
      final toques = <ToqueGalpao?>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GalpaoScene(onTapEndereco: toques.add)),
      ));

      await tester.tapAt(centroNaTela(1, 1));
      await tester.pump();

      expect(toques, [
        const ToqueGalpao(posicao: 1, ordem: 1, ocupado: false),
      ]);
    });

    testWidgets('toque num rack ocupado devolve o rack, não a vaga',
        (tester) async {
      final toques = <ToqueGalpao?>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GalpaoScene(
            pilhas: {1: _pilha(1, GalpaoConfig.niveisMax)},
            onTapEndereco: toques.add,
          ),
        ),
      ));

      // Pilha cheia: o topo é o rack de ordem 4, sem contorno em cima.
      await tester.tapAt(centroNaTela(1, GalpaoConfig.niveisMax));
      await tester.pump();

      expect(toques, [
        const ToqueGalpao(
            posicao: 1, ordem: GalpaoConfig.niveisMax, ocupado: true),
      ]);
    });

    testWidgets('na parte 2, o toque cai numa posição da parte 2',
        (tester) async {
      final toques = <ToqueGalpao?>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GalpaoScene(parte: 2, onTapEndereco: toques.add),
        ),
      ));

      // Enquadramento da parte 2: o mesmo ponto de tela da posição 86 pela
      // câmera com que a cena abre nessa parte.
      final camera = GalpaoScene.enquadrar(tela, parte: 2);
      final p = GalpaoConfig.porNumero(86)!;
      final y = (GalpaoConfig.yBase(1) + GalpaoConfig.yTopo(1)) / 2;
      await tester.tapAt(_projecao(camera, tela)(Vec3(p.x, y, p.z))!);
      await tester.pump();

      expect(toques, [
        const ToqueGalpao(posicao: 86, ordem: 1, ocupado: false),
      ]);
    });

    testWidgets('nenhum toque na parte 2 devolve endereço da parte 1',
        (tester) async {
      final toques = <ToqueGalpao?>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GalpaoScene(parte: 2, onTapEndereco: toques.add),
        ),
      ));

      // Varre a tela inteira: com o bloco da parte 1 fora do desenho, nenhum
      // ponto pode devolver um endereço dele — esconder no desenho não basta,
      // a lista de alvos do hit-test também tem de excluir a outra parte.
      for (var x = 20.0; x < tela.width; x += 60) {
        for (var y = 20.0; y < tela.height; y += 60) {
          await tester.tapAt(Offset(x, y));
          await tester.pump();
        }
      }

      expect(toques, isNotEmpty);
      for (final toque in toques) {
        if (toque == null) continue;
        expect(GalpaoConfig.parteDe(toque.posicao), 2,
            reason: 'posição ${toque.posicao} não é da parte 2');
      }
    });

    testWidgets('toque no nada desfaz a seleção (callback null)',
        (tester) async {
      final toques = <ToqueGalpao?>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GalpaoScene(onTapEndereco: toques.add)),
      ));

      await tester.tapAt(const Offset(6, 6)); // canto: só fundo
      await tester.pump();

      expect(toques, [null]);
    });

    testWidgets('arrasto não vira seleção', (tester) async {
      final toques = <ToqueGalpao?>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GalpaoScene(onTapEndereco: toques.add)),
      ));

      final dedo = await tester.startGesture(centroNaTela(1, 1));
      await dedo.moveBy(const Offset(30, 0)); // além dos 9 px do galpão
      await dedo.up();
      await tester.pump();

      expect(toques, isEmpty);
    });

    testWidgets('segurar mais de 600 ms não vira seleção', (tester) async {
      final toques = <ToqueGalpao?>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GalpaoScene(onTapEndereco: toques.add)),
      ));

      // O relógio dos eventos de ponteiro não anda com o pump: o timestamp
      // do soltar precisa ser explícito para simular a espera.
      final dedo = await tester.startGesture(centroNaTela(1, 1));
      await dedo.up(timeStamp: const Duration(milliseconds: 900));
      await tester.pump();

      expect(toques, isEmpty);
    });

    testWidgets('cena com seleção pinta o destaque sem exceção',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GalpaoScene(
            pilhas: {52: _pilha(52, 2)},
            selecionado: (posicao: 52, ordem: 2),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('produto destacado em ruas diferentes pinta sem exceção',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GalpaoScene(
            pilhas: {
              1:  _pilha(1, 2),
              52: _pilha(52, 1),
              78: _pilha(78, 3),
            },
            // 'P1' é o rack de ordem 1 de todas as pilhas do helper: o
            // destaque cruza três ruas de uma vez.
            destacadoCodigo: 'P1',
            selecionado:     (posicao: 52, ordem: 1),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });
  });

}

/// Projeção de tela equivalente à da cena, para conferir o enquadramento sem
/// depender de um paint real.
///
/// É a mesma conta de ProjecaoCamera; escrita aqui para o teste poder chamá-la
/// sem uma Size vinda de um paint de verdade.
Offset? Function(Vec3) _projecao(Camera camera, Size size) {
  final olho   = camera.position;
  final fwd    = (camera.target - olho).normalized;
  final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
  final up     = right.cross(fwd).normalized;
  final tanH   = math.tan(ProjecaoCamera.fovY / 2);
  final aspect = size.width / size.height;

  return (Vec3 v) {
    final d  = v - olho;
    final cz = d.dot(fwd);
    if (cz <= ProjecaoCamera.near) return null;
    final cx = d.dot(right) / (cz * tanH * aspect);
    final cy = d.dot(up) / (cz * tanH);
    return Offset((cx + 1) / 2 * size.width, (1 - cy) / 2 * size.height);
  };
}
