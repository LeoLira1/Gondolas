import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'gondola_scene.dart'
    show Vec3, Camera, Face, addBadgeEnderecoDesatualizado, corEnderecoDivergente,
        corEnderecoDivergentePositiva;
import 'models.dart'
    show CaixaColocadaEstante, chaveEnderecoEstoque, corConferenciaCiano,
         expositorMonitorNum, letraEstanteCelula;
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Expositor Monitor Produtos Agropecuários — estrutura escalonada: laterais
// amarelas cujos painéis têm a frente inclinada (fundos embaixo, rasos em
// cima — prismas, não caixas retas), painel slatwall branco vertical ao
// fundo, testeira branca com trim amarelo e logo Monitor (círculo azul com M
// + "MONITOR / PRODUTOS AGROPECUÁRIOS"), 3 prateleiras brancas com borda
// frontal amarela e profundidade crescente de cima pra baixo, e base amarela
// com deck branco que também recebe produtos.
//
// São 20 endereços em 4 níveis × 5 colunas, slot = 0 sempre, reaproveitando
// o esquema (coluna, nivel, slot) do estante_layout na Turso como "estante"
// nº expositorMonitorNum:
//   nível 0 = base (deck, o mais fundo) — rotulada com números 1–5
//   nível 1 = prateleira inferior       — letras K–O
//   nível 2 = prateleira média          — letras F–J
//   nível 3 = prateleira superior       — letras A–E (a mais rasa)
//
// Todos os níveis são superfícies de apoio (sem ganchos): empilham caixas
// como nas estantes comuns, com o nº de fileiras em profundidade acompanhando
// a profundidade do nível — a base comporta mais fileiras que a prateleira
// superior.
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMonitorCell {
  final int    coluna;
  final int    nivel;      // 0 = base (deck), 3 = prateleira superior
  final double xCenter;    // centro da coluna em X
  final double ySurface;   // piso de apoio do nível

  const ExpositorMonitorCell({
    required this.coluna,
    required this.nivel,
    required this.xCenter,
    required this.ySurface,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorMonitorGeometry — base + laterais inclinadas + painel + prateleiras
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMonitorGeometry {
  final double width;      // largura total (m)
  final double height;     // altura das laterais/painel (sem testeira)
  final bool   showFloor;

  const ExpositorMonitorGeometry({
    this.width     = 1.14,
    this.height    = 1.52,
    this.showFloor = true,
  });

  static const int niveis  = 4;
  static const int colunas = 5;

  // Altura total incluindo a testeira e o trim (usada pra centrar a câmera).
  double get alturaTotal => height + _testeiraH + _trimT + 0.02;

  // ── Dimensões dos produtos (caixas apoiadas) ───────────────────────────────
  static const double wCaixa      = 0.16;
  static const double hCaixa      = 0.16;
  static const double dCaixa      = 0.15;
  static const double _gapFileira = 0.02;  // vão entre fileiras em profundidade

  // ── Estrutura (proporções do expositor real / preview HTML da raiz) ────────
  static const double _baseH    = 0.12;   // rodapé amarelo
  static const double _deckT    = 0.022;  // deck branco sobre o rodapé
  static const double _baseZ0   = -0.23;  // fundo da base
  static const double _baseZ1   =  0.39;  // frente da base (nível mais fundo)
  static const double _lateralW = 0.04;   // espessura das laterais amarelas
  static const double _latZBaixo = 0.36;  // frente da lateral embaixo (funda)
  static const double _latZCima  = -0.08; // frente da lateral em cima (rasa)
  static const double _latZFundo = -0.22; // fundo das laterais
  static const double _painelT  = 0.025;  // espessura do painel slatwall
  static const double _painelZ  = -0.19;  // centro do painel em Z
  static const double _ranhuraH   = 0.009; // altura da ranhura (canaleta)
  static const double _ranhuraGap = 0.10;  // passo entre ranhuras
  static const double _shelfT   = 0.02;   // espessura da prateleira
  static const double _shelfZ0  = -0.18;  // fundo das prateleiras
  static const double _bordaH   = 0.045;  // borda frontal amarela
  static const double _testeiraH  = 0.28; // altura da testeira branca
  static const double _testeiraZ0 = -0.20;
  static const double _testeiraZ1 = -0.04;
  static const double _trimT    = 0.03;   // trim amarelo no topo da testeira

  // ── Paleta (da foto do expositor real) ─────────────────────────────────────
  static const _amarelo    = Color(0xFFf5b90a);  // amarelo Monitor
  static const _amareloEsc = Color(0xFFcf9a06);  // sombra do trim
  static const _branco     = Color(0xFFf2f0ec);  // painel, prateleiras, deck
  static const _ranhura    = Color(0xFFc4c1ba);  // sombra da canaleta
  static const _floor      = Color(0xFF12161d);

  // Azul do círculo do logo Monitor na testeira.
  static const corAzulMonitor = Color(0xFF1565c0);

  // Frente de cada nível em Z — profundidade crescente de cima pra baixo:
  // a base é a mais funda e a prateleira superior a mais rasa.
  static const List<double> _zFrentePorNivel = [0.36, 0.24, 0.14, 0.04];

  // Y da superfície de apoio do nível (deck ou topo da prateleira). Frações
  // da altura calibradas pelo preview: prateleiras a 33%, 58% e 83%.
  double nivelY(int nivel) => switch (nivel) {
        0 => _baseH + _deckT,
        1 => height * 0.33,
        2 => height * 0.58,
        _ => height * 0.83,
      };

  double zFrenteNivel(int nivel) => _zFrentePorNivel[nivel];

  // Fundo útil do nível em Z (onde encosta a última fileira de caixas).
  double _zFundoNivel(int nivel) => nivel == 0 ? _baseZ0 + 0.03 : _shelfZ0;

  /// Fileiras de caixas que cabem na profundidade útil do nível: 3 na base,
  /// 2 nas prateleiras inferior/média, 1 na superior (a mais rasa).
  int fileirasNivel(int nivel) {
    final prof = zFrenteNivel(nivel) - _zFundoNivel(nivel);
    return math.max(1, (prof + _gapFileira) ~/ (dCaixa + _gapFileira));
  }

  // X do centro da coluna c — 5 colunas na largura útil entre as laterais.
  double colunaX(int c) {
    final util = width - (_lateralW + 0.03) * 2 - wCaixa;
    final xMin = -util / 2;
    return colunas > 1 ? xMin + util * c / (colunas - 1) : 0;
  }

  List<ExpositorMonitorCell> get cells => [
        for (var niv = 0; niv < niveis; niv++)
          for (var col = 0; col < colunas; col++)
            ExpositorMonitorCell(
              coluna:   col,
              nivel:    niv,
              xCenter:  colunaX(col),
              ySurface: nivelY(niv),
            ),
      ];

  // ── Caixas apoiadas — fileiras em profundidade conforme o nível ────────────
  void addCaixaProduto(
    List<Face> faces, {
    required ExpositorMonitorCell celula,
    required Color color,
    bool desatualizado = false,
  }) {
    final xc = celula.xCenter;
    final y0 = celula.ySurface;
    final zF = zFrenteNivel(celula.nivel) - 0.01;
    final n  = fileirasNivel(celula.nivel);
    for (var fila = 0; fila < n; fila++) {
      final z1 = zF - fila * (dCaixa + _gapFileira);
      _box(faces,
        x0: xc - wCaixa / 2, x1: xc + wCaixa / 2,
        y0: y0,               y1: y0 + hCaixa,
        z0: z1 - dCaixa,      z1: z1,
        color: color);
    }
    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces,
          x1: xc + wCaixa / 2, y1: y0 + hCaixa, z1: zF, tamanho: wCaixa * 0.45);
    }
  }

  List<Face> buildFaces() {
    final faces = <Face>[];

    if (showFloor) {
      const s = 2.5;
      faces.add(Face([
        Vec3(-s, -0.001, -s), Vec3(-s, -0.001,  s),
        Vec3( s, -0.001,  s), Vec3( s, -0.001, -s),
      ], _floor));
    }

    final hw = width / 2;

    // ── Base: rodapé amarelo + deck branco (nível 0) ───────────────────────
    _box(faces,
      x0: -hw,     x1: hw,
      y0: 0,       y1: _baseH,
      z0: _baseZ0, z1: _baseZ1,
      color: _amarelo);
    _box(faces,
      x0: -hw + _lateralW, x1: hw - _lateralW,
      y0: _baseH,           y1: _baseH + _deckT,
      z0: _baseZ0 + 0.03,   z1: _baseZ1 - 0.03,
      color: _branco);

    // ── Laterais amarelas com a frente inclinada (prismas) ─────────────────
    // Fundas embaixo (z = _latZBaixo) e rasas em cima (z = _latZCima),
    // acompanhando o escalonamento das prateleiras.
    for (final sinal in [-1.0, 1.0]) {
      final xInt = sinal * (hw - _lateralW);
      final xExt = sinal * hw;
      _prismaLateral(faces,
        x0: math.min(xInt, xExt), x1: math.max(xInt, xExt),
        y0: _baseH,                y1: height,
        zFrenteBaixo: _latZBaixo,  zFrenteCima: _latZCima,
        zFundo: _latZFundo,
        color: _amarelo);
    }

    // ── Painel slatwall branco vertical ao fundo ───────────────────────────
    _box(faces,
      x0: -hw + _lateralW,        x1: hw - _lateralW,
      y0: _baseH,                  y1: height,
      z0: _painelZ - _painelT / 2, z1: _painelZ + _painelT / 2,
      color: _branco);

    // Ranhuras horizontais do slatwall — tiras finas levemente à frente do
    // painel pra vencer o depth-sort.
    var y = _baseH + _deckT + _ranhuraGap;
    while (y < height - 0.05) {
      final zR = _painelZ + _painelT / 2 + 0.002;
      faces.add(Face([
        Vec3(-hw + _lateralW, y,             zR),
        Vec3( hw - _lateralW, y,             zR),
        Vec3( hw - _lateralW, y + _ranhuraH, zR),
        Vec3(-hw + _lateralW, y + _ranhuraH, zR),
      ], _ranhura));
      y += _ranhuraGap;
    }

    // ── Prateleiras brancas com borda amarela (níveis 1–3) ─────────────────
    for (final niv in [1, 2, 3]) {
      final ys = nivelY(niv);
      final zF = zFrenteNivel(niv);
      _box(faces,
        x0: -hw + _lateralW + 0.03, x1: hw - _lateralW - 0.03,
        y0: ys - _shelfT,            y1: ys,
        z0: _shelfZ0,                z1: zF,
        color: _branco);
      // Borda amarela frontal
      _box(faces,
        x0: -hw + _lateralW + 0.03, x1: hw - _lateralW - 0.03,
        y0: ys - _bordaH,            y1: ys + 0.005,
        z0: zF,                      z1: zF + 0.014,
        color: _amarelo);
    }

    // ── Testeira branca com trim amarelo (logo desenhado no painter) ───────
    _box(faces,
      x0: -hw + _lateralW, x1: hw - _lateralW,
      y0: height,           y1: height + _testeiraH,
      z0: _testeiraZ0,      z1: _testeiraZ1,
      color: _branco);
    // Trim amarelo no topo
    _box(faces,
      x0: -hw + 0.02,             x1: hw - 0.02,
      y0: height + _testeiraH,     y1: height + _testeiraH + _trimT,
      z0: _testeiraZ0 - 0.01,      z1: _testeiraZ1 + 0.01,
      color: _amarelo);
    // Trims amarelos laterais da testeira
    for (final sinal in [-1.0, 1.0]) {
      final xA = sinal * (hw - 0.005);
      final xB = sinal * (hw - _lateralW - 0.005);
      _box(faces,
        x0: math.min(xA, xB),   x1: math.max(xA, xB),
        y0: height - 0.02,      y1: height + _testeiraH + _trimT,
        z0: _testeiraZ0 - 0.01, z1: _testeiraZ1 + 0.01,
        color: _amareloEsc);
    }

    return faces;
  }

  // Prisma da lateral: caixa cuja face frontal é inclinada (mais funda
  // embaixo, mais rasa em cima). Sem a face de baixo (encostada na base).
  static void _prismaLateral(List<Face> faces, {
    required double x0, required double x1,
    required double y0, required double y1,
    required double zFrenteBaixo, required double zFrenteCima,
    required double zFundo, required Color color,
  }) {
    final v = [
      Vec3(x0, y0, zFrenteBaixo), Vec3(x1, y0, zFrenteBaixo),
      Vec3(x1, y1, zFrenteCima),  Vec3(x0, y1, zFrenteCima),
      Vec3(x0, y0, zFundo),       Vec3(x1, y0, zFundo),
      Vec3(x1, y1, zFundo),       Vec3(x0, y1, zFundo),
    ];
    const idx = [
      [0, 1, 2, 3],  // frente inclinada
      [5, 4, 7, 6],  // fundo
      [4, 0, 3, 7],  // lado esquerdo
      [1, 5, 6, 2],  // lado direito
      [3, 2, 6, 7],  // topo
    ];
    for (final f in idx) {
      faces.add(Face([for (final i in f) v[i]], color));
    }
  }

  static void _box(List<Face> faces, {
    required double x0, required double x1,
    required double y0, required double y1,
    required double z0, required double z1,
    required Color color,
  }) {
    faces.add(Face([Vec3(x0,y1,z0), Vec3(x0,y1,z1), Vec3(x1,y1,z1), Vec3(x1,y1,z0)], color));
    faces.add(Face([Vec3(x0,y0,z1), Vec3(x1,y0,z1), Vec3(x1,y1,z1), Vec3(x0,y1,z1)], color));
    faces.add(Face([Vec3(x1,y0,z0), Vec3(x0,y0,z0), Vec3(x0,y1,z0), Vec3(x1,y1,z0)], color));
    faces.add(Face([Vec3(x1,y0,z1), Vec3(x1,y0,z0), Vec3(x1,y1,z0), Vec3(x1,y1,z1)], color));
    faces.add(Face([Vec3(x0,y0,z0), Vec3(x0,y0,z1), Vec3(x0,y1,z1), Vec3(x0,y1,z0)], color));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorMonitorPainter
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMonitorPainter extends CustomPainter {
  final Camera                    camera;
  final ExpositorMonitorGeometry  geometry;
  final bool                      wireframe;
  final bool                      showLabels;
  final List<Face>                extraFaces;

  static final Vec3 _lightDir = Vec3(4, 10, 5).normalized;

  const ExpositorMonitorPainter(this.camera, this.geometry, {
    this.wireframe  = false,
    this.showLabels = true,
    this.extraFaces = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size,
        Paint()..color = const Color(0xFF0e1116));

    final faces = geometry.buildFaces()..addAll(extraFaces);
    _project(faces, size);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
    _drawMarca(canvas, size);
    if (showLabels) _drawLabels(canvas, size);
  }

  (Offset, double)? _projectPoint(Vec3 v, Size size) {
    final eye    = camera.position;
    final fwd    = (camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 42.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;

    final d  = v - eye;
    final cz = d.dot(fwd);
    if (cz <= 0.01) return null;
    final cx = d.dot(right) / (cz * tanH * aspect);
    final cy = d.dot(up)    / (cz * tanH);
    return (
      Offset((cx + 1) / 2 * size.width, (1 - cy) / 2 * size.height),
      cz,
    );
  }

  void _project(List<Face> faces, Size size) {
    final eye    = camera.position;
    final fwd    = (camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 42.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;
    final w = size.width, h = size.height;

    Offset project(Vec3 v) {
      final d  = v - eye;
      final cz = d.dot(fwd);
      if (cz <= 0.01) return const Offset(-9999, -9999);
      final cx = d.dot(right) / (cz * tanH * aspect);
      final cy = d.dot(up)    / (cz * tanH);
      return Offset((cx + 1) / 2 * w, (1 - cy) / 2 * h);
    }

    for (final f in faces) {
      f.proj = f.verts.map(project).toList();
      if (f.proj.any((p) => p.dx < -9990)) {
        f.proj  = const [];
        f.depth = -1e9;
        continue;
      }
      f.depth = f.verts.fold(0.0, (s, v) => s + (v - eye).dot(fwd)) /
          f.verts.length;
      if (f.verts.length >= 3) {
        final n = (f.verts[1] - f.verts[0])
            .cross(f.verts[2] - f.verts[0])
            .normalized;
        f.light = 0.35 + 0.65 * n.dot(_lightDir).clamp(0.0, 1.0);
      }
    }
  }

  void _draw(Canvas canvas, List<Face> faces) {
    final fill   = Paint();
    final stroke = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = wireframe ? 1.0 : 0.5;

    for (final f in faces) {
      if (f.proj.isEmpty) continue;
      final path = Path()..moveTo(f.proj[0].dx, f.proj[0].dy);
      for (var i = 1; i < f.proj.length; i++) {
        path.lineTo(f.proj[i].dx, f.proj[i].dy);
      }
      path.close();

      if (wireframe) {
        stroke.color = f.color.withAlpha(200);
        canvas.drawPath(path, stroke);
      } else {
        fill.color = Color.lerp(Colors.black, f.color, f.light)!;
        canvas.drawPath(path, fill);
        stroke.color = const Color(0x44000000);
        canvas.drawPath(path, stroke);
      }
    }
  }

  // Logo Monitor na testeira — texto 2D projetado em cima do 3D, mesma
  // técnica dos labels: círculo azul com "M" + "MONITOR" e "PRODUTOS
  // AGROPECUÁRIOS" ao lado. Só desenha com a testeira de frente pra câmera.
  void _drawMarca(Canvas canvas, Size size) {
    if (camera.position.z <= 0.3) return;

    final g   = geometry;
    final yC  = g.height + ExpositorMonitorGeometry._testeiraH * 0.5;
    const zC  = ExpositorMonitorGeometry._testeiraZ1 + 0.01;

    final hit = _projectPoint(Vec3(0, yC, zC), size);
    if (hit == null) return;
    final (screen, cz) = hit;

    final s = (2.6 / cz).clamp(0.4, 1.6);

    // "MONITOR" + subtítulo, com o círculo azul à esquerda
    final tpNome = TextPainter(
      text: TextSpan(
        text: 'MONITOR',
        style: TextStyle(
          color:      const Color(0xFF1a1a1a),
          fontSize:   20.0 * s,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5 * s,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final tpSub = TextPainter(
      text: TextSpan(
        text: 'PRODUTOS AGROPECUÁRIOS',
        style: TextStyle(
          color:      const Color(0xE6303030),
          fontSize:   7.0 * s,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final raio    = 13.0 * s;
    final gap     = 8.0 * s;
    final largura = raio * 2 + gap + math.max(tpNome.width, tpSub.width);
    final xIni    = screen.dx - largura / 2;

    // Círculo azul com M
    final cCirc = Offset(xIni + raio, screen.dy);
    canvas.drawCircle(cCirc, raio,
        Paint()..color = ExpositorMonitorGeometry.corAzulMonitor);
    final tpM = TextPainter(
      text: TextSpan(
        text: 'M',
        style: TextStyle(
          color:      Colors.white,
          fontSize:   16.0 * s,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tpM.paint(canvas, cCirc - Offset(tpM.width / 2, tpM.height / 2));

    // Texto à direita do círculo
    final xTexto = xIni + raio * 2 + gap;
    tpNome.paint(canvas,
        Offset(xTexto, screen.dy - tpNome.height + 2.0 * s));
    tpSub.paint(canvas, Offset(xTexto, screen.dy + 2.0 * s));
  }

  void _drawLabels(Canvas canvas, Size size) {
    const camda   = Color(0xFFe87722);
    const bgColor = Color(0xC70b0c0e);

    final bgPaint  = Paint()..color = bgColor;
    final rimPaint = Paint()
      ..color       = camda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final c in geometry.cells) {
      final hit = _projectPoint(
          Vec3(c.xCenter, c.ySurface + 0.055,
               geometry.zFrenteNivel(c.nivel) + 0.02),
          size);
      if (hit == null) continue;

      final (screen, cz) = hit;
      final fontSize = 14.0 * (3.2 / cz).clamp(0.5, 1.6);
      final radius   = fontSize * 0.72;

      canvas.drawCircle(screen, radius, bgPaint);
      canvas.drawCircle(screen, radius, rimPaint);

      // Nível 0 mostra números 1–5; níveis 1–3 letras contínuas de cima pra
      // baixo (A–E, F–J, K–O) — mesma regra de letraEstanteCelula.
      final rotulo = letraEstanteCelula(expositorMonitorNum, c.coluna, c.nivel);
      final tp = TextPainter(
        text: TextSpan(
          text: rotulo,
          style: TextStyle(
            color:      camda,
            fontSize:   fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(ExpositorMonitorPainter old) =>
      old.camera.rotY        != camera.rotY        ||
      old.camera.rotX        != camera.rotX        ||
      old.camera.dist        != camera.dist        ||
      old.wireframe          != wireframe          ||
      old.showLabels         != showLabels         ||
      old.extraFaces         != extraFaces         ||
      old.geometry.width     != geometry.width     ||
      old.geometry.height    != geometry.height    ||
      old.geometry.showFloor != geometry.showFloor;
}

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorMonitorScene — 3D interativo com suporte a produtos
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMonitorScene extends StatefulWidget {
  final ExpositorMonitorGeometry geometry;
  final bool                     wireframe;
  final bool                     autoRotate;
  final bool                     showLabels;
  // Reutiliza CaixaColocadaEstante: coluna = coluna, nivel = nível (0 = base,
  // 3 = prateleira superior), slot = 0 sempre (um produto por endereço).
  final List<CaixaColocadaEstante> caixas;
  final String?                    produtoSelecionadoId;
  final Map<String, Color>         corPorProduto;
  final void Function(int coluna, int nivel)? onTapCelula;
  final void Function(int coluna, int nivel)? onTapCelulaVisualizar;
  final String?                    destacadoCodigo;
  final Set<String>                desatualizados;
  final Set<String>                divergentes;
  final Set<String>                divergentesPositivas;
  final Set<String>                destacadosCodigos;

  const ExpositorMonitorScene({
    super.key,
    required this.geometry,
    this.wireframe            = false,
    this.autoRotate           = true,
    this.showLabels           = true,
    this.caixas               = const [],
    this.produtoSelecionadoId,
    this.corPorProduto        = const {},
    this.onTapCelula,
    this.onTapCelulaVisualizar,
    this.destacadoCodigo,
    this.desatualizados       = const {},
    this.divergentes          = const {},
    this.divergentesPositivas = const {},
    this.destacadosCodigos    = const {},
  });

  @override
  State<ExpositorMonitorScene> createState() =>
      _ExpositorMonitorSceneState();
}

class _ExpositorMonitorSceneState extends State<ExpositorMonitorScene>
    with SingleTickerProviderStateMixin, SceneGestureGuard<ExpositorMonitorScene> {
  late Ticker _ticker;
  late Camera _camera;

  final _painterKey = GlobalKey();
  Camera? _cameraAtStart;

  @override
  void initState() {
    super.initState();
    _camera = Camera(
      rotY:   0.35,
      rotX:   0.18,
      dist:   3.4,
      target: Vec3(0, widget.geometry.alturaTotal / 2, 0),
    );
    _ticker = createTicker((_) {
      if (widget.autoRotate) {
        setState(() => _camera = _camera.copyWith(rotY: _camera.rotY + 0.0025));
      }
    })..start();
  }

  @override
  void didUpdateWidget(ExpositorMonitorScene old) {
    super.didUpdateWidget(old);
    if (old.geometry.height != widget.geometry.height) {
      _camera = Camera(
        rotY:   _camera.rotY,
        rotX:   _camera.rotX,
        dist:   _camera.dist,
        target: Vec3(0, widget.geometry.alturaTotal / 2, 0),
      );
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onScaleStart(ScaleStartDetails d) {
    beginGesture(d);
    _cameraAtStart = _camera;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final origin = gestureOrigin;
    final c0     = _cameraAtStart;
    if (origin == null || c0 == null) return;

    if (reanchorIfPointersChanged(d)) {
      _cameraAtStart = _camera;
      return;
    }
    markDragIfMoved(d);

    final delta = d.focalPoint - origin;
    setState(() {
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.008,
        rotX: (c0.rotX + delta.dy * 0.008).clamp(-0.1, math.pi / 2 - 0.05),
        dist: (c0.dist / d.scale).clamp(1.2, 8.0),
      );
    });
  }

  void _tryFireTap(Offset globalTap) {
    final rb = _painterKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final hit = _hitTest(rb.globalToLocal(globalTap), rb.size);
    if (hit == null) return;
    if (widget.produtoSelecionadoId != null) {
      widget.onTapCelula?.call(hit.coluna, hit.nivel);
    } else {
      widget.onTapCelulaVisualizar?.call(hit.coluna, hit.nivel);
    }
  }

  // Hit-test: cada nível tem seu próprio plano frontal (a base avança mais
  // que as prateleiras, que avançam mais quanto mais baixas), então o raio
  // do toque é intersectado plano a plano e testado contra a área clicável
  // das células daquele nível.
  ({int coluna, int nivel})? _hitTest(Offset tap, Size size) {
    final eye    = _camera.position;
    final fwd    = (_camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 42.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;

    final ndcX = 2 * tap.dx / size.width  - 1;
    final ndcY = 1 - 2 * tap.dy / size.height;

    final dir = (right * (ndcX * tanH * aspect) +
                 up    * (ndcY * tanH) +
                 fwd).normalized;
    if (dir.z.abs() < 1e-6) return null;

    // Meia-largura clicável da coluna — metade do passo entre colunas,
    // pra não sobrepor a vizinha.
    final hwCelula =
        (widget.geometry.colunaX(1) - widget.geometry.colunaX(0)) / 2 - 0.005;

    ({int coluna, int nivel, double d2})? nearest;
    for (final c in widget.geometry.cells) {
      final zPlano = widget.geometry.zFrenteNivel(c.nivel);
      final t = (zPlano - eye.z) / dir.z;
      if (t <= 0.1) continue;
      final hx = eye.x + t * dir.x;
      final hy = eye.y + t * dir.y;

      final yMin = c.ySurface - 0.05;
      final yMax = c.ySurface + ExpositorMonitorGeometry.hCaixa + 0.06;

      if ((hx - c.xCenter).abs() > hwCelula) continue;
      if (hy < yMin || hy > yMax) continue;

      final dx = hx - c.xCenter;
      final dy = hy - (yMin + yMax) / 2;
      final d2 = dx * dx + dy * dy;
      if (nearest == null || d2 < nearest.d2) {
        nearest = (coluna: c.coluna, nivel: c.nivel, d2: d2);
      }
    }

    return nearest == null
        ? null
        : (coluna: nearest.coluna, nivel: nearest.nivel);
  }

  @override
  Widget build(BuildContext context) {
    final extraFaces = <Face>[];
    for (final caixa in widget.caixas) {
      final isConferencia = widget.destacadosCodigos.contains(caixa.produtoId);
      final isHighlighted = caixa.produtoId == widget.destacadoCodigo;
      final celulaList = widget.geometry.cells
          .where((c) => c.coluna == caixa.coluna && c.nivel == caixa.nivel)
          .toList();
      if (celulaList.isEmpty) continue;
      final chave = chaveEnderecoEstoque(
        produtoCodigo: caixa.produtoId,
        localTipo:     'estante',
        localNum:      expositorMonitorNum,
        faceOuColuna:  caixa.coluna,
        andarOuNivel:  caixa.nivel,
      );
      // Divergência de contagem pinta a caixa inteira: azul escuro quando é
      // positiva (contado > sistema), vermelho nas demais. Destaques de
      // conferência e busca (momentâneos) têm prioridade sobre ela.
      final isDivergente = widget.divergentes.contains(chave);
      final isDivergentePositiva = widget.divergentesPositivas.contains(chave);
      final cor = isConferencia
          ? corConferenciaCiano
          : isHighlighted
              ? const Color(0xFFe87722)
              : isDivergentePositiva
                  ? corEnderecoDivergentePositiva
                  : isDivergente
                      ? corEnderecoDivergente
                      : (widget.corPorProduto[caixa.produtoId] ?? const Color(0xFF888888));
      widget.geometry.addCaixaProduto(extraFaces,
          celula: celulaList.first, color: cor,
          desatualizado: widget.desatualizados.contains(chave));
    }

    return Listener(
      onPointerDown:   aoEncostarDedo,
      onPointerUp:     (e) { if (aoSoltarDedo(e)) _tryFireTap(pontoDoToque!); },
      onPointerCancel: aoSoltarDedo,
      child: GestureDetector(
        onScaleStart:  _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        child: CustomPaint(
          key:     _painterKey,
          painter: ExpositorMonitorPainter(_camera, widget.geometry,
              wireframe:  widget.wireframe,
              showLabels: widget.showLabels,
              extraFaces: extraFaces),
          child:   const SizedBox.expand(),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Miniatura do expositor pro mapa da loja (LojaScene) — base amarela, painel
// fino vertical, prateleiras escalonadas e testeira reta. Chamada no switch
// de tipos em buildFaces da LojaGeometry:
//
//   } else if (item.numero == expositorMonitorNum) {
//     expositorMonitorLoja(faces, item.x, item.z, item.w, item.d, cor);
//   }
// ─────────────────────────────────────────────────────────────────────────────

void expositorMonitorLoja(
  List<Face> faces,
  double cx, double cz, double w, double d,
  Color cor,
) {
  final hw = w / 2, hd = d / 2;
  // Mesma altura das demais estruturas do mapa (LojaGeometry._estanteH).
  const h = 0.85;
  final corTest = Color.lerp(cor, Colors.white, 0.35)!;

  void box(double x0, double x1, double y0, double y1,
           double z0, double z1, Color c) {
    faces.add(Face([Vec3(x0,y1,z0), Vec3(x0,y1,z1), Vec3(x1,y1,z1), Vec3(x1,y1,z0)], c));
    faces.add(Face([Vec3(x0,y0,z1), Vec3(x1,y0,z1), Vec3(x1,y1,z1), Vec3(x0,y1,z1)], c));
    faces.add(Face([Vec3(x1,y0,z0), Vec3(x0,y0,z0), Vec3(x0,y1,z0), Vec3(x1,y1,z0)], c));
    faces.add(Face([Vec3(x1,y0,z1), Vec3(x1,y0,z0), Vec3(x1,y1,z0), Vec3(x1,y1,z1)], c));
    faces.add(Face([Vec3(x0,y0,z0), Vec3(x0,y0,z1), Vec3(x0,y1,z1), Vec3(x0,y1,z0)], c));
  }

  // Base (o nível mais fundo do escalonamento)
  box(cx - hw, cx + hw, 0, 0.10, cz - hd, cz + hd, cor);
  // Painel vertical fino (encostado no fundo do footprint)
  box(cx - hw, cx + hw, 0.10, h * 0.80, cz - hd, cz - hd + 0.05, cor);
  // Prateleiras escalonadas: quanto mais baixa, mais funda
  box(cx - hw, cx + hw, h * 0.30, h * 0.30 + 0.02,
      cz - hd, cz - hd + d * 0.55, cor);
  box(cx - hw, cx + hw, h * 0.48, h * 0.48 + 0.02,
      cz - hd, cz - hd + d * 0.40, cor);
  box(cx - hw, cx + hw, h * 0.66, h * 0.66 + 0.02,
      cz - hd, cz - hd + d * 0.25, cor);
  // Testeira reta, levemente mais profunda que o painel
  box(cx - hw, cx + hw, h * 0.80, h, cz - hd, cz - hd + 0.14, corTest);
}
