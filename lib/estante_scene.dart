import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'gondola_scene.dart';
import 'models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CelulaEstante
// ─────────────────────────────────────────────────────────────────────────────

class CelulaEstante {
  final int coluna;
  final int nivel;
  final double yTop;
  final double xMin, xMax;

  const CelulaEstante({
    required this.coluna,
    required this.nivel,
    required this.yTop,
    required this.xMin,
    required this.xMax,
  });

  double get largura => xMax - xMin;
}

// ─────────────────────────────────────────────────────────────────────────────
// EstanteGeometry — 3 colunas × 4 níveis (12 células)
// ─────────────────────────────────────────────────────────────────────────────

class EstanteGeometry {
  static const _corMadeira      = Color(0xFF8a5a2e);
  static const _corMadeiraEscura = Color(0xFF5e3d1f);

  static const double larguraTotal = 6.0;
  static const double alturaTotal  = 4.2;
  static const double profundidade = 1.0;
  static const double espessura    = 0.08;
  static const int    numColunas   = 3;
  static const int    numNiveis    = 4;

  static const double wCaixa = 0.42, hCaixa = 0.50, dCaixa = 0.42, gap = 0.04;

  static double get larguraColuna {
    final espacoUtil = larguraTotal - espessura * (numColunas + 1);
    return espacoUtil / numColunas;
  }

  static double get alturaNivel => alturaTotal / numNiveis;

  static List<CelulaEstante> get celulas {
    final lista = <CelulaEstante>[];
    for (var col = 0; col < numColunas; col++) {
      final xMin =
          -larguraTotal / 2 + espessura * (col + 1) + larguraColuna * col;
      final xMax = xMin + larguraColuna;
      for (var niv = 0; niv < numNiveis; niv++) {
        lista.add(CelulaEstante(
          coluna: col,
          nivel:  niv,
          yTop:   espessura + alturaNivel * niv + espessura,
          xMin:   xMin,
          xMax:   xMax,
        ));
      }
    }
    return lista;
  }

  static int slotsPorCelula(CelulaEstante c) =>
      (c.largura / (wCaixa + gap)).floor();

  static List<Face> buildFaces() {
    final faces = <Face>[];
    final halfL = larguraTotal / 2;
    final halfD = profundidade / 2;

    // prateleiras horizontais (base + uma por nível)
    for (var niv = 0; niv <= numNiveis; niv++) {
      final y = espessura + alturaNivel * niv;
      _box(faces,
          x0: -halfL, x1: halfL,
          y0: y,      y1: y + espessura,
          z0: -halfD, z1: halfD,
          color: _corMadeira);
    }

    // lateral esquerda
    _box(faces,
        x0: -halfL,            x1: -halfL + espessura,
        y0: 0,                 y1: alturaTotal,
        z0: -halfD,            z1: halfD,
        color: _corMadeiraEscura);

    // lateral direita
    _box(faces,
        x0: halfL - espessura, x1: halfL,
        y0: 0,                 y1: alturaTotal,
        z0: -halfD,            z1: halfD,
        color: _corMadeiraEscura);

    // divisórias internas
    for (var col = 1; col < numColunas; col++) {
      final xDiv = -halfL + espessura * col + larguraColuna * col;
      _box(faces,
          x0: xDiv,            x1: xDiv + espessura,
          y0: 0,               y1: alturaTotal,
          z0: -halfD,          z1: halfD,
          color: _corMadeiraEscura);
    }

    return faces;
  }

  static void _box(
    List<Face> faces, {
    required double x0, required double x1,
    required double y0, required double y1,
    required double z0, required double z1,
    required Color color,
  }) {
    faces.add(Face([Vec3(x0,y1,z0), Vec3(x0,y1,z1), Vec3(x1,y1,z1), Vec3(x1,y1,z0)], color)); // top
    faces.add(Face([Vec3(x0,y0,z1), Vec3(x1,y0,z1), Vec3(x1,y1,z1), Vec3(x0,y1,z1)], color)); // front
    faces.add(Face([Vec3(x1,y0,z0), Vec3(x0,y0,z0), Vec3(x0,y1,z0), Vec3(x1,y1,z0)], color)); // back
    faces.add(Face([Vec3(x1,y0,z1), Vec3(x1,y0,z0), Vec3(x1,y1,z0), Vec3(x1,y1,z1)], color)); // right
    faces.add(Face([Vec3(x0,y0,z0), Vec3(x0,y0,z1), Vec3(x0,y1,z1), Vec3(x0,y1,z0)], color)); // left
  }

  static void addBoxProduto(
    List<Face> faces, {
    required CelulaEstante celula,
    required int slot,
    required Color color,
  }) {
    final xCenter = celula.xMin + wCaixa / 2 + slot * (wCaixa + gap);
    _box(faces,
        x0: xCenter - wCaixa / 2, x1: xCenter + wCaixa / 2,
        y0: celula.yTop,          y1: celula.yTop + hCaixa,
        z0: -dCaixa / 2,          z1: dCaixa / 2,
        color: color);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EstantePainter
// ─────────────────────────────────────────────────────────────────────────────

class EstantePainter extends CustomPainter {
  final Camera     camera;
  final List<Face> extraFaces;
  final bool       showLabels;

  static final Vec3 _lightDir = Vec3(5, 10, 7).normalized;

  EstantePainter(this.camera, {
    this.extraFaces = const <Face>[],
    this.showLabels = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF14110d));

    final faces = EstanteGeometry.buildFaces()..addAll(extraFaces);
    _project(faces, size);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
    if (showLabels) _drawLabels(canvas, size);
  }

  void _project(List<Face> faces, Size size) {
    final eye   = camera.position;
    final fwd   = (camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    const fovY = 45.0 * math.pi / 180.0;
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
      ..color      = const Color(0x33000000)
      ..style      = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    for (final f in faces) {
      if (f.proj.isEmpty) continue;
      final path = Path()..moveTo(f.proj[0].dx, f.proj[0].dy);
      for (var i = 1; i < f.proj.length; i++) {
        path.lineTo(f.proj[i].dx, f.proj[i].dy);
      }
      path.close();
      fill.color = Color.lerp(Colors.black, f.color, f.light)!;
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }
  }

  void _drawLabels(Canvas canvas, Size size) {
    final eye   = camera.position;
    final fwd   = (camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    const fovY = 45.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;
    final w = size.width, h = size.height;

    (Offset, double)? project(Vec3 v) {
      final d  = v - eye;
      final cz = d.dot(fwd);
      if (cz <= 0.01) return null;
      final cx = d.dot(right) / (cz * tanH * aspect);
      final cy = d.dot(up)    / (cz * tanH);
      return (Offset((cx + 1) / 2 * w, (1 - cy) / 2 * h), cz);
    }

    const camda   = Color(0xFFe87722);
    const bgColor = Color(0xC70b0c0e);
    const nNiveis = EstanteGeometry.numNiveis;

    final bgPaint  = Paint()..color = bgColor;
    final rimPaint = Paint()
      ..color       = camda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final celulas = EstanteGeometry.celulas;
    for (var niv = 0; niv < nNiveis; niv++) {
      final yTop = celulas.firstWhere((c) => c.nivel == niv).yTop;
      final hit  = project(Vec3(0, yTop + 0.06, 0));
      if (hit == null) continue;

      final (screen, cz) = hit;
      final fontSize = 32.0 * (6.0 / cz).clamp(0.5, 1.8);
      final radius   = fontSize * 0.72;

      canvas.drawCircle(screen, radius, bgPaint);
      canvas.drawCircle(screen, radius, rimPaint);

      final letter = String.fromCharCode(65 + (nNiveis - 1 - niv));
      final tp = TextPainter(
        text: TextSpan(
          text: letter,
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
  bool shouldRepaint(EstantePainter old) =>
      old.camera.rotY  != camera.rotY  ||
      old.camera.rotX  != camera.rotX  ||
      old.camera.dist  != camera.dist  ||
      old.showLabels   != showLabels   ||
      old.extraFaces   != extraFaces;
}

// ─────────────────────────────────────────────────────────────────────────────
// EstanteScene widget
// ─────────────────────────────────────────────────────────────────────────────

class EstanteScene extends StatefulWidget {
  final int estanteAtual;
  final List<CaixaColocadaEstante> caixas;
  final String? produtoSelecionadoId;
  final Map<String, Color> corPorProduto;
  final void Function(int coluna, int nivel, double hx)? onTapCelula;
  final String? destacadoCodigo;
  final bool showLabels;

  const EstanteScene({
    super.key,
    required this.estanteAtual,
    this.caixas               = const [],
    this.produtoSelecionadoId,
    this.corPorProduto        = const {},
    this.onTapCelula,
    this.destacadoCodigo,
    this.showLabels           = true,
  });

  @override
  State<EstanteScene> createState() => _EstanteSceneState();
}

class _EstanteSceneState extends State<EstanteScene> {
  Camera _camera = const Camera(
    rotY:   0.5,
    rotX:   0.25,
    dist:   9.0,
    target: Vec3(0, 2.1, 0),
  );
  final _painterKey = GlobalKey();

  Offset? _gestureOrigin;
  Camera? _cameraAtGestureStart;
  bool    _isDragging = false;

  static const double _dragThreshold = 7.0;

  void _onScaleStart(ScaleStartDetails d) {
    _gestureOrigin        = d.focalPoint;
    _cameraAtGestureStart = _camera;
    _isDragging           = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final origin = _gestureOrigin;
    final c0     = _cameraAtGestureStart;
    if (origin == null || c0 == null) return;

    final delta = d.focalPoint - origin;
    if (delta.distance > _dragThreshold || (d.scale - 1.0).abs() > 0.02) {
      _isDragging = true;
    }

    setState(() {
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.008,
        rotX: (c0.rotX + delta.dy * 0.008).clamp(-0.1, math.pi / 2 - 0.05),
        dist: (c0.dist / d.scale).clamp(4.0, 18.0),
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (!_isDragging && _gestureOrigin != null) {
      _tryFireTap(_gestureOrigin!);
    }
    _gestureOrigin        = null;
    _cameraAtGestureStart = null;
    _isDragging           = false;
  }

  void _tryFireTap(Offset globalTap) {
    if (widget.onTapCelula == null || widget.produtoSelecionadoId == null) return;
    final rb = _painterKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final hit = _hitTest(rb.globalToLocal(globalTap), rb.size);
    if (hit != null) widget.onTapCelula!(hit.coluna, hit.nivel, hit.hx);
  }

  // Ray-plane intersection. Returns nearest hit whose (hx, hz) lands inside the cell bounding box.
  ({int coluna, int nivel, double hx})? _hitTest(Offset tap, Size size) {
    final eye   = _camera.position;
    final fwd   = (_camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    const fovY = 45.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;

    final ndcX = 2 * tap.dx / size.width  - 1;
    final ndcY = 1 - 2 * tap.dy / size.height;

    final dir = (right * (ndcX * tanH * aspect) +
                 up    * (ndcY * tanH) +
                 fwd).normalized;

    ({int coluna, int nivel, double hx, double t})? nearest;

    for (final celula in EstanteGeometry.celulas) {
      if (dir.y.abs() < 1e-6) continue;
      final t = (celula.yTop - eye.y) / dir.y;
      if (t <= 0.1) continue;

      final hx = eye.x + t * dir.x;
      final hz = eye.z + t * dir.z;

      if (hx < celula.xMin || hx > celula.xMax) continue;
      if (hz.abs() > EstanteGeometry.profundidade / 2 + 0.05) continue;

      if (nearest == null || t < nearest.t) {
        nearest = (coluna: celula.coluna, nivel: celula.nivel, hx: hx, t: t);
      }
    }

    return nearest == null
        ? null
        : (coluna: nearest.coluna, nivel: nearest.nivel, hx: nearest.hx);
  }

  @override
  Widget build(BuildContext context) {
    final extraFaces = <Face>[];
    for (final caixa in widget.caixas) {
      final isHighlighted = caixa.produtoId == widget.destacadoCodigo;
      final cor = isHighlighted
          ? const Color(0xFFe87722)
          : (widget.corPorProduto[caixa.produtoId] ?? const Color(0xFF888888));
      final celula = EstanteGeometry.celulas.firstWhere(
        (c) => c.coluna == caixa.coluna && c.nivel == caixa.nivel,
      );
      EstanteGeometry.addBoxProduto(extraFaces,
          celula: celula, slot: caixa.slot, color: cor);
    }

    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        key:     _painterKey,
        painter: EstantePainter(_camera,
            extraFaces: extraFaces, showLabels: widget.showLabels),
        child:   const SizedBox.expand(),
      ),
    );
  }
}
