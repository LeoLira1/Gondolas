import 'dart:math' as math;
import 'dart:typed_data' show ByteData;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gondola_camda/galpao_scene.dart';
import 'package:gondola_camda/gondola_scene.dart' show Vec3, Camera, ProjecaoCamera;
import 'package:gondola_camda/textura_piso.dart';

// A textura do piso só é "do chão" se a matriz que a deforma for A MESMA
// projeção que desenha os racks. Estes testes conferem isso ponto a ponto: se
// alguém mexer na câmera, no fov ou na projeção da cena e esquecer daqui, a
// diferença aparece como um piso deslizando por baixo do galpão — que é
// exatamente o sintoma que uma imagem de fundo 2D produziria.

void main() {
  // O binding é preciso para o rootBundle achar o asset do bundle de teste.
  // Os testes que carregam ou rasterizam imagem são `test`, e não
  // `testWidgets`: dentro do relógio falso do testWidgets o callback do engine
  // (decode do PNG, Picture.toImage) nunca chega e o await fica pendurado.
  TestWidgetsFlutterBinding.ensureInitialized();

  const tamanho = Size(400, 720);

  /// As câmeras de teste: uma por combinação de giro, inclinação e distância
  /// que o galpão realmente usa (um dedo gira, dois dedos aproximam).
  final cameras = <Camera>[
    const Camera(rotY: 0, rotX: 0.9, dist: 30, target: Vec3(0, 0, 0)),
    const Camera(rotY: 0.7, rotX: 0.35, dist: 18, target: Vec3(2, 1.5, -3)),
    Camera(rotY: -2.1, rotX: 1.2, dist: 45, target: const Vec3(-5, 0, 8)),
    Camera(rotY: math.pi, rotX: 0.25, dist: 12, target: const Vec3(0, 2, 0)),
  ];

  group('matrizDoPlanoDoPiso', () {
    test('reproduz a projeção da cena em todo ponto do chão', () {
      for (final camera in cameras) {
        final proj = ProjecaoCamera(camera, tamanho);
        final m = matrizDoPlanoDoPiso(proj);

        for (var x = -20.0; x <= 20.0; x += 2.5) {
          for (var z = -20.0; z <= 20.0; z += 2.5) {
            final esperado = proj.projetar(Vec3(x, 0, z));
            if (esperado == null) continue; // atrás da câmera: recortado
            final obtido = aplicarMatrizDoPiso(m, x, z);
            expect(obtido.dx, closeTo(esperado.$1.dx, 1e-6),
                reason: 'x de tela em ($x, $z), rotY=${camera.rotY}');
            expect(obtido.dy, closeTo(esperado.$1.dy, 1e-6),
                reason: 'y de tela em ($x, $z), rotY=${camera.rotY}');
          }
        }
      }
    });

    test('acompanha o zoom: aproximar a câmera afasta dois pontos do chão', () {
      const perto = Camera(rotX: 0.6, dist: 10, target: Vec3(0, 0, 0));
      const longe = Camera(rotX: 0.6, dist: 40, target: Vec3(0, 0, 0));

      double vao(Camera c) {
        final m = matrizDoPlanoDoPiso(ProjecaoCamera(c, tamanho));
        return (aplicarMatrizDoPiso(m, 3, 0) - aplicarMatrizDoPiso(m, -3, 0))
            .distance;
      }

      expect(vao(perto), greaterThan(vao(longe) * 2));
    });

    test('acompanha o pan: mover o alvo desloca a textura junto', () {
      const a = Camera(rotX: 0.6, dist: 20, target: Vec3(0, 0, 0));
      const b = Camera(rotX: 0.6, dist: 20, target: Vec3(6, 0, 0));
      final ma = matrizDoPlanoDoPiso(ProjecaoCamera(a, tamanho));
      final mb = matrizDoPlanoDoPiso(ProjecaoCamera(b, tamanho));
      expect((aplicarMatrizDoPiso(ma, 0, 0) - aplicarMatrizDoPiso(mb, 0, 0))
          .distance, greaterThan(20));
    });

    test('é perspectiva de verdade: o ladrilho do fundo é menor que o da frente',
        () {
      // Com a câmera olhando ao longo de +Z, dois ladrilhos de mesmo tamanho no
      // mundo têm que projetar em alturas diferentes na tela. Numa imagem de
      // fundo 2D (ou num mapeamento afim) elas seriam iguais — este teste é o
      // que separa uma coisa da outra.
      const camera = Camera(rotY: 0, rotX: 0.5, dist: 25, target: Vec3(0, 0, 0));
      final m = matrizDoPlanoDoPiso(ProjecaoCamera(camera, tamanho));

      double alturaNaTela(double z) =>
          (aplicarMatrizDoPiso(m, 0, z + 6) - aplicarMatrizDoPiso(m, 0, z))
              .distance;

      final frente = alturaNaTela(6);   // perto da câmera
      final fundo  = alturaNaTela(-18); // longe dela
      expect(frente, greaterThan(fundo * 1.5));
    });
  });

  group('recortarPisoNoNear', () {
    test('devolve o retângulo inteiro com a câmera fora dele', () {
      const camera = Camera(rotX: 0.9, dist: 60, target: Vec3(0, 0, 0));
      final proj = ProjecaoCamera(camera, tamanho);
      final p = recortarPisoNoNear(proj, x0: -10, x1: 10, z0: -10, z1: 10);
      expect(p.length, 4);
    });

    test('corta o pedaço atrás da câmera em vez de espelhá-lo', () {
      // Câmera baixa e no meio do piso: metade do chão fica atrás dela. Sem o
      // recorte, essa metade atravessaria a divisão por w com sinal trocado e
      // reapareceria de cabeça para baixo no alto da tela.
      const camera = Camera(rotY: 0, rotX: 0.05, dist: 1, target: Vec3(0, 1, 0));
      final proj = ProjecaoCamera(camera, tamanho);
      final p = recortarPisoNoNear(proj, x0: -30, x1: 30, z0: -30, z1: 30);

      expect(p, isNotEmpty);
      expect(p.length, lessThanOrEqualTo(5));
      for (final v in p) {
        final profundidade = proj.profundidade(Vec3(v.dx, 0, v.dy));
        expect(profundidade, greaterThanOrEqualTo(ProjecaoCamera.near - 1e-9),
            reason: 'vértice $v ficou atrás do near plane');
      }
    });

    test('devolve vazio quando o piso inteiro está atrás da câmera', () {
      // Olhando para longe do retângulo, que fica todo às costas da câmera.
      const camera =
          Camera(rotY: 0, rotX: 0.1, dist: 5, target: Vec3(0, 1.5, 200));
      final proj = ProjecaoCamera(camera, tamanho);
      final p = recortarPisoNoNear(proj, x0: -10, x1: 10, z0: 300, z1: 320);
      expect(p.length, lessThan(3));
    });
  });


  // ── O concreto chega mesmo à tela? ─────────────────────────────────────────
  //
  // Os testes acima provam a MATEMÁTICA. Estes rasterizam a cena de verdade e
  // leem os pixels: é o que separa "a matriz está certa" de "o piso apareceu".

  group('GalpaoPainter com a textura', () {
    const tela = Size(400, 720);

    /// Rasteriza a cena e devolve os pixels em RGBA.
    Future<ByteData> pintar(GalpaoPainter painter) async {
      final rec = ui.PictureRecorder();
      painter.paint(Canvas(rec), tela);
      final img = await rec
          .endRecording()
          .toImage(tela.width.round(), tela.height.round());
      final px = await img.toByteData();
      img.dispose();
      return px!;
    }

    int pixel(ByteData px, double x, double y) =>
        px.getUint32(((y.round() * tela.width.round()) + x.round()) * 4);

    /// O galpão com o MAPA DESLIGADO — nenhuma rua visível, nenhuma etiqueta —,
    /// para o que sobra na tela ser só o piso. É o que permite ler o pixel do
    /// chão sem a sorte de não cair num contorno de vaga ou num número de
    /// posição, que cobrem boa parte do meio da tela num galpão vazio.
    GalpaoPainter soPiso(Camera camera, {ui.Image? textura}) => GalpaoPainter(
          camera,
          parte:            1,
          ruasVisiveis:     const <int>{},
          mostrarEtiquetas: false,
          texturaPiso:      textura,
        );

    /// Uma grade de pontos no meio da tela, onde o chão da parte 1 aparece.
    Iterable<Offset> amostras() sync* {
      for (var x = 60.0; x < 340; x += 8) {
        for (var y = 300.0; y < 460; y += 8) {
          yield Offset(x, y);
        }
      }
    }

    test('pinta concreto no chão, e não o fundo chapado da cena',
        () async {
      await TexturaPiso.carregar();
      final textura = TexturaPiso.imagem.value!;
      final camera = GalpaoScene.enquadrar(tela, parte: 1);

      final px = await pintar(soPiso(camera, textura: textura));

      // Cinza de concreto: canais próximos entre si e claramente acima do fundo
      // 0xFF0b0c0e da cena. A maioria esmagadora dos pontos tem de passar.
      var concreto = 0, total = 0;
      for (final p in amostras()) {
        total++;
        final c = pixel(px, p.dx, p.dy);
        final r = (c >> 24) & 0xFF, g = (c >> 16) & 0xFF, b = (c >> 8) & 0xFF;
        if (r > 40 && (r - g).abs() < 24 && (g - b).abs() < 24) concreto++;
      }
      expect(concreto / total, greaterThan(0.9),
          reason: 'só $concreto de $total pontos do chão são concreto');
    });

    test('sem a textura, o piso cai no fallback e a cena não quebra',
        () async {
      final camera = GalpaoScene.enquadrar(tela, parte: 1);
      final px = await pintar(soPiso(camera));

      // Fundo 0xFF0b0c0e com 5% de branco por cima: continua quase preto.
      var escuros = 0, total = 0;
      for (final p in amostras()) {
        total++;
        if (((pixel(px, p.dx, p.dy) >> 24) & 0xFF) < 60) escuros++;
      }
      expect(escuros / total, greaterThan(0.9),
          reason: 'sem textura o piso deveria continuar quase preto');
    });

    test('a textura gira com a câmera (não é um fundo 2D)',
        () async {
      await TexturaPiso.carregar();
      final textura = TexturaPiso.imagem.value!;
      final base = GalpaoScene.enquadrar(tela, parte: 1);

      final a = await pintar(soPiso(base, textura: textura));
      final b = await pintar(
          soPiso(base.copyWith(rotY: base.rotY + 0.6), textura: textura));

      // Um fundo 2D daria pixels idênticos no chão depois de girar a câmera.
      var diferentes = 0, total = 0;
      for (final p in amostras()) {
        total++;
        if (pixel(a, p.dx, p.dy) != pixel(b, p.dx, p.dy)) diferentes++;
      }
      expect(diferentes / total, greaterThan(0.5),
          reason: 'o chão mal mudou ao girar: a textura não está no plano 3D');
    });

    test('não constrói shader nem decodifica imagem por frame', () async {
      await TexturaPiso.carregar();
      final textura = TexturaPiso.imagem.value!;
      final base = GalpaoScene.enquadrar(tela, parte: 1);

      // Aquece: o primeiro paint é quem tem direito a construir o shader.
      await pintar(soPiso(base, textura: textura));
      final antes = TexturaPiso.shadersCriados;

      // 30 frames de um arrasto de câmera — o caso em que um decode ou um
      // shader por frame apareceria como engasgo na tela.
      for (var i = 1; i <= 30; i++) {
        await pintar(
            soPiso(base.copyWith(rotY: base.rotY + i * 0.02), textura: textura));
      }
      expect(TexturaPiso.shadersCriados, antes,
          reason: 'o shader do concreto está sendo reconstruído a cada paint');
    });

    test('a textura acompanha o zoom (não fica presa à tela)',
        () async {
      await TexturaPiso.carregar();
      final textura = TexturaPiso.imagem.value!;
      final base = GalpaoScene.enquadrar(tela, parte: 1);

      final a = await pintar(soPiso(base, textura: textura));
      final b = await pintar(
          soPiso(base.copyWith(dist: base.dist * 0.6), textura: textura));

      var diferentes = 0, total = 0;
      for (final p in amostras()) {
        total++;
        if (pixel(a, p.dx, p.dy) != pixel(b, p.dx, p.dy)) diferentes++;
      }
      expect(diferentes / total, greaterThan(0.5),
          reason: 'o chão mal mudou no zoom: a textura não está no plano 3D');
    });
  });

  group('TexturaPiso', () {
    test('carrega o asset uma vez e publica a imagem decodificada',
        () async {
      await TexturaPiso.carregar();
      final img = TexturaPiso.imagem.value;
      expect(img, isNotNull,
          reason: 'assets/textures/galpao_concreto.png não entrou no bundle');
      expect(img!.width, greaterThan(0));
      expect(img.height, greaterThan(0));

      // Segunda chamada não redecodifica: é a MESMA ui.Image.
      await TexturaPiso.carregar();
      expect(identical(TexturaPiso.imagem.value, img), isTrue);
    });
  });
}
