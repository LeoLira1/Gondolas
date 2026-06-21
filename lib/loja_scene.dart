import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'gondola_scene.dart' show Vec3, Camera;

// ── Data classes ──────────────────────────────────────────────────────────────

class ItemLoja {
  final String tipo;   // 'gondola' ou 'estante'
  final int numero;
  final double x, z;
  final double w, d;
  final double rotacao;

  const ItemLoja({
    required this.tipo,
    required this.numero,
    required this.x,
    required this.z,
    this.w = 0.7,
    this.d = 1.6,
    this.rotacao = 0,
  });
}

class ProdutoLoja {
  final String nome;
  final String tipo;   // 'gondola' ou 'estante'
  final int numero;
  final String nivel;

  const ProdutoLoja({
    required this.nome,
    required this.tipo,
    required this.numero,
    required this.nivel,
  });
}

// ── Layout fixo da loja (posições do protótipo HTML) ─────────────────────────

const double lojaW = 10.0;
const double lojaH = 14.0;

const List<ItemLoja> itensLoja = [
  // 12 gôndolas
  ItemLoja(tipo: 'gondola', numero: 12, x: 2.0, z:  4.0),
  ItemLoja(tipo: 'gondola', numero:  7, x: 4.0, z:  4.0),
  ItemLoja(tipo: 'gondola', numero:  5, x: 6.0, z:  4.0),
  ItemLoja(tipo: 'gondola', numero: 11, x: 2.0, z:  6.0),
  ItemLoja(tipo: 'gondola', numero:  4, x: 6.0, z:  6.0),
  ItemLoja(tipo: 'gondola', numero: 10, x: 2.0, z:  8.0),
  ItemLoja(tipo: 'gondola', numero:  3, x: 6.0, z:  8.0),
  ItemLoja(tipo: 'gondola', numero:  9, x: 2.0, z: 10.0),
  ItemLoja(tipo: 'gondola', numero:  2, x: 6.0, z: 10.0),
  ItemLoja(tipo: 'gondola', numero:  8, x: 2.0, z: 12.0),
  ItemLoja(tipo: 'gondola', numero:  6, x: 4.0, z: 12.0),
  ItemLoja(tipo: 'gondola', numero:  1, x: 6.0, z: 12.0),
  // 7 estantes encostadas nas paredes
  ItemLoja(tipo: 'estante', numero: 7, x: 1.00, z:  1.0, w: 0.7, d: 1.6),
  ItemLoja(tipo: 'estante', numero: 6, x: 2.10, z:  1.0, w: 0.7, d: 1.6),
  ItemLoja(tipo: 'estante', numero: 2, x: 9.45, z:  2.0, w: 0.7, d: 1.6),
  ItemLoja(tipo: 'estante', numero: 1, x: 9.45, z:  4.0, w: 0.7, d: 1.6),
  ItemLoja(tipo: 'estante', numero: 5, x: 0.55, z:  7.6, w: 0.7, d: 1.6),
  ItemLoja(tipo: 'estante', numero: 4, x: 0.55, z:  9.6, w: 0.7, d: 1.6),
  ItemLoja(tipo: 'estante', numero: 3, x: 0.55, z: 11.6, w: 0.7, d: 1.6),
];

// Catálogo mock — substituir por query Turso quando disponível
const List<ProdutoLoja> catalogoLojaFake = [
  ProdutoLoja(nome: 'CHINCHA P/ARREIO 2 ARGOLAS PASFIL C099', tipo: 'gondola', numero: 11, nivel: 'Andar Base'),
  ProdutoLoja(nome: 'HERBICIDA NORTOX 2,4-D 806 SL 5L',       tipo: 'gondola', numero:  5, nivel: 'Andar 2'),
  ProdutoLoja(nome: 'FUNGICIDA OUROFINO AZOX 200 1L',         tipo: 'gondola', numero:  7, nivel: 'Andar 1'),
  ProdutoLoja(nome: 'ADUBO FOLIAR ZOETIS BORO 20L',           tipo: 'estante', numero:  4, nivel: 'Nível 2'),
  ProdutoLoja(nome: 'SEMENTE MILHO HIBRIDO SC 60kg',          tipo: 'estante', numero:  3, nivel: 'Nível 1'),
  ProdutoLoja(nome: 'INSETICIDA FMC LANNATE BR 1L',           tipo: 'gondola', numero:  9, nivel: 'Andar Base'),
  ProdutoLoja(nome: 'CORDA SISAL 10MM ROLO 50M',              tipo: 'estante', numero:  6, nivel: 'Nível 3'),
  ProdutoLoja(nome: 'LUVA NITRILICA PROTECAO PAR',            tipo: 'estante', numero:  1, nivel: 'Nível 4'),
  ProdutoLoja(nome: 'FERTILIZANTE NPK 04-14-08 SC 50kg',      tipo: 'gondola', numero:  3, nivel: 'Andar 1'),
  ProdutoLoja(nome: 'BALDE PLASTICO 20L AZUL',                tipo: 'gondola', numero:  2, nivel: 'Andar Base'),
];

// ── Colors ────────────────────────────────────────────────────────────────────

const Color corGondolaLoja = Color(0xFFe0944a);
const Color corEstanteLoja = Color(0xFF4a93d8);
const Color _corApagado    = Color(0xFF2d2e31);
const Color _corPiso       = Color(0xFF17181b);
const Color _corParede     = Color(0xFF2a2b2f);
const Color _corBg         = Color(0xFF0b0c0e);

// ── Internal face class (independent of gondola_scene.dart's Face) ────────────

class _Face {
  final List<Vec3> verts;
  final Color color;
  double depth = 0;
  List<Offset> proj = const [];
  double light = 1.0;
  _Face(this.verts, this.color);
}

// ── LojaGeometry ──────────────────────────────────────────────────────────────

class LojaGeometry {
  static const double gondolaR   = 0.62;
  static const double _gondolaH  = 0.85;
  static const double _estanteH  = 0.85;
  static const double _paredeH   = 0.90;
  static const double _paredeEsp = 0.18;

  static List<_Face> buildFaces(int? selecionadoIdx, double pulseT) {
    final faces = <_Face>[];

    // Piso
    faces.add(_Face([
      Vec3(0, 0, 0), Vec3(0, 0, lojaH),
      Vec3(lojaW, 0, lojaH), Vec3(lojaW, 0, 0),
    ], _corPiso));

    // Paredes perimetrais
    _wallBox(faces, 0, _paredeEsp, 0, lojaH);
    _wallBox(faces, 0, lojaW, 0, _paredeEsp);
    _wallBox(faces, 0, lojaW, lojaH - _paredeEsp, lojaH);
    _wallBox(faces, lojaW - _paredeEsp, lojaW, 0, lojaH);

    // Estruturas
    for (var i = 0; i < itensLoja.length; i++) {
      final item   = itensLoja[i];
      final isSel  = selecionadoIdx == i;
      final hasSel = selecionadoIdx != null;

      final Color cor;
      if (!hasSel) {
        cor = item.tipo == 'gondola' ? corGondolaLoja : corEstanteLoja;
      } else if (isSel) {
        final base  = item.tipo == 'gondola' ? corGondolaLoja : corEstanteLoja;
        final pulse = (0.35 + 0.25 * math.sin(pulseT * 2.2)).clamp(0.0, 1.0);
        cor = Color.lerp(base, Colors.white, pulse * 0.35)!;
      } else {
        cor = _corApagado;
      }

      if (item.tipo == 'gondola') {
        _gondola(faces, item, cor);
      } else {
        _estante(faces, item, cor);
      }
    }

    return faces;
  }

  static void _wallBox(List<_Face> f, double x0, double x1, double z0, double z1) {
    const h = _paredeH;
    const c = _corParede;
    f.add(_Face([Vec3(x0,0,z1), Vec3(x1,0,z1), Vec3(x1,h,z1), Vec3(x0,h,z1)], c));
    f.add(_Face([Vec3(x1,0,z0), Vec3(x0,0,z0), Vec3(x0,h,z0), Vec3(x1,h,z0)], c));
    f.add(_Face([Vec3(x0,0,z0), Vec3(x0,0,z1), Vec3(x0,h,z1), Vec3(x0,h,z0)], c));
    f.add(_Face([Vec3(x1,0,z1), Vec3(x1,0,z0), Vec3(x1,h,z0), Vec3(x1,h,z1)], c));
    f.add(_Face([Vec3(x0,h,z0), Vec3(x0,h,z1), Vec3(x1,h,z1), Vec3(x1,h,z0)], c));
  }

  static void _gondola(List<_Face> faces, ItemLoja item, Color cor) {
    const sides = 8;
    const r = gondolaR;
    const h = _gondolaH;
    const rot = math.pi / 8;
    final angles = List.generate(sides, (i) => i * 2 * math.pi / sides + rot);

    for (var i = 0; i < sides; i++) {
      final a0 = angles[i], a1 = angles[(i + 1) % sides];
      final x0 = item.x + r * math.cos(a0), z0 = item.z + r * math.sin(a0);
      final x1 = item.x + r * math.cos(a1), z1 = item.z + r * math.sin(a1);
      faces.add(_Face([
        Vec3(x0, 0, z0), Vec3(x0, h, z0),
        Vec3(x1, h, z1), Vec3(x1, 0, z1),
      ], cor));
    }
    faces.add(_Face([
      for (var i = sides - 1; i >= 0; i--)
        Vec3(item.x + r * math.cos(angles[i]), h, item.z + r * math.sin(angles[i])),
    ], cor));
  }

  static void _estante(List<_Face> faces, ItemLoja item, Color cor) {
    final hw = item.w / 2, hd = item.d / 2;
    final x0 = item.x - hw, x1 = item.x + hw;
    final z0 = item.z - hd, z1 = item.z + hd;
    const h = _estanteH;
    faces.add(_Face([Vec3(x0,0,z1), Vec3(x1,0,z1), Vec3(x1,h,z1), Vec3(x0,h,z1)], cor));
    faces.add(_Face([Vec3(x1,0,z0), Vec3(x0,0,z0), Vec3(x0,h,z0), Vec3(x1,h,z0)], cor));
    faces.add(_Face([Vec3(x0,0,z0), Vec3(x0,0,z1), Vec3(x0,h,z1), Vec3(x0,h,z0)], cor));
    faces.add(_Face([Vec3(x1,0,z1), Vec3(x1,0,z0), Vec3(x1,h,z0), Vec3(x1,h,z1)], cor));
    faces.add(_Face([Vec3(x0,h,z0), Vec3(x0,h,z1), Vec3(x1,h,z1), Vec3(x1,h,z0)], cor));
  }
}

// ── LojaPainter ───────────────────────────────────────────────────────────────

class LojaPainter extends CustomPainter {
  final Camera camera;
  final int?   selecionadoIdx;
  final double pulseT;

  static final Vec3 _lightDir = Vec3(5, 10, 7).normalized;

  LojaPainter(this.camera, {this.selecionadoIdx, this.pulseT = 0});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _corBg);
    final faces = LojaGeometry.buildFaces(selecionadoIdx, pulseT);
    _project(faces, size);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
  }

  // Sutherland-Hodgman near-plane clipping fixes the disappearing-face bug
  // that occurred when any vertex crossed behind the camera near plane.
  void _project(List<_Face> faces, Size size) {
    final eye    = camera.position;
    final fwd    = (camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 45.0 * math.pi / 180.0;
    const near   = 0.1;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;
    final w = size.width, h = size.height;

    Offset toScreen(Vec3 v) {
      final d  = v - eye;
      final cz = d.dot(fwd);
      final cx = d.dot(right) / (cz * tanH * aspect);
      final cy = d.dot(up)    / (cz * tanH);
      return Offset((cx + 1) / 2 * w, (1 - cy) / 2 * h);
    }

    List<Vec3> clipNear(List<Vec3> verts) {
      final out = <Vec3>[];
      final len = verts.length;
      for (var i = 0; i < len; i++) {
        final a = verts[i];
        final b = verts[(i + 1) % len];
        final da = (a - eye).dot(fwd);
        final db = (b - eye).dot(fwd);
        if (da >= near) out.add(a);
        if ((da >= near) != (db >= near)) {
          final t = (near - da) / (db - da);
          out.add(Vec3(
            a.x + (b.x - a.x) * t,
            a.y + (b.y - a.y) * t,
            a.z + (b.z - a.z) * t,
          ));
        }
      }
      return out;
    }

    for (final f in faces) {
      final clipped = clipNear(f.verts);
      if (clipped.length < 3) {
        f.proj  = const [];
        f.depth = -1e9;
        continue;
      }
      f.proj  = clipped.map(toScreen).toList();
      f.depth = clipped.fold(0.0, (s, v) => s + (v - eye).dot(fwd)) / clipped.length;
      if (f.verts.length >= 3) {
        final n = (f.verts[1] - f.verts[0])
            .cross(f.verts[2] - f.verts[0])
            .normalized;
        f.light = 0.35 + 0.65 * n.dot(_lightDir).clamp(0.0, 1.0);
      }
    }
  }

  void _draw(Canvas canvas, List<_Face> faces) {
    final fill   = Paint();
    final stroke = Paint()
      ..color       = const Color(0x44000000)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 0.6;

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

  @override
  bool shouldRepaint(LojaPainter old) =>
      old.camera.rotY     != camera.rotY     ||
      old.camera.rotX     != camera.rotX     ||
      old.camera.dist     != camera.dist     ||
      old.camera.target.x != camera.target.x ||
      old.camera.target.z != camera.target.z ||
      old.selecionadoIdx  != selecionadoIdx  ||
      (old.pulseT - pulseT).abs() > 0.001;
}

// ── LojaScene ─────────────────────────────────────────────────────────────────

class LojaScene extends StatefulWidget {
  final int?                       selecionadoIdx;
  final void Function(int? idx)    onSelecionado;
  final void Function(int idx)?    onVerDetalhes;
  final Vec3?                      focarEm;

  const LojaScene({
    super.key,
    this.selecionadoIdx,
    required this.onSelecionado,
    this.onVerDetalhes,
    this.focarEm,
  });

  @override
  State<LojaScene> createState() => _LojaSceneState();
}

class _LojaSceneState extends State<LojaScene> with TickerProviderStateMixin {
  Camera _camera = Camera(
    rotY:   0.4,
    rotX:   0.85,
    dist:   17.0,
    target: Vec3(lojaW / 2, 0.2, lojaH / 2),
  );

  final _key = GlobalKey();
  Offset? _gestureOrigin;
  Camera? _cam0;
  bool    _isDragging = false;
  static const double _kDrag = 7.0;

  late final Ticker _ticker;
  double _pulseT = 0;

  Vec3?  _animFrom, _animTo, _lastFocarEm;
  double _animP = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    if (widget.focarEm != null) {
      _lastFocarEm = widget.focarEm;
      _animFrom    = _camera.target;
      _animTo      = widget.focarEm!;
      _animP       = 0;
    }
  }

  @override
  void didUpdateWidget(LojaScene old) {
    super.didUpdateWidget(old);
    final f = widget.focarEm;
    if (f != null) {
      final prev = _lastFocarEm;
      if (prev == null || prev.x != f.x || prev.y != f.y || prev.z != f.z) {
        _lastFocarEm = f;
        _animFrom    = _camera.target;
        _animTo      = f;
        _animP       = 0;
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    if (!mounted) return;
    bool dirty = false;

    if (widget.selecionadoIdx != null) {
      _pulseT += 0.04;
      dirty = true;
    }

    if (_animTo != null) {
      _animP = (_animP + 0.04).clamp(0.0, 1.0);
      final e   = 1 - math.pow(1 - _animP, 3).toDouble(); // ease-out cubic
      final frm = _animFrom!, to = _animTo!;
      _camera = Camera(
        rotY:   _camera.rotY,
        rotX:   _camera.rotX,
        dist:   _camera.dist,
        target: Vec3(
          frm.x + (to.x - frm.x) * e,
          frm.y + (to.y - frm.y) * e,
          frm.z + (to.z - frm.z) * e,
        ),
      );
      if (_animP >= 1.0) _animTo = null;
      dirty = true;
    }

    if (dirty) setState(() {});
  }

  // ── Gestures ──────────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    _gestureOrigin = d.focalPoint;
    _cam0          = _camera;
    _isDragging    = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_gestureOrigin == null || _cam0 == null) return;
    final delta = d.focalPoint - _gestureOrigin!;
    if (delta.distance > _kDrag || (d.scale - 1.0).abs() > 0.02) {
      _isDragging = true;
    }
    setState(() {
      _camera = Camera(
        rotY:   _cam0!.rotY - delta.dx * 0.006,
        rotX:   (_cam0!.rotX + delta.dy * 0.006).clamp(0.25, 1.45),
        dist:   (_cam0!.dist / d.scale).clamp(6.0, 28.0),
        target: _camera.target,
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (!_isDragging && _gestureOrigin != null) {
      _tryHitTest(_gestureOrigin!);
    }
    _gestureOrigin = null;
    _cam0          = null;
    _isDragging    = false;
  }

  void _tryHitTest(Offset globalTap) {
    final rb = _key.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final idx = _hitTest(rb.globalToLocal(globalTap), rb.size);
    if (idx != null && idx == widget.selecionadoIdx) {
      widget.onVerDetalhes?.call(idx);
    } else {
      widget.onSelecionado(idx);
    }
  }

  int? _hitTest(Offset tap, Size size) {
    final eye    = _camera.position;
    final fwd    = (_camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 45.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;

    final ndcX = 2 * tap.dx / size.width  - 1;
    final ndcY = 1 - 2 * tap.dy / size.height;
    final dir  = (right * (ndcX * tanH * aspect) + up * (ndcY * tanH) + fwd).normalized;

    if (dir.y.abs() < 1e-6) return null;
    const testY = 0.43;
    final t = (testY - eye.y) / dir.y;
    if (t <= 0) return null;

    final hitX = eye.x + t * dir.x;
    final hitZ = eye.z + t * dir.z;

    for (var i = 0; i < itensLoja.length; i++) {
      final item = itensLoja[i];
      if (item.tipo == 'gondola') {
        final dx = hitX - item.x, dz = hitZ - item.z;
        if (dx * dx + dz * dz < LojaGeometry.gondolaR * LojaGeometry.gondolaR) return i;
      } else {
        if ((hitX - item.x).abs() < item.w / 2 &&
            (hitZ - item.z).abs() < item.d / 2) return i;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        key:     _key,
        painter: LojaPainter(
          _camera,
          selecionadoIdx: widget.selecionadoIdx,
          pulseT:         _pulseT,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}
