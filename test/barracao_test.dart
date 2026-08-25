import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/barracao_config.dart';
import 'package:gondola_camda/barracao_page.dart';
import 'package:gondola_camda/barracao_scene.dart';
import 'package:gondola_camda/barracao_service.dart';
import 'package:gondola_camda/gondola_scene.dart' show Camera, Vec3;
import 'package:gondola_camda/models.dart' show Produto;

/// Os endereços do layout padrão como a página os receberia do banco: id
/// sequencial a partir de 1, na ordem dos rótulos.
List<EnderecoBarracao> _enderecosPadrao() {
  final posicoes = BarracaoConfig.posicoesPadrao;
  return [
    for (var i = 0; i < posicoes.length; i++)
      EnderecoBarracao(
        id:     i + 1,
        rotulo: posicoes[i].rotulo,
        x:      posicoes[i].x,
        z:      posicoes[i].z,
      ),
  ];
}

void main() {
  group('obra do barracão', () {
    test('retângulo de 3500 × 1000 com pé-direito 600 e parede de 20', () {
      expect(BarracaoConfig.largura, 3500);
      expect(BarracaoConfig.profundidade, 1000);
      expect(BarracaoConfig.peDireito, 600);
      expect(BarracaoConfig.espessuraParede, 20);
    });

    test('as três aberturas estão na sequência e nas medidas da planta', () {
      final a = BarracaoConfig.aberturas;
      expect(a.length, 3);

      expect(a[0].tipo, TipoAbertura.porta);
      expect(a[0].x0, 600);
      expect(a[0].x1, 800);
      expect(a[0].largura, 200);
      expect(a[0].altura, 300);

      expect(a[1].tipo, TipoAbertura.portao);
      expect(a[1].x0, 1300);
      expect(a[1].x1, 1800);
      expect(a[1].largura, 500);
      expect(a[1].altura, 450);

      expect(a[2].tipo, TipoAbertura.porta);
      expect(a[2].x0, 2300);
      expect(a[2].x1, 2500);
      expect(a[2].largura, 200);
      expect(a[2].altura, 300);
    });

    test('os panos cheios são o complemento exato das aberturas', () {
      final panos = BarracaoConfig.panosDaFrente;
      expect(
        [for (final p in panos) (p.x0, p.x1)],
        [(0.0, 600.0), (800.0, 1300.0), (1800.0, 2300.0), (2500.0, 3500.0)],
      );
      // Panos + aberturas cobrem os 35 m sem sobra nem buraco.
      final somaPanos =
          panos.fold<double>(0, (s, p) => s + p.largura);
      final somaAberturas = BarracaoConfig.aberturas
          .fold<double>(0, (s, a) => s + a.largura);
      expect(somaPanos + somaAberturas, BarracaoConfig.largura);
      // Todos vão do chão ao pé-direito.
      for (final p in panos) {
        expect(p.y0, 0);
        expect(p.y1, BarracaoConfig.peDireito);
      }
    });

    test('cada abertura tem verga do topo do vão até o pé-direito', () {
      final vergas = BarracaoConfig.vergas;
      expect(vergas.length, BarracaoConfig.aberturas.length);
      for (var i = 0; i < vergas.length; i++) {
        final a = BarracaoConfig.aberturas[i];
        expect(vergas[i].x0, a.x0);
        expect(vergas[i].x1, a.x1);
        expect(vergas[i].y0, a.altura);
        expect(vergas[i].y1, BarracaoConfig.peDireito);
        expect(vergas[i].altura, BarracaoConfig.peDireito - a.altura);
      }
    });
  });

  group('layout dos paletes', () {
    test('palete 120 × 100 × 15 com bag de 100 × 85 × 130 em cima', () {
      expect(BarracaoConfig.paleteX, 120);
      expect(BarracaoConfig.paleteZ, 100);
      expect(BarracaoConfig.paleteAltura, 15);
      expect(BarracaoConfig.bagX, 100);
      expect(BarracaoConfig.bagZ, 85);
      expect(BarracaoConfig.bagAltura, 130);
      expect(BarracaoConfig.alturaCarga, 145);
      // O bag cabe em cima do palete, sem transbordar.
      expect(BarracaoConfig.bagX, lessThanOrEqualTo(BarracaoConfig.paleteX));
      expect(BarracaoConfig.bagZ, lessThanOrEqualTo(BarracaoConfig.paleteZ));
    });

    test('passo de 135 em X e 120 em Z, com a folga do enunciado', () {
      expect(BarracaoConfig.passoX, BarracaoConfig.paleteX + 15);
      expect(BarracaoConfig.passoZ, BarracaoConfig.paleteZ + 20);
    });

    test('a primeira fileira encosta na parede do fundo', () {
      final z = BarracaoConfig.zDaFileira(0);
      expect(z + BarracaoConfig.paleteZ / 2, BarracaoConfig.interiorZ1);
    });

    test('as fileiras avançam para a FRENTE, uma por passo', () {
      for (var i = 1; i < BarracaoConfig.fileiras; i++) {
        expect(
          BarracaoConfig.zDaFileira(i - 1) - BarracaoConfig.zDaFileira(i),
          closeTo(BarracaoConfig.passoZ, 1e-9),
        );
      }
    });

    test('sobram ao menos 400 cm de corredor de manobra', () {
      expect(BarracaoConfig.corredorLivre,
          greaterThanOrEqualTo(BarracaoConfig.corredorManobra));
    });

    test('não cabe mais uma fileira sem comer o corredor', () {
      // A fileira seguinte à última existente invadiria os 400 cm — é o que
      // decide o número de fileiras, e o que um passo diferente mudaria.
      final proxima = BarracaoConfig.zDaFileira(BarracaoConfig.fileiras) -
          BarracaoConfig.paleteZ / 2;
      expect(proxima - BarracaoConfig.interiorZ0,
          lessThan(BarracaoConfig.corredorManobra));
    });

    test('as colunas cabem entre as paredes, com folga igual dos dois lados',
        () {
      final primeiro =
          BarracaoConfig.xDaColuna(0) - BarracaoConfig.paleteX / 2;
      final ultimo = BarracaoConfig.xDaColuna(BarracaoConfig.colunas - 1) +
          BarracaoConfig.paleteX / 2;
      expect(primeiro, greaterThanOrEqualTo(BarracaoConfig.interiorX0));
      expect(ultimo, lessThanOrEqualTo(BarracaoConfig.interiorX1));
      expect(primeiro - BarracaoConfig.interiorX0,
          closeTo(BarracaoConfig.interiorX1 - ultimo, 1e-9));
    });

    test('não cabe mais uma coluna', () {
      final aMais = BarracaoConfig.xDaColuna(BarracaoConfig.colunas) +
          BarracaoConfig.paleteX / 2;
      expect(aMais, greaterThan(BarracaoConfig.interiorX1));
    });

    test('a câmera padrão passa por cima da parede e alcança a 1ª fileira',
        () {
      // A parede da frente projeta uma sombra geométrica de
      // peDireito / tan(elevação) para dentro do barracão; a fileira mais à
      // frente precisa estar além dela, senão a vista abre com paletes
      // escondidos atrás de uma parede de 6 m.
      final sombra =
          BarracaoConfig.peDireito / math.tan(BarracaoConfig.rotXPadrao);
      final frenteDaPrimeira =
          BarracaoConfig.zDaFileira(BarracaoConfig.fileiras - 1) -
              BarracaoConfig.paleteZ / 2;
      expect(frenteDaPrimeira, greaterThan(sombra));
    });
  });

  group('numeração dos endereços', () {
    test('BAR-01 em diante, com zero à esquerda até 99', () {
      expect(BarracaoConfig.rotuloDoIndice(0), 'BAR-01');
      expect(BarracaoConfig.rotuloDoIndice(8), 'BAR-09');
      expect(BarracaoConfig.rotuloDoIndice(9), 'BAR-10');
      expect(BarracaoConfig.rotuloDoIndice(99), 'BAR-100');
    });

    test('é contínua no barracão inteiro — não reinicia por fileira', () {
      final posicoes = BarracaoConfig.posicoesPadrao;
      expect(posicoes.length,
          BarracaoConfig.fileiras * BarracaoConfig.colunas);
      for (var i = 0; i < posicoes.length; i++) {
        expect(posicoes[i].rotulo, BarracaoConfig.rotuloDoIndice(i));
      }
      // E não há rótulo repetido, que é o que a numeração por fileira criaria.
      expect(posicoes.map((p) => p.rotulo).toSet().length, posicoes.length);
    });

    test('numera do fundo para a frente e, na fileira, da esquerda para a '
        'direita', () {
      final posicoes = BarracaoConfig.posicoesPadrao;
      expect(posicoes.first.fileira, 0);
      expect(posicoes.first.coluna, 0);
      // O primeiro endereço está na fileira encostada no fundo…
      expect(posicoes.first.z, BarracaoConfig.zDaFileira(0));
      // …e o segundo, ao lado dele, um passo à direita.
      expect(posicoes[1].z, posicoes.first.z);
      expect(posicoes[1].x - posicoes.first.x,
          closeTo(BarracaoConfig.passoX, 1e-9));
      // A virada de fileira acontece exatamente a cada `colunas` endereços.
      final viradaZ = posicoes[BarracaoConfig.colunas].z;
      expect(viradaZ, BarracaoConfig.zDaFileira(1));
      expect(posicoes[BarracaoConfig.colunas].coluna, 0);
    });

    test('todo palete cai dentro das paredes', () {
      for (final p in BarracaoConfig.posicoesPadrao) {
        expect(p.x - BarracaoConfig.paleteX / 2,
            greaterThanOrEqualTo(BarracaoConfig.interiorX0));
        expect(p.x + BarracaoConfig.paleteX / 2,
            lessThanOrEqualTo(BarracaoConfig.interiorX1));
        expect(p.z - BarracaoConfig.paleteZ / 2,
            greaterThanOrEqualTo(BarracaoConfig.interiorZ0));
        expect(p.z + BarracaoConfig.paleteZ / 2,
            lessThanOrEqualTo(BarracaoConfig.interiorZ1));
      }
    });
  });

  group('cor do bag', () {
    test('produto sem cor conhecida cai no cinza', () {
      expect(corBagBarracao(produtoCodigo: 'X1'), const Color(0xFF888888));
    });

    test('a cor da categoria vence o cinza', () {
      expect(
        corBagBarracao(
            produtoCodigo: 'X1',
            corPorProduto: const {'X1': Color(0xFF123456)}),
        const Color(0xFF123456),
      );
    });

    test('o destaque da busca vence a cor da categoria', () {
      expect(
        corBagBarracao(
          produtoCodigo:   'X1',
          corPorProduto:   const {'X1': Color(0xFF123456)},
          destacadoCodigo: 'X1',
        ),
        corCamdaBarracao,
      );
    });

    test('destaque vazio não acende ninguém', () {
      // Um endereço gravado sem código casaria com '' e acenderia o barracão
      // inteiro — a mesma guarda do galpão.
      expect(
        corBagBarracao(produtoCodigo: '', destacadoCodigo: ''),
        const Color(0xFF888888),
      );
    });
  });

  group('geometria da cena', () {
    setUp(BarracaoGeometry.limparCache);

    test('palete livre desenha só o estrado; ocupado ganha o bag', () {
      const livre = EnderecoBarracao(id: 1, rotulo: 'BAR-01', x: 500, z: 900);
      final soParedes = BarracaoGeometry.buildFaces(const []).length;

      final comLivre = BarracaoGeometry.buildFaces([livre]).length;
      expect(comLivre - soParedes, 5, reason: 'estrado = 1 caixa de 5 faces');

      BarracaoGeometry.limparCache();
      final ocupado = livre.comProduto(
          produtoCodigo: 'X1', produtoNome: 'PRODUTO', quantidade: 10);
      final comBag = BarracaoGeometry.buildFaces([ocupado]).length;
      expect(comBag - soParedes, 10, reason: 'estrado + bag = 2 caixas');
    });

    test('a lista de faces é memoizada por identidade dos dados', () {
      final enderecos = _enderecosPadrao();
      final a = BarracaoGeometry.buildFaces(enderecos);
      final b = BarracaoGeometry.buildFaces(enderecos);
      expect(identical(a, b), isTrue);

      // Mudar a seleção remonta.
      final c = BarracaoGeometry.buildFaces(enderecos, selecionadoId: 1);
      expect(identical(a, c), isFalse);
    });

    test('nenhuma face passa do pé-direito nem sai das paredes', () {
      final faces = BarracaoGeometry.buildFaces(_enderecosPadrao());
      expect(faces, isNotEmpty);
      for (final f in faces) {
        for (final v in f.verts) {
          expect(v.y, greaterThanOrEqualTo(-1e-9));
          expect(v.y, lessThanOrEqualTo(BarracaoConfig.peDireito + 1e-9));
          expect(v.x, greaterThanOrEqualTo(-1e-9));
          expect(v.x, lessThanOrEqualTo(BarracaoConfig.largura + 1e-9));
          expect(v.z, greaterThanOrEqualTo(-1e-9));
          expect(v.z, lessThanOrEqualTo(BarracaoConfig.profundidade + 1e-9));
        }
      }
    });

    test('o vão de cada abertura fica LIVRE de parede', () {
      final faces = BarracaoGeometry.buildFaces(const []);
      for (final abertura in BarracaoConfig.aberturas) {
        // Um ponto no meio do vão, na metade da altura dele: nenhuma face de
        // parede pode ter um vértice ali dentro.
        final xMeio = abertura.centroX;
        final yMeio = abertura.altura / 2;
        for (final f in faces) {
          final dentro = f.verts.every((v) =>
              v.z <= BarracaoConfig.espessuraParede + 1e-9 &&
              v.x > abertura.x0 - 1e-9 &&
              v.x < abertura.x1 + 1e-9 &&
              v.y < yMeio);
          expect(dentro, isFalse,
              reason: 'face dentro do vão de ${abertura.rotulo} '
                  '(x $xMeio, y $yMeio)');
        }
      }
    });
  });

  group('câmera padrão', () {
    test('o olho fica DE FRENTE para a parede das aberturas (fora dela)', () {
      final camera = BarracaoScene.enquadrar(const Size(400, 800));
      // A parede das aberturas está em Z = 0; olhar de frente para ela é ter o
      // olho do lado de fora, em Z negativo.
      expect(camera.position.z, lessThan(0));
      // E acima do pé-direito, para a vista passar por cima da parede.
      expect(camera.position.y, greaterThan(BarracaoConfig.peDireito));
    });

    test('enquadra os 35 m inteiros na tela', () {
      const size = Size(400, 800);
      final camera = BarracaoScene.enquadrar(size);
      final env = BarracaoConfig.envelope;
      for (final x in [env.minX, env.maxX]) {
        for (final y in [env.minY, env.maxY]) {
          for (final z in [env.minZ, env.maxZ]) {
            final tela = _projetar(camera, size, Vec3(x, y, z));
            expect(tela, isNotNull,
                reason: 'canto ($x, $y, $z) atrás da câmera');
            expect(tela!.dx, inInclusiveRange(0, size.width));
            expect(tela.dy, inInclusiveRange(0, size.height));
          }
        }
      }
    });

    test('a tela deitada pede mais distância que a em pé', () {
      final emPe   = BarracaoScene.enquadrar(const Size(400, 800));
      final deitada = BarracaoScene.enquadrar(const Size(800, 400));
      // O barracão é um retângulo bem largo: na tela em pé a largura é o lado
      // apertado, então ela é a que precisa afastar mais.
      expect(emPe.dist, greaterThan(deitada.dist));
    });
  });

  group('página do barracão', () {
    /// Um catálogo curto, com dois produtos que a busca de dois termos
    /// distingue.
    const catalogo = [
      Produto(
          codigo: 'H1',
          nome: 'HERBICIDA BORAL 500 SC 20L',
          categoria: 'HERBICIDA',
          corHex: '#4caf50'),
      Produto(
          codigo: 'F1',
          nome: 'FUNGICIDA AZOX 200 1L',
          categoria: 'FUNGICIDA',
          corHex: '#4a93d8'),
    ];

    testWidgets('abre desenhando os endereços que recebeu', (tester) async {
      final enderecos = _enderecosPadrao();
      await tester.pumpWidget(MaterialApp(
        home: BarracaoPage(
          enderecosIniciais: enderecos,
          catalogoInicial:   catalogo,
        ),
      ));
      await tester.pump();

      expect(find.text('Barracão'), findsOneWidget);
      expect(
        find.text('${enderecos.length} paletes livres de ${enderecos.length}'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('o toque num palete abre o painel do endereço',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: BarracaoPage(
          enderecosIniciais: _enderecosPadrao(),
          catalogoInicial:   catalogo,
        ),
      ));
      await tester.pump();

      await _tocarNoPalete(tester, 'BAR-01');

      // O painel do galpão, com o rótulo do barracão.
      expect(find.text('BAR-01'), findsWidgets);
      expect(find.textContaining('Palete livre'), findsOneWidget);
      expect(find.textContaining('Buscar produto'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('buscar, atribuir e ver o produto no endereço',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: BarracaoPage(
          enderecosIniciais: _enderecosPadrao(),
          catalogoInicial:   catalogo,
        ),
      ));
      await tester.pump();
      await _tocarNoPalete(tester, 'BAR-01');

      // Busca inteligente: dois termos soltos, casando qualquer parte do nome.
      await tester.enterText(
          find.byType(TextField).first, 'boral 20');
      await tester.pump();
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);

      await tester.tap(find.text('HERBICIDA BORAL 500 SC 20L'));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, '45');
      await tester.pump();
      expect(find.text('Lançar em BAR-01'), findsOneWidget);

      await tester.tap(find.text('Lançar em BAR-01'));
      await tester.pump();

      // O painel fecha depois do lançamento e o contador acompanha.
      expect(find.textContaining('Buscar produto'), findsNothing);
      expect(find.textContaining('99 paletes livres'), findsOneWidget);

      // Reabrindo o endereço, o produto está lá.
      await _tocarNoPalete(tester, 'BAR-01');
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
      expect(find.text('cód. H1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('corrigir a quantidade não tira o produto do palete',
        (tester) async {
      final enderecos = _enderecosPadrao();
      enderecos[0] = enderecos[0].comProduto(
          produtoCodigo: 'H1',
          produtoNome:   'HERBICIDA BORAL 500 SC 20L',
          quantidade:    45);
      await tester.pumpWidget(MaterialApp(
        home: BarracaoPage(
          enderecosIniciais: enderecos,
          catalogoInicial:   catalogo,
        ),
      ));
      await tester.pump();
      await _tocarNoPalete(tester, 'BAR-01');

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Quantidade em BAR-01'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '57');
      await tester.pump();
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();

      // O painel continua aberto no mesmo endereço, com o número novo.
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
      expect(find.textContaining('57'), findsWidgets);
      expect(find.textContaining('99 paletes livres'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('0 no teclado de quantidade libera o palete', (tester) async {
      final enderecos = _enderecosPadrao();
      enderecos[0] = enderecos[0].comProduto(
          produtoCodigo: 'H1',
          produtoNome:   'HERBICIDA BORAL 500 SC 20L',
          quantidade:    45);
      await tester.pumpWidget(MaterialApp(
        home: BarracaoPage(
          enderecosIniciais: enderecos,
          catalogoInicial:   catalogo,
        ),
      ));
      await tester.pump();
      await _tocarNoPalete(tester, 'BAR-01');

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '0');
      await tester.pump();
      // Sem pilha, o aviso é o de endereço que fica livre — não o da descida
      // de racks, que é coisa do galpão.
      expect(find.textContaining('0 tira o palete de BAR-01'), findsOneWidget);
      expect(find.textContaining('descem um nível'), findsNothing);

      await tester.tap(find.text('Esvaziar'));
      await tester.pumpAndSettle();

      expect(find.textContaining('100 paletes livres'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Projeta um ponto do mundo na tela com a mesma conta da cena, ou null se ele
/// está atrás da câmera.
Offset? _projetar(Camera camera, Size size, Vec3 v) {
  final eye   = camera.position;
  final fwd   = (camera.target - eye).normalized;
  final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
  final up    = right.cross(fwd).normalized;
  const fovY  = 45.0 * math.pi / 180.0;
  final tanH   = math.tan(fovY / 2);
  final aspect = size.width / size.height;

  final d  = v - eye;
  final cz = d.dot(fwd);
  if (cz <= 0.1) return null;
  final cx = d.dot(right) / (cz * tanH * aspect);
  final cy = d.dot(up)    / (cz * tanH);
  return Offset((cx + 1) / 2 * size.width, (1 - cy) / 2 * size.height);
}

/// Toca o palete de [rotulo] na cena montada, mirando no centro do volume da
/// carga — o hit-test da cena é por raio, então o toque tem de sair de um
/// ponto de tela que realmente cruza a caixa do palete.
Future<void> _tocarNoPalete(WidgetTester tester, String rotulo) async {
  final cena = find.byType(BarracaoScene);
  final caixa = tester.getRect(cena);
  final camera = BarracaoScene.enquadrar(caixa.size);

  final posicao = BarracaoConfig.posicoesPadrao
      .firstWhere((p) => p.rotulo == rotulo);
  final alvo = _projetar(
    camera,
    caixa.size,
    Vec3(posicao.x, BarracaoConfig.alturaCarga / 2, posicao.z),
  );
  expect(alvo, isNotNull, reason: '$rotulo não está na tela');

  await tester.tapAt(caixa.topLeft + alvo!);
  await tester.pump();
}
