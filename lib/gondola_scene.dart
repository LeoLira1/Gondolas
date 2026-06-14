import 'dart:math' as math;
import 'package:flutter/material.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Vec3 — lightweight 3-D vector
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
  final double rotY; // azimuth
  final double rotX; // elevation (~11° up matches original three_js initial pos)
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
// _Face — polygon in world space, projected lazily
// ──────────────────────────────────────────────────────────────────────────────

class _Face {
  final List<Vec3> verts;
  final Color color;
  double depth = 0;
  List<Offset> proj = const [];
  double light = 1.0;

  _Face(this.verts, this.color);
}

// ──────────────────────────────────────────────────────────────────────────────
// GondolaGeometry — builds static gondola faces
// The faces list is passed to the painter each frame; boxes (Part 2) will be
// appended to the same list before projection so they share the same pipeline.
// ──────────────────────────────────────────────────────────────────────────────

class GondolaGeometry {
  static const _corCorpo  = Color(0xFF2e6b46);
  static const _corColuna = Color(0xFF1f4a30);
  static const _corBorda  = Color(0xFF4a9d6a);

  // Shelf Y-centres and radii — exposed so hit-testing (Part 2) can reuse them
  static const List<({double yTop, double r})> andares = [
    (yTop: 0.675 + 0.35 / 2, r: 3.4), // andar 0 — base
    (yTop: 2.15  + 0.30 / 2, r: 2.4), // andar 1 — meio
    (yTop: 3.43  + 0.26 / 2, r: 1.5), // andar 2 — topo
  ];

  static List<_Face> buildFaces() {
    final faces = <_Face>[];

    // 8 feet
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      _prism(faces,
          cx: 2.8 * math.cos(a), cz: 2.8 * math.sin(a),
          y0: 0.0, y1: 0.5,
          r: 0.12, sides: 6,
          color: _corColuna);
    }

    // Shelf 0 — base (radius 3.4)
    _shelf(faces, r: 3.4, yc: 0.675, h: 0.35);
    // Column 0→1
    _prism(faces, cx: 0, cz: 0, y0: 0.85, y1: 2.0,
        r: 0.28, sides: 8, color: _corColuna);

    // Shelf 1 — meio (radius 2.4)
    _shelf(faces, r: 2.4, yc: 2.15, h: 0.30);
    // Column 1→2
    _prism(faces, cx: 0, cz: 0, y0: 2.30, y1: 3.30,
        r: 0.28, sides: 8, color: _corColuna);

    // Shelf 2 — topo (radius 1.5)
    _shelf(faces, r: 1.5, yc: 3.43, h: 0.26);

    return faces;
  }

  static void _shelf(List<_Face> faces,
      {required double r, required double yc, required double h}) {
    const rot = math.pi / 8; // align flat face forward
    _prism(faces,
        cx: 0, cz: 0, y0: yc - h / 2, y1: yc + h / 2,
        r: r, sides: 8, color: _corCorpo, rotOff: rot);
    // Accent border ring on top
    _prism(faces,
        cx: 0, cz: 0, y0: yc + h / 2, y1: yc + h / 2 + 0.06,
        r: r + 0.13, sides: 8, color: _corBorda, rotOff: rot);
  }

  /// Builds an n-sided prism (side faces + top cap).
  /// Winding chosen for outward side normals and upward top normals.
  static void _prism(List<_Face> faces, {
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
      // Side: v0_bottom → v0_top → v1_top → v1_bottom gives outward normal
      faces.add(_Face([
        Vec3(x0, y0, z0), Vec3(x0, y1, z0),
        Vec3(x1, y1, z1), Vec3(x1, y0, z1),
      ], color));
    }

    // Top cap as single polygon (reverse angle order → +Y normal, no internal edge lines)
    faces.add(_Face([
      for (var i = sides - 1; i >= 0; i--)
        Vec3(cx + r * math.cos(angles[i]), y1, cz + r * math.sin(angles[i]))
    ], color));
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// GondolaPainter — projects + painter's-algorithm sorts + draws faces
// ──────────────────────────────────────────────────────────────────────────────

class GondolaPainter extends CustomPainter {
  final Camera camera;
  // Boxes to draw (Part 2 will pass them in)
  final List<_Face> extraFaces;

  static final Vec3 _lightDir = Vec3(5, 10, 7).normalized;

  GondolaPainter(this.camera, {this.extraFaces = const <_Face>[]});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0e1014));

    final faces = GondolaGeometry.buildFaces()..addAll(extraFaces);
    _project(faces, size);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
  }

  void _project(List<_Face> faces, Size size) {
    final eye = camera.position;
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

      // Average depth in camera space
      f.depth = f.verts.fold(0.0, (s, v) => s + (v - eye).dot(fwd)) /
          f.verts.length;

      // Diffuse lighting from first triangle of the face
      if (f.verts.length >= 3) {
        final n = (f.verts[1] - f.verts[0])
            .cross(f.verts[2] - f.verts[0])
            .normalized;
        f.light = 0.35 + 0.65 * n.dot(_lightDir).clamp(0.0, 1.0);
      }
    }
  }

  void _draw(Canvas canvas, List<_Face> faces) {
    final fillPaint   = Paint();
    final strokePaint = Paint()
      ..color     = const Color(0x33000000)
      ..style     = PaintingStyle.stroke
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
      fillPaint.color = Color.fromARGB(
        255,
        (c.red   * li).round().clamp(0, 255),
        (c.green * li).round().clamp(0, 255),
        (c.blue  * li).round().clamp(0, 255),
      );
      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, strokePaint);
    }
  }

  @override
  bool shouldRepaint(GondolaPainter old) =>
      old.camera.rotY   != camera.rotY   ||
      old.camera.rotX   != camera.rotX   ||
      old.camera.dist   != camera.dist   ||
      old.extraFaces    != extraFaces;
}

// ──────────────────────────────────────────────────────────────────────────────
// GondolaScene widget
// ──────────────────────────────────────────────────────────────────────────────

class GondolaScene extends StatefulWidget {
  final int gondolaAtual;

  const GondolaScene({super.key, required this.gondolaAtual});

  @override
  State<GondolaScene> createState() => _GondolaSceneState();
}

class _GondolaSceneState extends State<GondolaScene> {
  Camera _camera = const Camera();

  // Gesture tracking — used in Part 2 to distinguish tap vs drag
  Offset?  _gestureOrigin;
  Camera?  _cameraAtGestureStart;
  bool     _isDragging = false;

  static const double _dragThreshold = 6.0; // px

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
    if (delta.distance > _dragThreshold) _isDragging = true;

    setState(() {
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.008,
        rotX: (c0.rotX + delta.dy * 0.008)
            .clamp(-0.05, math.pi / 2 - 0.05), // prevent going below horizon
        dist: (c0.dist / d.scale).clamp(4.0, 28.0),
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    // _isDragging stays set until next gesture start.
    // Part 2 will inspect it inside onTapUp to gate box placement.
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        painter: GondolaPainter(_camera),
        child: const SizedBox.expand(),
      ),
    );
  }
}
