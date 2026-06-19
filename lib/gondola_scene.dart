import 'dart:math' as math;
import 'package:flutter/material.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Vec3
// ──────────────────────────────────────────────────────────────────────────────

class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  Vec3 cross(Vec3 o) => Vec3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );

  double get length => math.sqrt(x * x + y * y + z * z);
  Vec3 get normalized {
    final l = length;
    return l < 1e-10 ? const Vec3(0, 1, 0) : this * (1.0 / l);
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Camera — immutable orbit camera
// ──────────────────────────────────────────────────────────────────────────────

class Camera {
  final double rotY;
  final double rotX;
  final double dist;
  final Vec3 target;

  const Camera({
    this.rotY = 0.0,
    this.rotX = 0.2,
    this.dist = 14.0,
    this.target = const Vec3(0, 1.7, 0),
  });

  Camera copyWith({double? rotY, double? rotX, double? dist}) => Camera(
        rotY: rotY ?? this.rotY,
        rotX: rotX ?? this.rotX,
        dist: dist ?? this.dist,
        target: target,
      );

  Vec3 get position {
    final cosX = math.cos(rotX);
    return Vec3(
      target.x + dist * math.sin(rotY) * cosX,
      target.y + dist * math.sin(rotX),
      target.z + dist * math.cos(rotY) * cosX,
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Face — polygon in world space, projected by the painter
// ──────────────────────────────────────────────────────────────────────────────

class Face {
  final List<Vec3> verts;
  final Color color;
  double depth = 0;
  List<Offset> proj = const [];
  double light = 1.0;

  Face(this.verts, this.color);
}

// ──────────────────────────────────────────────────────────────────────────────
// CaixaColocada — a product box placed on a shelf
// ──────────────────────────────────────────────────────────────────────────────

class CaixaColocada {
  final int andar;       // 0=base, 1=meio, 2=topo
  final String produtoId;
  final double x, z;    // position at shelf surface centre

  const CaixaColocada({
    required this.andar,
    required this.produtoId,
    required this.x,
    required this.z,
  });

  Map<String, dynamic> toJson() =>
      {'andar': andar, 'produtoId': produtoId, 'x': x, 'z': z};
}

// ──────────────────────────────────────────────────────────────────────────────
// GondolaGeometry — static gondola faces + box helper
// ──────────────────────────────────────────────────────────────────────────────

class GondolaGeometry {
  static const _corCorpo  = Color(0xFF2e6b46);
  static const _corColuna = Color(0xFF1f4a30);
  static const _corBorda  = Color(0xFF4a9d6a);

  // yTop = top of shelf surface including the 0.06 accent-ring.
  // This is the Y at which boxes sit and what hit-testing tests against.
  static const List<({double yTop, double r})> andares = [
    (yTop: 0.675 + 0.35 / 2 + 0.06, r: 3.4), // andar 0 — base  (y≈0.91)
    (yTop: 2.15  + 0.30 / 2 + 0.06, r: 2.4), // andar 1 — meio  (y≈2.36)
    (yTop: 3.43  + 0.26 / 2 + 0.06, r: 1.5), // andar 2 — topo  (y≈3.62)
  ];

  static List<Face> buildFaces() {
    final faces = <Face>[];

    // 8 feet
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      _prism(faces,
          cx: 2.8 * math.cos(a), cz: 2.8 * math.sin(a),
          y0: 0.0, y1: 0.5,
          r: 0.12, sides: 6,
          color: _corColuna);
    }

    // Shelf 0 — base
    _shelf(faces, r: 3.4, yc: 0.675, h: 0.35);
    _prism(faces, cx: 0, cz: 0, y0: 0.85, y1: 2.0,
        r: 0.28, sides: 8, color: _corColuna);

    // Shelf 1 — meio
    _shelf(faces, r: 2.4, yc: 2.15, h: 0.30);
    _prism(faces, cx: 0, cz: 0, y0: 2.30, y1: 3.30,
        r: 0.28, sides: 8, color: _corColuna);

    // Shelf 2 — topo
    _shelf(faces, r: 1.5, yc: 3.43, h: 0.26);

    return faces;
  }

  static void _shelf(List<Face> faces,
      {required double r, required double yc, required double h}) {
    const rot = math.pi / 8;
    _prism(faces,
        cx: 0, cz: 0, y0: yc - h / 2, y1: yc + h / 2,
        r: r, sides: 8, color: _corCorpo, rotOff: rot);
    _prism(faces,
        cx: 0, cz: 0, y0: yc + h / 2, y1: yc + h / 2 + 0.06,
        r: r + 0.13, sides: 8, color: _corBorda, rotOff: rot);
  }

  static void _prism(List<Face> faces, {
    required double cx, required double cz,
    required double y0, required double y1,
    required double r, required int sides,
    required Color color, double rotOff = 0,
  }) {
    final angles = List.generate(sides, (i) => i * 2 * math.pi / sides + rotOff);

    for (var i = 0; i < sides; i++) {
      final a0 = angles[i], a1 = angles[(i + 1) % sides];
      final x0 = cx + r * math.cos(a0), z0 = cz + r * math.sin(a0);
      final x1 = cx + r * math.cos(a1), z1 = cz + r * math.sin(a1);
      faces.add(Face([
        Vec3(x0, y0, z0), Vec3(x0, y1, z0),
        Vec3(x1, y1, z1), Vec3(x1, y0, z1),
      ], color));
    }

    // Single-polygon top cap — no internal edge lines
    faces.add(Face([
      for (var i = sides - 1; i >= 0; i--)
        Vec3(cx + r * math.cos(angles[i]), y1, cz + r * math.sin(angles[i]))
    ], color));
  }

  /// Adds 5 visible faces of a box sitting on a shelf surface at (cx, cy, cz).
  static void addBox(List<Face> faces, {
    required double cx, required double cy, required double cz,
    required Color color,
  }) {
    const w = 0.40, h = 0.52, d = 0.40;
    final x0 = cx - w / 2, x1 = cx + w / 2;
    final y0 = cy,          y1 = cy + h;
    final z0 = cz - d / 2, z1 = cz + d / 2;

    // Top  (+Y)
    faces.add(Face([Vec3(x0,y1,z0), Vec3(x0,y1,z1), Vec3(x1,y1,z1), Vec3(x1,y1,z0)], color));
    // Front (+Z)
    faces.add(Face([Vec3(x0,y0,z1), Vec3(x1,y0,z1), Vec3(x1,y1,z1), Vec3(x0,y1,z1)], color));
    // Back  (-Z)
    faces.add(Face([Vec3(x1,y0,z0), Vec3(x0,y0,z0), Vec3(x0,y1,z0), Vec3(x1,y1,z0)], color));
    // Right (+X)
    faces.add(Face([Vec3(x1,y0,z1), Vec3(x1,y0,z0), Vec3(x1,y1,z0), Vec3(x1,y1,z1)], color));
    // Left  (-X)
    faces.add(Face([Vec3(x0,y0,z0), Vec3(x0,y0,z1), Vec3(x0,y1,z1), Vec3(x0,y1,z0)], color));
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// GondolaPainter
// ──────────────────────────────────────────────────────────────────────────────

class GondolaPainter extends CustomPainter {
  final Camera camera;
  final List<Face> extraFaces;

  static final Vec3 _lightDir = Vec3(5, 10, 7).normalized;

  GondolaPainter(this.camera, {this.extraFaces = const <Face>[]});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0e1014));

    final faces = GondolaGeometry.buildFaces()..addAll(extraFaces);
    _project(faces, size);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
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

      final li = f.light;
      final c  = f.color;
      fill.color = Color.lerp(Colors.black, c, li)!;
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }
  }

  @override
  bool shouldRepaint(GondolaPainter old) =>
      old.camera.rotY != camera.rotY ||
      old.camera.rotX != camera.rotX ||
      old.camera.dist != camera.dist ||
      old.extraFaces  != extraFaces;
}

// ──────────────────────────────────────────────────────────────────────────────
// GondolaScene widget
// ──────────────────────────────────────────────────────────────────────────────

class GondolaScene extends StatefulWidget {
  final int gondolaAtual;
  final List<CaixaColocada> caixas;
  final String? produtoSelecionadoId;
  final Map<String, Color> corPorProduto;
  final void Function(int andar, double x, double z)? onTapAndar;
  final String? destacadoCodigo;

  const GondolaScene({
    super.key,
    required this.gondolaAtual,
    this.caixas = const [],
    this.produtoSelecionadoId,
    this.corPorProduto = const {},
    this.onTapAndar,
    this.destacadoCodigo,
  });

  @override
  State<GondolaScene> createState() => _GondolaSceneState();
}

class _GondolaSceneState extends State<GondolaScene> {
  Camera _camera = const Camera();
  final  _painterKey = GlobalKey();

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
    // Multi-finger or large movement → drag (not a tap)
    if (delta.distance > _dragThreshold || (d.scale - 1.0).abs() > 0.02) {
      _isDragging = true;
    }

    setState(() {
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.008,
        rotX: (c0.rotX + delta.dy * 0.008).clamp(-0.05, math.pi / 2 - 0.05),
        dist: (c0.dist / d.scale).clamp(4.0, 28.0),
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (!_isDragging && _gestureOrigin != null) {
      _tryPlaceBox(_gestureOrigin!);
    }
    _gestureOrigin        = null;
    _cameraAtGestureStart = null;
    _isDragging           = false;
  }

  void _tryPlaceBox(Offset globalTap) {
    if (widget.onTapAndar == null || widget.produtoSelecionadoId == null) return;

    final rb = _painterKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;

    final hit = _hitTest(rb.globalToLocal(globalTap), rb.size);
    if (hit != null) widget.onTapAndar!(hit.andar, hit.x, hit.z);
  }

  /// Ray-plane intersection against each shelf's horizontal surface.
  /// Returns the nearest hit (smallest positive t) that lands within the shelf radius.
  ({int andar, double x, double z})? _hitTest(Offset tap, Size size) {
    final eye   = _camera.position;
    final fwd   = (_camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    const fovY = 45.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;

    final ndcX = 2 * tap.dx / size.width  - 1;
    final ndcY = 1 - 2 * tap.dy / size.height;

    // Ray direction through this screen pixel
    final dir = (right * (ndcX * tanH * aspect) +
                 up    * (ndcY * tanH) +
                 fwd).normalized;

    ({int andar, double x, double z, double t})? nearest;

    for (var i = 0; i < GondolaGeometry.andares.length; i++) {
      final shelf = GondolaGeometry.andares[i];
      if (dir.y.abs() < 1e-6) continue; // ray parallel to shelf plane

      final t = (shelf.yTop - eye.y) / dir.y;
      if (t <= 0.1) continue; // behind camera

      final hx = eye.x + t * dir.x;
      final hz = eye.z + t * dir.z;

      // Conservative octagon check: point must be within 90% of shelf radius
      if (math.sqrt(hx * hx + hz * hz) < shelf.r * 0.90) {
        if (nearest == null || t < nearest.t) {
          nearest = (andar: i, x: hx, z: hz, t: t);
        }
      }
    }

    return nearest == null ? null : (andar: nearest.andar, x: nearest.x, z: nearest.z);
  }

  @override
  Widget build(BuildContext context) {
    // Build box faces from current gondola's placed boxes
    final extraFaces = <Face>[];
    for (final caixa in widget.caixas) {
      final isHighlighted = caixa.produtoId == widget.destacadoCodigo;
      final cor = isHighlighted
          ? const Color(0xFFe87722)
          : (widget.corPorProduto[caixa.produtoId] ?? const Color(0xFF888888));
      final shelf = GondolaGeometry.andares[caixa.andar];
      GondolaGeometry.addBox(extraFaces,
          cx: caixa.x, cy: shelf.yTop, cz: caixa.z, color: cor);
    }

    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        key:     _painterKey,
        painter: GondolaPainter(_camera, extraFaces: extraFaces),
        child:   const SizedBox.expand(),
      ),
    );
  }
}
