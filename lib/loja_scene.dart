import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'gondola_scene.dart'; // Vec3, Camera

// ──────────────────────────────────────────────────────────────────────────────
// Store item model
// ──────────────────────────────────────────────────────────────────────────────

enum LojaItemTipo { gondola, estante }

class LojaItem {
  final int id;
  final LojaItemTipo tipo;
  final String label;
  final double cx, cz;

  const LojaItem({
    required this.id,
    required this.tipo,
    required this.label,
    required this.cx,
    required this.cz,
  });

  @override
  bool operator ==(Object other) =>
      other is LojaItem && other.id == id && other.tipo == tipo;

  @override
  int get hashCode => Object.hash(id, tipo);
}

// ──────────────────────────────────────────────────────────────────────────────
// Store layout
// ──────────────────────────────────────────────────────────────────────────────
//
// Floor: X ∈ [-14, 14], Z ∈ [-10, 10]
// 12 gondolas: 3 rows × 4 cols, each 3.2 wide × 1.0 deep × 1.8 tall
// 7 wall shelves: 3 left + 3 right + 1 back

const List<LojaItem> lojaGondolas = [
  LojaItem(id: 1,  tipo: LojaItemTipo.gondola, label: '1',  cx: -9.0, cz: -6.0),
  LojaItem(id: 2,  tipo: LojaItemTipo.gondola, label: '2',  cx: -3.0, cz: -6.0),
  LojaItem(id: 3,  tipo: LojaItemTipo.gondola, label: '3',  cx:  3.0, cz: -6.0),
  LojaItem(id: 4,  tipo: LojaItemTipo.gondola, label: '4',  cx:  9.0, cz: -6.0),
  LojaItem(id: 5,  tipo: LojaItemTipo.gondola, label: '5',  cx: -9.0, cz:  0.0),
  LojaItem(id: 6,  tipo: LojaItemTipo.gondola, label: '6',  cx: -3.0, cz:  0.0),
  LojaItem(id: 7,  tipo: LojaItemTipo.gondola, label: '7',  cx:  3.0, cz:  0.0),
  LojaItem(id: 8,  tipo: LojaItemTipo.gondola, label: '8',  cx:  9.0, cz:  0.0),
  LojaItem(id: 9,  tipo: LojaItemTipo.gondola, label: '9',  cx: -9.0, cz:  6.0),
  LojaItem(id: 10, tipo: LojaItemTipo.gondola, label: '10', cx: -3.0, cz:  6.0),
  LojaItem(id: 11, tipo: LojaItemTipo.gondola, label: '11', cx:  3.0, cz:  6.0),
  LojaItem(id: 12, tipo: LojaItemTipo.gondola, label: '12', cx:  9.0, cz:  6.0),
];

const List<LojaItem> lojaEstantes = [
  // Left wall (x = -13.7): shelf depth along X, length along Z
  LojaItem(id: 1, tipo: LojaItemTipo.estante, label: 'E1', cx: -13.7, cz: -6.0),
  LojaItem(id: 2, tipo: LojaItemTipo.estante, label: 'E2', cx: -13.7, cz:  0.0),
  LojaItem(id: 3, tipo: LojaItemTipo.estante, label: 'E3', cx: -13.7, cz:  6.0),
  // Right wall (x = +13.7): mirror
  LojaItem(id: 4, tipo: LojaItemTipo.estante, label: 'E4', cx:  13.7, cz: -6.0),
  LojaItem(id: 5, tipo: LojaItemTipo.estante, label: 'E5', cx:  13.7, cz:  0.0),
  LojaItem(id: 6, tipo: LojaItemTipo.estante, label: 'E6', cx:  13.7, cz:  6.0),
  // Back wall (z = -9.7): length along X
  LojaItem(id: 7, tipo: LojaItemTipo.estante, label: 'E7', cx:  0.0,  cz: -9.7),
];

// ──────────────────────────────────────────────────────────────────────────────
// Internal face type
// ──────────────────────────────────────────────────────────────────────────────

class _LFace {
  final List<Vec3> verts;
  final Color color;
  final bool isWall;
  double depth = 0;
  List<Offset> proj = const [];
  double light = 1.0;

  _LFace(this.verts, this.color, {this.isWall = false});
}

// ──────────────────────────────────────────────────────────────────────────────
// LojaGeometry — static helpers
// ──────────────────────────────────────────────────────────────────────────────

class LojaGeometry {
  static const _corPiso    = Color(0xFF141c27);
  static const _corGrade   = Color(0xFF1e2d40);
  static const _corGondola = Color(0xFF2e6b46);
  static const _corEstante = Color(0xFF1f4a30);
  static const _corBordaG  = Color(0xFF4a9d6a);
  static const _corSel     = Color(0xFFe8a022);
  static const _corBordaSel= Color(0xFFf5c842);
  // Semi-transparent walls (Correção A: opacity ~0.35 so objects behind are visible)
  static const _corParede  = Color(0x593a4a60);

  static List<_LFace> build({LojaItem? selected}) {
    final faces = <_LFace>[];

    _floor(faces);
    _walls(faces);

    for (final g in lojaGondolas) {
      _gondola(faces, g, selected: selected == g);
    }
    for (final e in lojaEstantes) {
      _estante(faces, e, selected: selected == e);
    }

    return faces;
  }

  static void _floor(List<_LFace> faces) {
    // Main floor quad
    faces.add(_LFace([
      Vec3(-14, 0, -10), Vec3( 14, 0, -10),
      Vec3( 14, 0,  10), Vec3(-14, 0,  10),
    ], _corPiso));

    // Grid lines as thin quads (avoid z-fighting: y = 0.002)
    const h = 0.002;
    for (var z = -9.0; z <= 9.0; z += 3.0) {
      faces.add(_LFace([
        Vec3(-14, h, z - 0.04), Vec3(14, h, z - 0.04),
        Vec3(14, h, z + 0.04), Vec3(-14, h, z + 0.04),
      ], _corGrade));
    }
    for (var x = -12.0; x <= 12.0; x += 3.0) {
      faces.add(_LFace([
        Vec3(x - 0.04, h, -10), Vec3(x + 0.04, h, -10),
        Vec3(x + 0.04, h,  10), Vec3(x - 0.04, h,  10),
      ], _corGrade));
    }
  }

  // Semi-transparent perimeter walls — drawn after opaque geometry so blending
  // doesn't hide objects behind them (Correção A).
  static void _walls(List<_LFace> faces) {
    const hw = 14.0, hd = 10.0, wh = 3.2;
    // Back wall (z = -hd) — most likely to occlude objects at certain angles
    faces.add(_LFace([
      Vec3(-hw, 0, -hd), Vec3( hw, 0, -hd),
      Vec3( hw, wh, -hd), Vec3(-hw, wh, -hd),
    ], _corParede, isWall: true));
    // Front wall (z = +hd)
    faces.add(_LFace([
      Vec3( hw, 0, hd), Vec3(-hw, 0, hd),
      Vec3(-hw, wh, hd), Vec3( hw, wh, hd),
    ], _corParede, isWall: true));
    // Left wall (x = -hw)
    faces.add(_LFace([
      Vec3(-hw, 0,  hd), Vec3(-hw, 0, -hd),
      Vec3(-hw, wh, -hd), Vec3(-hw, wh,  hd),
    ], _corParede, isWall: true));
    // Right wall (x = +hw)
    faces.add(_LFace([
      Vec3(hw, 0, -hd), Vec3(hw, 0,  hd),
      Vec3(hw, wh,  hd), Vec3(hw, wh, -hd),
    ], _corParede, isWall: true));
  }

  // Gondola box: 3.2 wide (X) × 1.0 deep (Z) × 1.8 tall
  static void _gondola(List<_LFace> faces, LojaItem g, {bool selected = false}) {
    final c  = selected ? _corSel    : _corGondola;
    final cb = selected ? _corBordaSel : _corBordaG;
    _box(faces, cx: g.cx, cy: 0.9, cz: g.cz, hx: 1.6, hy: 0.9, hz: 0.5, color: c);
    // Accent cap on top
    _box(faces, cx: g.cx, cy: 1.85, cz: g.cz, hx: 1.7, hy: 0.05, hz: 0.6, color: cb);
  }

  // Wall shelf: side shelves run along Z (hx small, hz large)
  //             back shelf runs along X (hx large, hz small)
  static void _estante(List<_LFace> faces, LojaItem e, {bool selected = false}) {
    final c = selected ? _corSel : _corEstante;
    final isLateral = e.cx.abs() > 10;
    if (isLateral) {
      _box(faces, cx: e.cx, cy: 1.0, cz: e.cz, hx: 0.3, hy: 1.0, hz: 2.2, color: c);
    } else {
      _box(faces, cx: e.cx, cy: 1.0, cz: e.cz, hx: 5.0, hy: 1.0, hz: 0.3, color: c);
    }
  }

  // Axis-aligned box: 5 visible faces (no bottom)
  static void _box(List<_LFace> faces, {
    required double cx, required double cy, required double cz,
    required double hx, required double hy, required double hz,
    required Color color, bool isWall = false,
  }) {
    final x0 = cx - hx, x1 = cx + hx;
    final y0 = cy - hy, y1 = cy + hy;
    final z0 = cz - hz, z1 = cz + hz;

    // Top (+Y)
    faces.add(_LFace([Vec3(x0,y1,z0), Vec3(x0,y1,z1), Vec3(x1,y1,z1), Vec3(x1,y1,z0)], color, isWall: isWall));
    // Front (+Z)
    faces.add(_LFace([Vec3(x0,y0,z1), Vec3(x1,y0,z1), Vec3(x1,y1,z1), Vec3(x0,y1,z1)], color, isWall: isWall));
    // Back (-Z)
    faces.add(_LFace([Vec3(x1,y0,z0), Vec3(x0,y0,z0), Vec3(x0,y1,z0), Vec3(x1,y1,z0)], color, isWall: isWall));
    // Right (+X)
    faces.add(_LFace([Vec3(x1,y0,z1), Vec3(x1,y0,z0), Vec3(x1,y1,z0), Vec3(x1,y1,z1)], color, isWall: isWall));
    // Left (-X)
    faces.add(_LFace([Vec3(x0,y0,z0), Vec3(x0,y0,z1), Vec3(x0,y1,z1), Vec3(x0,y1,z0)], color, isWall: isWall));
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// LojaPainter
// ──────────────────────────────────────────────────────────────────────────────

class LojaPainter extends CustomPainter {
  final Camera camera;
  final LojaItem? selected;

  static final Vec3 _lightDir = Vec3(5, 10, 7).normalized;
  static const _near = 0.5;

  LojaPainter(this.camera, {this.selected});

  // Per-paint cached vectors
  late Vec3   _eye, _fwd, _right, _up;
  late double _tanH, _aspect, _w, _h;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0e1014));

    _eye    = camera.position;
    _fwd    = (camera.target - _eye).normalized;
    _right  = _fwd.cross(const Vec3(0, 1, 0)).normalized;
    _up     = _right.cross(_fwd).normalized;
    const fovY = 45.0 * math.pi / 180.0;
    _tanH   = math.tan(fovY / 2);
    _aspect = size.width / size.height;
    _w = size.width;
    _h = size.height;

    final faces = LojaGeometry.build(selected: selected);
    for (final f in faces) {
      _projectFace(f);
    }

    // Opaque faces sorted back-to-front, then semi-transparent walls on top
    final opaque = faces.where((f) => !f.isWall && f.proj.isNotEmpty).toList()
      ..sort((a, b) => b.depth.compareTo(a.depth));
    final walls  = faces.where((f) =>  f.isWall && f.proj.isNotEmpty).toList()
      ..sort((a, b) => b.depth.compareTo(a.depth));

    _drawFaces(canvas, opaque);
    _drawFaces(canvas, walls);
    _drawLabels(canvas);
  }

  Offset _toScreen(Vec3 v) {
    final d  = v - _eye;
    final cz = d.dot(_fwd);
    final cx = d.dot(_right) / (cz * _tanH * _aspect);
    final cy = d.dot(_up)    / (cz * _tanH);
    return Offset((cx + 1) / 2 * _w, (1 - cy) / 2 * _h);
  }

  void _projectFace(_LFace f) {
    final clipped = _clipNear(f.verts);
    if (clipped.length < 3) {
      f.proj  = const [];
      f.depth = -1e9;
      return;
    }
    f.proj  = clipped.map(_toScreen).toList();
    f.depth = clipped.fold(0.0, (s, v) => s + (v - _eye).dot(_fwd)) / clipped.length;
    if (f.verts.length >= 3) {
      final n = (f.verts[1] - f.verts[0]).cross(f.verts[2] - f.verts[0]).normalized;
      f.light = 0.35 + 0.65 * n.dot(_lightDir).clamp(0.0, 1.0);
    }
  }

  // Sutherland-Hodgman clip against near plane
  List<Vec3> _clipNear(List<Vec3> verts) {
    final out = <Vec3>[];
    final len = verts.length;
    for (var i = 0; i < len; i++) {
      final a = verts[i];
      final b = verts[(i + 1) % len];
      final da = (a - _eye).dot(_fwd);
      final db = (b - _eye).dot(_fwd);
      if (da >= _near) out.add(a);
      if ((da >= _near) != (db >= _near)) {
        final t = (_near - da) / (db - da);
        out.add(Vec3(
          a.x + (b.x - a.x) * t,
          a.y + (b.y - a.y) * t,
          a.z + (b.z - a.z) * t,
        ));
      }
    }
    return out;
  }

  void _drawFaces(Canvas canvas, List<_LFace> faces) {
    final fill   = Paint();
    final stroke = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color       = const Color(0x33000000);

    for (final f in faces) {
      if (f.proj.isEmpty) continue;
      final path = Path()..moveTo(f.proj[0].dx, f.proj[0].dy);
      for (var i = 1; i < f.proj.length; i++) {
        path.lineTo(f.proj[i].dx, f.proj[i].dy);
      }
      path.close();

      fill.color = Color.lerp(Colors.black, f.color, f.light)!;
      canvas.drawPath(path, fill);
      if (!f.isWall) canvas.drawPath(path, stroke);
    }
  }

  void _drawLabels(Canvas canvas) {
    for (final g in lojaGondolas) {
      _label(canvas, Vec3(g.cx, 2.05, g.cz), g.label, 11, bold: true);
    }
    for (final e in lojaEstantes) {
      _label(canvas, Vec3(e.cx, 2.15, e.cz), e.label, 9, bold: false);
    }
  }

  void _label(Canvas canvas, Vec3 world, String text, double fontSize, {required bool bold}) {
    final d  = world - _eye;
    final cz = d.dot(_fwd);
    if (cz < _near) return;
    final screen = _toScreen(world);
    if (screen.dx < 0 || screen.dx > _w || screen.dy < 0 || screen.dy > _h) return;

    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          shadows: const [Shadow(blurRadius: 2, color: Colors.black)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(LojaPainter old) =>
      old.camera.rotY != camera.rotY ||
      old.camera.rotX != camera.rotX ||
      old.camera.dist != camera.dist ||
      old.selected    != selected;
}

// ──────────────────────────────────────────────────────────────────────────────
// LojaScene — orbit camera + tap-to-select
// ──────────────────────────────────────────────────────────────────────────────

class LojaScene extends StatefulWidget {
  final LojaItem? selected;
  final void Function(LojaItem item)? onSelect;

  const LojaScene({super.key, this.selected, this.onSelect});

  @override
  State<LojaScene> createState() => _LojaSceneState();
}

class _LojaSceneState extends State<LojaScene> {
  Camera _camera = const Camera(
    rotY: -0.3,
    rotX: 0.52,
    dist: 36.0,
    target: Vec3(0, 1.0, 0),
  );
  final _key = GlobalKey();

  Offset? _gestureOrigin;
  Camera? _camStart;
  bool    _dragging = false;

  static const _dragThreshold = 7.0;

  void _onScaleStart(ScaleStartDetails d) {
    _gestureOrigin = d.focalPoint;
    _camStart      = _camera;
    _dragging      = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final o  = _gestureOrigin;
    final c0 = _camStart;
    if (o == null || c0 == null) return;
    final delta = d.focalPoint - o;
    if (delta.distance > _dragThreshold || (d.scale - 1.0).abs() > 0.02) {
      _dragging = true;
    }
    setState(() {
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.007,
        rotX: (c0.rotX + delta.dy * 0.007).clamp(0.15, math.pi / 2 - 0.05),
        dist: (c0.dist / d.scale).clamp(10.0, 65.0),
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (!_dragging && _gestureOrigin != null) {
      _handleTap(_gestureOrigin!);
    }
    _gestureOrigin = null;
    _camStart      = null;
    _dragging      = false;
  }

  void _handleTap(Offset global) {
    final rb = _key.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final hit = _hitTest(rb.globalToLocal(global), rb.size);
    if (hit != null) widget.onSelect?.call(hit);
  }

  /// Ray–AABB intersection (slab method). Returns entry t or null.
  double? _rayBox(Vec3 eye, Vec3 dir, Vec3 bMin, Vec3 bMax) {
    double tMin = 0, tMax = double.infinity;
    for (var axis = 0; axis < 3; axis++) {
      final o  = axis == 0 ? eye.x  : axis == 1 ? eye.y  : eye.z;
      final dv = axis == 0 ? dir.x  : axis == 1 ? dir.y  : dir.z;
      final lo = axis == 0 ? bMin.x : axis == 1 ? bMin.y : bMin.z;
      final hi = axis == 0 ? bMax.x : axis == 1 ? bMax.y : bMax.z;
      if (dv.abs() < 1e-10) {
        if (o < lo || o > hi) return null;
      } else {
        var t0 = (lo - o) / dv;
        var t1 = (hi - o) / dv;
        if (t0 > t1) { final tmp = t0; t0 = t1; t1 = tmp; }
        tMin = math.max(tMin, t0);
        tMax = math.min(tMax, t1);
        if (tMin > tMax) return null;
      }
    }
    return tMin;
  }

  LojaItem? _hitTest(Offset tap, Size size) {
    final eye   = _camera.position;
    final fwd   = (_camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    const fovY = 45.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;

    final ndcX = 2 * tap.dx / size.width  - 1;
    final ndcY = 1 - 2 * tap.dy / size.height;
    final dir  = (right * (ndcX * tanH * aspect) + up * (ndcY * tanH) + fwd).normalized;

    LojaItem? nearest;
    double    nearestT = double.infinity;

    void test(LojaItem item, double hx, double hy, double hz) {
      final t = _rayBox(
        eye, dir,
        Vec3(item.cx - hx, 0,       item.cz - hz),
        Vec3(item.cx + hx, hy * 2,  item.cz + hz),
      );
      if (t != null && t > 0.1 && t < nearestT) {
        nearestT = t;
        nearest  = item;
      }
    }

    for (final g in lojaGondolas) { test(g, 1.6, 0.9, 0.5); }
    for (final e in lojaEstantes) {
      if (e.cx.abs() > 10) { test(e, 0.3, 1.0, 2.2); }
      else                  { test(e, 5.0, 1.0, 0.3); }
    }

    return nearest;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        key:     _key,
        painter: LojaPainter(_camera, selected: widget.selected),
        child:   const SizedBox.expand(),
      ),
    );
  }
}
