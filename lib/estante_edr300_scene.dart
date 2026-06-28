import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'gondola_scene.dart' show Vec3, Camera, Face;

// ─────────────────────────────────────────────────────────────────────────────
// Edr300Geometry — estante de aço com montantes em L perfurados
// ─────────────────────────────────────────────────────────────────────────────

class Edr300Geometry {
  final int    shelves;
  final double height;
  final double width;
  final double depth;
  final bool   showHoles;
  final bool   showFloor;

  const Edr300Geometry({
    this.shelves   = 6,
    this.height    = 1.98,
    this.width     = 0.92,
    this.depth     = 0.30,
    this.showHoles = false,
    this.showFloor = true,
  });

  static const _steel     = Color(0xFFb8bcc2);
  static const _steelDark = Color(0xFF9a9ea6);
  static const _hole      = Color(0xFF4a5060);
  static const _floor     = Color(0xFF12161d);

  static const double _postW  = 0.035;
  static const double _shelfT = 0.018;

  List<Face> buildFaces() {
    final faces = <Face>[];

    if (showFloor) {
      const s = 2.5;
      faces.add(Face([
        Vec3(-s, -0.001, -s), Vec3(-s, -0.001,  s),
        Vec3( s, -0.001,  s), Vec3( s, -0.001, -s),
      ], _floor));
    }

    final half  = width  / 2 - _postW / 2;
    final halfD = depth  / 2 - _postW / 2;

    // 4 montantes com perfil em L
    for (final pos in [
      (half,  halfD), (-half,  halfD),
      (half, -halfD), (-half, -halfD),
    ]) {
      final px = pos.$1, pz = pos.$2;

      // aba frontal
      _box(faces,
        x0: px - _postW / 2, x1: px + _postW / 2,
        y0: 0,               y1: height,
        z0: pz - 0.003,      z1: pz + 0.003,
        color: _steel);

      // aba lateral (forma o L)
      final sideX = px + (px > 0 ? -_postW / 2 : _postW / 2);
      _box(faces,
        x0: sideX - 0.003,  x1: sideX + 0.003,
        y0: 0,               y1: height,
        z0: pz - _postW / 2, z1: pz + _postW / 2,
        color: _steel);

      // furos de regulagem
      if (showHoles) {
        final rows = (height / 0.04).floor();
        for (var i = 2; i < rows - 1; i++) {
          _box(faces,
            x0: px - 0.007,        x1: px + 0.007,
            y0: i * 0.04 - 0.005,  y1: i * 0.04 + 0.005,
            z0: pz + 0.001,        z1: pz + 0.007,
            color: _hole);
        }
      }
    }

    // prateleiras
    for (var i = 0; i < shelves; i++) {
      final y = shelves > 1
          ? (height - _shelfT) * i / (shelves - 1)
          : height / 2;

      // bandeja
      _box(faces,
        x0: -width / 2 + 0.005, x1: width / 2 - 0.005,
        y0: y,                   y1: y + _shelfT,
        z0: -depth / 2 + 0.005, z1: depth / 2 - 0.005,
        color: _steel);

      // lábio frontal
      _box(faces,
        x0: -(width - 0.01) / 2, x1: (width - 0.01) / 2,
        y0: y - 0.03,             y1: y,
        z0: depth / 2 - 0.015,   z1: depth / 2 - 0.005,
        color: _steelDark);

      // lábio traseiro
      _box(faces,
        x0: -(width - 0.01) / 2,  x1: (width - 0.01) / 2,
        y0: y - 0.03,              y1: y,
        z0: -(depth / 2 - 0.005), z1: -(depth / 2 - 0.015),
        color: _steelDark);
    }

    return faces;
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
// Edr300Painter
// ─────────────────────────────────────────────────────────────────────────────

class Edr300Painter extends CustomPainter {
  final Camera         camera;
  final Edr300Geometry geometry;
  final bool           wireframe;

  static final Vec3 _lightDir = Vec3(4, 10, 5).normalized;

  const Edr300Painter(this.camera, this.geometry, {this.wireframe = false});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size,
        Paint()..color = const Color(0xFF0e1116));

    final faces = geometry.buildFaces();
    _project(faces, size);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
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

  @override
  bool shouldRepaint(Edr300Painter old) =>
      old.camera.rotY   != camera.rotY  ||
      old.camera.rotX   != camera.rotX  ||
      old.camera.dist   != camera.dist  ||
      old.wireframe     != wireframe     ||
      old.geometry.shelves   != geometry.shelves   ||
      old.geometry.height    != geometry.height    ||
      old.geometry.width     != geometry.width     ||
      old.geometry.depth     != geometry.depth     ||
      old.geometry.showHoles != geometry.showHoles ||
      old.geometry.showFloor != geometry.showFloor;
}

// ─────────────────────────────────────────────────────────────────────────────
// Edr300Scene widget — 3D interativo com rotação automática
// ─────────────────────────────────────────────────────────────────────────────

class Edr300Scene extends StatefulWidget {
  final Edr300Geometry geometry;
  final bool wireframe;
  final bool autoRotate;

  const Edr300Scene({
    super.key,
    required this.geometry,
    this.wireframe  = false,
    this.autoRotate = true,
  });

  @override
  State<Edr300Scene> createState() => _Edr300SceneState();
}

class _Edr300SceneState extends State<Edr300Scene>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  late Camera _camera;

  Offset? _gestureOrigin;
  Camera? _cameraAtStart;
  static const double _dragThreshold = 6.0;

  @override
  void initState() {
    super.initState();
    _camera = Camera(
      rotY:   0.9,
      rotX:   0.35,
      dist:   3.5,
      target: Vec3(0, widget.geometry.height / 2, 0),
    );
    _ticker = createTicker((_) {
      if (widget.autoRotate) {
        setState(() => _camera = _camera.copyWith(rotY: _camera.rotY + 0.0025));
      }
    })..start();
  }

  @override
  void didUpdateWidget(Edr300Scene old) {
    super.didUpdateWidget(old);
    if (old.geometry.height != widget.geometry.height) {
      _camera = Camera(
        rotY:   _camera.rotY,
        rotX:   _camera.rotX,
        dist:   _camera.dist,
        target: Vec3(0, widget.geometry.height / 2, 0),
      );
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onScaleStart(ScaleStartDetails d) {
    _gestureOrigin = d.focalPoint;
    _cameraAtStart = _camera;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final origin = _gestureOrigin;
    final c0     = _cameraAtStart;
    if (origin == null || c0 == null) return;
    final delta = d.focalPoint - origin;
    setState(() {
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.008,
        rotX: (c0.rotX + delta.dy * 0.008).clamp(-0.1, math.pi / 2 - 0.05),
        dist: (c0.dist / d.scale).clamp(1.5, 8.0),
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    _gestureOrigin = null;
    _cameraAtStart = null;
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onScaleStart:  _onScaleStart,
    onScaleUpdate: _onScaleUpdate,
    onScaleEnd:    _onScaleEnd,
    child: CustomPaint(
      painter: Edr300Painter(_camera, widget.geometry, wireframe: widget.wireframe),
      child:   const SizedBox.expand(),
    ),
  );
}
