import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:three_js/three_js.dart' as three;
import 'package:three_js_geometry/three_js_geometry.dart';

class GondolaScene extends StatefulWidget {
  const GondolaScene({super.key});

  @override
  State<GondolaScene> createState() => _GondolaSceneState();
}

class _GondolaSceneState extends State<GondolaScene> {
  late three.ThreeJS threeJs;
  late three.OrbitControls controls;

  @override
  void initState() {
    super.initState();
    threeJs = three.ThreeJS(
      onSetupComplete: () { setState(() {}); },
      setup: _setup,
      settings: three.Settings(
        renderOptions: {
          "minFilter": three.LinearFilter,
          "magFilter": three.LinearFilter,
          "format": three.RGBAFormat,
          "samples": 4,
        },
      ),
    );
  }

  @override
  void dispose() {
    controls.dispose();
    threeJs.dispose();
    super.dispose();
  }

  void _setup() {
    // ── Cena ──
    threeJs.scene = three.Scene();
    threeJs.scene.background = three.Color.fromHex32(0x0e1014);

    // ── Câmera perspectiva fov=45 ──
    threeJs.camera = three.PerspectiveCamera(
      45,
      threeJs.width / threeJs.height,
      0.1,
      200,
    );
    threeJs.camera.position.setValues(0, 4.5, 14);

    // ── OrbitControls com damping — fluidez essencial no tablet ──
    controls = three.OrbitControls(threeJs.camera, threeJs.globalKey);
    controls.enableDamping = true;
    controls.dampingFactor = 0.05;
    controls.screenSpacePanning = false;
    controls.minDistance = 4;
    controls.maxDistance = 28;
    // Limita polar para não passar pelo chão nem ir ao zênite
    controls.maxPolarAngle = math.pi / 2;
    // Mira no centro vertical da gôndola
    controls.target.setValues(0, 1.7, 0);

    // ── Luzes ──
    threeJs.scene.add(three.AmbientLight(0xffffff, 0.55));

    final dirLight = three.DirectionalLight(0xffffff, 1.2);
    dirLight.position.setValues(5, 10, 7);
    threeJs.scene.add(dirLight);

    // luz de preenchimento azulada fraca para suavizar sombras
    final fillLight = three.DirectionalLight(0x4477aa, 0.3);
    fillLight.position.setValues(-4, 3, -4);
    threeJs.scene.add(fillLight);

    // ── Chão ──
    _montarChao();

    // ── Gôndola octogonal 3 andares ──
    _montarGondola();

    // ── Loop de animação — atualiza damping dos controles ──
    threeJs.addAnimationEvent((dt) {
      controls.update();
    });
  }

  void _montarChao() {
    // Disco escuro recebendo a gôndola
    final geoChao = CircleGeometry(9, 32);
    final matChao = three.MeshLambertMaterial.fromMap({'color': 0x12181e});
    final chao = three.Mesh(geoChao, matChao);
    chao.rotation.x = -math.pi / 2;
    chao.position.y = -0.002; // levemente abaixo do y=0 para evitar z-fighting
    threeJs.scene.add(chao);

    // GridHelper sutil
    final grid = GridHelper(18, 18, 0x1c2830, 0x1c2830);
    threeJs.scene.add(grid);
  }

  void _montarGondola() {
    // ── Paleta de cores CAMDA ──
    const corCorpo  = 0x2e6b46; // verde escuro — corpo das bandejas
    const corColuna = 0x1f4a30; // verde mais escuro — colunas e pés
    const corBorda  = 0x4a9d6a; // verde claro — bordas superiores

    // ── 8 pés cilíndricos na base, distribuídos em círculo (raio 2.8) ──
    final geoPe = CylinderGeometry(0.12, 0.12, 0.5, 6);
    final matPe = three.MeshPhongMaterial.fromMap({'color': corColuna});
    for (int i = 0; i < 8; i++) {
      final angulo = i * math.pi / 4;
      final pe = three.Mesh(geoPe, matPe);
      pe.position.setValues(
        2.8 * math.cos(angulo),
        0.25,
        2.8 * math.sin(angulo),
      );
      threeJs.scene.add(pe);
    }

    // ── Andar 1: base (raio 3.4) — sobre os pés ──
    _adicionarBandeja(
      raio: 3.4,
      altura: 0.35,
      yCentro: 0.675, // sobe 0.5 (pé) + 0.175 (metade da bandeja)
      corCorpo: corCorpo,
      corBorda: corBorda,
    );

    // coluna central: base → meio
    _adicionarColuna(yBase: 0.85, yTopo: 2.0, raio: 0.28, cor: corColuna);

    // ── Andar 2: meio (raio 2.4) ──
    _adicionarBandeja(
      raio: 2.4,
      altura: 0.30,
      yCentro: 2.15,
      corCorpo: corCorpo,
      corBorda: corBorda,
    );

    // coluna central: meio → topo
    _adicionarColuna(yBase: 2.30, yTopo: 3.30, raio: 0.28, cor: corColuna);

    // ── Andar 3: topo (raio 1.5) ──
    _adicionarBandeja(
      raio: 1.5,
      altura: 0.26,
      yCentro: 3.43,
      corCorpo: corCorpo,
      corBorda: corBorda,
    );
  }

  /// Bandeja octogonal (8 faces) com anel de acabamento no topo.
  /// Rotação PI/8 no Y alinha uma face plana para a frente.
  void _adicionarBandeja({
    required double raio,
    required double altura,
    required double yCentro,
    required int corCorpo,
    required int corBorda,
  }) {
    final mat     = three.MeshPhongMaterial.fromMap({'color': corCorpo});
    final matBord = three.MeshPhongMaterial.fromMap({'color': corBorda});

    // Prisma octogonal principal
    final geo  = CylinderGeometry(raio, raio, altura, 8);
    final mesh = three.Mesh(geo, mat);
    mesh.position.y = yCentro;
    mesh.rotation.y = math.pi / 8;
    threeJs.scene.add(mesh);

    // Anel de acabamento superior — levemente mais largo e mais claro
    final geoBorda = CylinderGeometry(raio + 0.13, raio + 0.13, 0.06, 8);
    final borda    = three.Mesh(geoBorda, matBord);
    borda.position.y = yCentro + altura / 2;
    borda.rotation.y = math.pi / 8;
    threeJs.scene.add(borda);
  }

  /// Coluna central octogonal conectando dois andares.
  void _adicionarColuna({
    required double yBase,
    required double yTopo,
    required double raio,
    required int cor,
  }) {
    final h   = yTopo - yBase;
    final geo = CylinderGeometry(raio, raio, h, 8);
    final mat = three.MeshPhongMaterial.fromMap({'color': cor});
    final col = three.Mesh(geo, mat);
    col.position.y = yBase + h / 2;
    threeJs.scene.add(col);
  }

  @override
  Widget build(BuildContext context) {
    return threeJs.build();
  }
}
