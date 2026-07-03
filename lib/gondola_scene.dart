import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'models.dart' show faceFromPos, chaveEnderecoEstoque, corConferenciaCiano;

// ──────────────────────────────────────────────────────────────────────────────
// Faces do hexágono — convenção fixa para todas as gôndolas
// ──────────────────────────────────────────────────────────────────────────────
//
// Face 1 = face voltada para a entrada (+Z); numeração horária vista de cima.
// Ângulo central da face k no plano XZ (ângulo = atan2(z, x)).

double faceAngle(int k) => math.pi / 2 - (k - 1) * math.pi / 3;

/// Setor i do prisma (vértices em i·60°, centro de face em 30° + i·60°) → face 1-6.
int sectorToFace(int i) => (((90 - (30 + i * 60)) ~/ 60) % 6 + 6) % 6 + 1;

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
// Badge de endereço desatualizado — indicador discreto e estático (sem
// animação contínua, pra não conflitar com o pulsar de busca da LojaScene).
// ──────────────────────────────────────────────────────────────────────────────

const Color corEnderecoDesatualizado = Color(0xFFffc107);

/// Pequeno triângulo âmbar achatado no canto superior-frontal-direito de uma
/// caixa, levemente elevado do topo para não empatar no depth-sort do
/// pintor com a face de cima.
void addBadgeEnderecoDesatualizado(
  List<Face> faces, {
  required double x1,
  required double y1,
  required double z1,
  required double tamanho,
}) {
  const elevacao = 0.006;
  faces.add(Face([
    Vec3(x1,           y1 + elevacao, z1),
    Vec3(x1 - tamanho, y1 + elevacao, z1),
    Vec3(x1,           y1 + elevacao, z1 - tamanho),
  ], corEnderecoDesatualizado));
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
  static const _corCorpo    = Color(0xFF2e6b46);
  static const _corColuna   = Color(0xFF1f4a30);
  static const _corBorda    = Color(0xFF4a9d6a);
  static const corDestaque  = Color(0xFFe87722);

  // Posição dos labels de face 1-6: um pouco além do anel de borda do andar
  // base, à altura do corpo da prateleira.
  static const double labelDist = 3.4 + 0.13 + 0.55;
  static const double labelY    = 0.675 + 0.15;

  static Vec3 labelPos(int k) => Vec3(
        labelDist * math.cos(faceAngle(k)),
        labelY,
        labelDist * math.sin(faceAngle(k)),
      );

  // yTop = top of shelf surface including the 0.06 accent-ring.
  // This is the Y at which boxes sit and what hit-testing tests against.
  static const List<({double yTop, double r})> andares = [
    (yTop: 0.675 + 0.35 / 2 + 0.06, r: 3.4), // andar 0 — base  (y≈0.91)
    (yTop: 2.15  + 0.30 / 2 + 0.06, r: 2.4), // andar 1 — meio  (y≈2.36)
    (yTop: 3.43  + 0.26 / 2 + 0.06, r: 1.5), // andar 2 — topo  (y≈3.62)
  ];

  /// Builds gondola faces transformed to a map position.
  /// Vertices are scaled uniformly, then translated by (tx, 0, tz).
  static List<Face> buildFacesAt({
    required double scale,
    required double tx,
    required double tz,
    Color Function(Color)? colorMapper,
  }) {
    return buildFaces().map((f) {
      final verts = f.verts
          .map((v) => Vec3(v.x * scale + tx, v.y * scale, v.z * scale + tz))
          .toList();
      return Face(verts, colorMapper != null ? colorMapper(f.color) : f.color);
    }).toList();
  }


  static List<Face> buildFaces({int? faceSelecionada}) {
    final faces = <Face>[];

    // 6 feet nos vértices do hexágono
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      _prism(faces,
          cx: 2.8 * math.cos(a), cz: 2.8 * math.sin(a),
          y0: 0.0, y1: 0.5,
          r: 0.12, sides: 6,
          color: _corColuna);
    }

    // Shelf 0 — base
    _shelf(faces, r: 3.4, yc: 0.675, h: 0.35, faceSel: faceSelecionada);
    _prism(faces, cx: 0, cz: 0, y0: 0.85, y1: 2.0,
        r: 0.28, sides: 6, color: _corColuna);

    // Shelf 1 — meio
    _shelf(faces, r: 2.4, yc: 2.15, h: 0.30, faceSel: faceSelecionada);
    _prism(faces, cx: 0, cz: 0, y0: 2.30, y1: 3.30,
        r: 0.28, sides: 6, color: _corColuna);

    // Shelf 2 — topo
    _shelf(faces, r: 1.5, yc: 3.43, h: 0.26, faceSel: faceSelecionada);

    return faces;
  }

  /// Projeta (x, z) para dentro do hexágono do andar quando o ponto cai fora,
  /// empurrando ao longo da normal da(s) face(s) violada(s). Mantém uma margem
  /// de meia-caixa para a caixa não ficar pendurada na borda.
  static ({double x, double z}) clampAoAndar(int andar, double x, double z) {
    const margem  = 0.2;
    final apotema = andares[andar].r * math.cos(math.pi / 6) - margem;
    var px = x, pz = z;
    for (var i = 0; i < 6; i++) {
      final a  = math.pi / 6 + i * math.pi / 3; // normal da face do setor i
      final nx = math.cos(a), nz = math.sin(a);
      final d  = px * nx + pz * nz;
      if (d > apotema) {
        px -= nx * (d - apotema);
        pz -= nz * (d - apotema);
      }
    }
    return (x: px, z: pz);
  }

  static void _shelf(List<Face> faces,
      {required double r, required double yc, required double h, int? faceSel}) {
    Color destaca(Color base, int i) => faceSel != null && sectorToFace(i) == faceSel
        ? Color.lerp(base, corDestaque, 0.55)!
        : base;
    _prism(faces,
        cx: 0, cz: 0, y0: yc - h / 2, y1: yc + h / 2,
        r: r, sides: 6, color: _corCorpo,
        sideColor: (i) => destaca(_corCorpo, i));
    _prism(faces,
        cx: 0, cz: 0, y0: yc + h / 2, y1: yc + h / 2 + 0.06,
        r: r + 0.13, sides: 6, color: _corBorda,
        sideColor: (i) => destaca(_corBorda, i));
  }

  static void _prism(List<Face> faces, {
    required double cx, required double cz,
    required double y0, required double y1,
    required double r, required int sides,
    required Color color, double rotOff = 0,
    Color Function(int side)? sideColor,
  }) {
    final angles = List.generate(sides, (i) => i * 2 * math.pi / sides + rotOff);

    for (var i = 0; i < sides; i++) {
      final a0 = angles[i], a1 = angles[(i + 1) % sides];
      final x0 = cx + r * math.cos(a0), z0 = cz + r * math.sin(a0);
      final x1 = cx + r * math.cos(a1), z1 = cz + r * math.sin(a1);
      faces.add(Face([
        Vec3(x0, y0, z0), Vec3(x0, y1, z0),
        Vec3(x1, y1, z1), Vec3(x1, y0, z1),
      ], sideColor?.call(i) ?? color));
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
    bool desatualizado = false,
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

    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces, x1: x1, y1: y1, z1: z1, tamanho: w * 0.4);
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// GondolaPainter
// ──────────────────────────────────────────────────────────────────────────────

class GondolaPainter extends CustomPainter {
  final Camera camera;
  final List<Face> extraFaces;
  final int? faceSelecionada;
  // When set, skips buildFaces() and uses this list directly (for the store map).
  final List<Face>? allFacesOverride;

  static final Vec3 _lightDir = Vec3(5, 10, 7).normalized;

  GondolaPainter(this.camera, {
    this.extraFaces = const <Face>[],
    this.faceSelecionada,
    this.allFacesOverride,
  });

  /// Tamanho perspectivo dos labels de face (compartilhado com o hit-test).
  static double labelFontSize(double cz) => 20.0 * (7.0 / cz).clamp(0.6, 1.6);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0e1014));

    final faces = allFacesOverride ??
        (GondolaGeometry.buildFaces(faceSelecionada: faceSelecionada)
          ..addAll(extraFaces));
    _project(faces, size);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
    if (allFacesOverride == null) _drawFaceLabels(canvas, size);
  }

  // Labels 1-6 no padrão visual do EDR-300: disco escuro com borda e texto
  // laranja CAMDA, tamanho perspectivo. Cull + fade quando a face vira de costas.
  void _drawFaceLabels(Canvas canvas, Size size) {
    final eye    = camera.position;
    final fwd    = (camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 45.0 * math.pi / 180.0;
    const near   = 0.1;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;
    final w = size.width, h = size.height;

    const camda = GondolaGeometry.corDestaque;
    const disco = Color(0xFF12161c);

    for (var k = 1; k <= 6; k++) {
      final pos    = GondolaGeometry.labelPos(k);
      final ang    = faceAngle(k);
      final normal = Vec3(math.cos(ang), 0, math.sin(ang));
      final dot    = normal.dot((eye - pos).normalized);
      if (dot <= 0.05) continue;
      final alpha = (dot * 2.2).clamp(0.0, 1.0);

      final d  = pos - eye;
      final cz = d.dot(fwd);
      if (cz <= near) continue;
      final cx     = d.dot(right) / (cz * tanH * aspect);
      final cy     = d.dot(up)    / (cz * tanH);
      final screen = Offset((cx + 1) / 2 * w, (1 - cy) / 2 * h);

      final fontSize = labelFontSize(cz);
      final radius   = fontSize * 0.72;

      canvas.drawCircle(screen, radius,
          Paint()..color = disco.withValues(alpha: 0.92 * alpha));
      canvas.drawCircle(screen, radius,
          Paint()
            ..color       = camda.withValues(alpha: alpha)
            ..style       = PaintingStyle.stroke
            ..strokeWidth = 2.0);

      final tp = TextPainter(
        text: TextSpan(
          text: '$k',
          style: TextStyle(
            color:      camda.withValues(alpha: alpha),
            fontSize:   fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }
  }

  void _project(List<Face> faces, Size size) {
    final eye   = camera.position;
    final fwd   = (camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    const fovY = 45.0 * math.pi / 180.0;
    const near = 0.1;
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

    // Sutherland-Hodgman clip against near plane (cz >= near)
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
      f.depth = clipped.fold(0.0, (s, v) => s + (v - eye).dot(fwd)) /
          clipped.length;

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
  bool shouldRepaint(GondolaPainter old) {
    if (allFacesOverride != null || old.allFacesOverride != null) return true;
    return old.camera.rotY != camera.rotY ||
        old.camera.rotX != camera.rotX ||
        old.camera.dist != camera.dist ||
        old.faceSelecionada != faceSelecionada ||
        old.extraFaces  != extraFaces;
  }
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
  final int? faceSelecionada;
  // andar é null quando a seleção veio de um label (que não pertence a andar).
  final void Function(int face, int? andar)? onFaceTap;
  // Quando muda para um valor não-nulo, a câmera gira para olhar essa face.
  final int? faceParaCamera;
  // Chaves (chaveEnderecoEstoque) dos endereços desatualizados — carregado
  // uma vez ao abrir a cena; o painter só desenha, sem consultar o service.
  final Set<String> desatualizados;
  // Códigos destacados pelo Modo Conferência (Fase 3) — generalização de
  // destacadoCodigo para acender várias caixas de uma vez, vindas de fora
  // (não da busca). Cor própria (ciano) pra não se confundir com a busca.
  final Set<String> destacadosCodigos;

  const GondolaScene({
    super.key,
    required this.gondolaAtual,
    this.caixas = const [],
    this.produtoSelecionadoId,
    this.corPorProduto = const {},
    this.onTapAndar,
    this.destacadoCodigo,
    this.faceSelecionada,
    this.onFaceTap,
    this.faceParaCamera,
    this.desatualizados = const {},
    this.destacadosCodigos = const {},
  });

  @override
  State<GondolaScene> createState() => _GondolaSceneState();
}

class _GondolaSceneState extends State<GondolaScene> {
  Camera _camera = const Camera();
  final  _painterKey = GlobalKey();

  // Câmera de frente para a face k: posição ao longo da normal da face.
  // position() usa (sin(rotY), cos(rotY)), então rotY = pi/2 - faceAngle(k).
  static double _rotYParaFace(int k) => (k - 1) * math.pi / 3;

  @override
  void initState() {
    super.initState();
    final f = widget.faceParaCamera;
    if (f != null) _camera = _camera.copyWith(rotY: _rotYParaFace(f));
  }

  @override
  void didUpdateWidget(GondolaScene old) {
    super.didUpdateWidget(old);
    final f = widget.faceParaCamera;
    if (f != null && f != old.faceParaCamera) {
      _camera = _camera.copyWith(rotY: _rotYParaFace(f));
    }
  }

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
      _handleTap(_gestureOrigin!);
    }
    _gestureOrigin        = null;
    _cameraAtGestureStart = null;
    _isDragging           = false;
  }

  void _handleTap(Offset globalTap) {
    final rb = _painterKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final local = rb.globalToLocal(globalTap);

    // 1) Label de face 1-6 (hit circular)
    final labelFace = _hitTestLabel(local, rb.size);
    if (labelFace != null) {
      widget.onFaceTap?.call(labelFace, null);
      return;
    }

    // 2) Prateleira: coloca caixa (se há produto ativo) ou seleciona a face
    //    derivada do atan2 do ponto de interseção.
    final hit = _hitTest(local, rb.size);
    if (hit == null) return;
    if (widget.onTapAndar != null && widget.produtoSelecionadoId != null) {
      widget.onTapAndar!(hit.andar, hit.x, hit.z);
    } else {
      widget.onFaceTap?.call(faceFromPos(hit.x, hit.z), hit.andar);
    }
  }

  /// Hit circular nos labels de face (raio do disco + 8px de folga),
  /// respeitando o mesmo culling do desenho.
  int? _hitTestLabel(Offset tap, Size size) {
    final eye    = _camera.position;
    final fwd    = (_camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 45.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;

    int?   best;
    double bestCz = double.infinity;

    for (var k = 1; k <= 6; k++) {
      final pos    = GondolaGeometry.labelPos(k);
      final ang    = faceAngle(k);
      final normal = Vec3(math.cos(ang), 0, math.sin(ang));
      if (normal.dot((eye - pos).normalized) <= 0.05) continue;

      final d  = pos - eye;
      final cz = d.dot(fwd);
      if (cz <= 0.1) continue;
      final cx     = d.dot(right) / (cz * tanH * aspect);
      final cy     = d.dot(up)    / (cz * tanH);
      final screen = Offset((cx + 1) / 2 * size.width,
                            (1 - cy) / 2 * size.height);

      final radius = GondolaPainter.labelFontSize(cz) * 0.72 + 8;
      if ((tap - screen).distance <= radius && cz < bestCz) {
        best   = k;
        bestCz = cz;
      }
    }
    return best;
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

      // Conservative hexagon check: point must be inside 90% of the apothem
      // on every one of the 6 faces (normais em 30° + i·60°).
      final apotema = shelf.r * math.cos(math.pi / 6) * 0.90;
      var dentro = true;
      for (var f = 0; f < 6 && dentro; f++) {
        final a = math.pi / 6 + f * math.pi / 3;
        if (hx * math.cos(a) + hz * math.sin(a) > apotema) dentro = false;
      }
      if (dentro) {
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
      final isConferencia = widget.destacadosCodigos.contains(caixa.produtoId);
      final isHighlighted = caixa.produtoId == widget.destacadoCodigo;
      final cor = isConferencia
          ? corConferenciaCiano
          : isHighlighted
              ? const Color(0xFFe87722)
              : (widget.corPorProduto[caixa.produtoId] ?? const Color(0xFF888888));
      final shelf = GondolaGeometry.andares[caixa.andar];
      final chave = chaveEnderecoEstoque(
        produtoCodigo: caixa.produtoId,
        localTipo:     'gondola',
        localNum:      widget.gondolaAtual,
        faceOuColuna:  faceFromPos(caixa.x, caixa.z),
        andarOuNivel:  caixa.andar,
      );
      GondolaGeometry.addBox(extraFaces,
          cx: caixa.x, cy: shelf.yTop, cz: caixa.z, color: cor,
          desatualizado: widget.desatualizados.contains(chave));
    }

    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        key:     _painterKey,
        painter: GondolaPainter(_camera,
            extraFaces:      extraFaces,
            faceSelecionada: widget.faceSelecionada),
        child:   const SizedBox.expand(),
      ),
    );
  }
}
