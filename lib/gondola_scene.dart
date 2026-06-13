import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Visualizador 3D da gôndola octogonal — renderização por software, 100% Dart.
///
/// Não usa OpenGL/ANGLE nem nenhum plugin nativo: projeta a geometria com um
/// pipeline simples (transform → projeção em perspectiva → ordenação por
/// profundidade → preenchimento de polígonos no Canvas). Isso roda em qualquer
/// aparelho, sem o risco de crash do motor nativo.
class GondolaScene extends StatefulWidget {
  const GondolaScene({super.key});

  @override
  State<GondolaScene> createState() => _GondolaSceneState();
}

class _GondolaSceneState extends State<GondolaScene> {
  // Geometria construída uma única vez.
  late final List<_Face> _faces = _buildGondola();

  // Câmera orbital ao redor do centro da gôndola.
  double _yaw = 0.6; // azimute (arrastar na horizontal)
  double _pitch = 0.42; // elevação (arrastar na vertical)
  double _distance = 16; // zoom (pinça)

  // Estado capturado no início de um gesto de pinça.
  double _startDistance = 16;

  static const double _minDistance = 5;
  static const double _maxDistance = 28;
  static const double _minPitch = 0.08; // não atravessa o chão
  static const double _maxPitch = 1.45; // não vai ao zênite

  void _onScaleStart(ScaleStartDetails d) {
    _startDistance = _distance;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      // Zoom: a escala da pinça encolhe/expande a distância.
      _distance = (_startDistance / d.scale).clamp(_minDistance, _maxDistance);
      // Rotação: o deslocamento do ponto focal gira a câmera.
      _yaw -= d.focalPointDelta.dx * 0.01;
      _pitch = (_pitch + d.focalPointDelta.dy * 0.01)
          .clamp(_minPitch, _maxPitch);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      child: CustomPaint(
        painter: _GondolaPainter(_faces, _yaw, _pitch, _distance),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ─────────────────────────── Geometria ───────────────────────────

/// Vetor 3D mínimo (evita depender de pacotes externos).
class _V3 {
  final double x, y, z;
  const _V3(this.x, this.y, this.z);

  _V3 operator -(_V3 o) => _V3(x - o.x, y - o.y, z - o.z);
  double dot(_V3 o) => x * o.x + y * o.y + z * o.z;
  _V3 cross(_V3 o) =>
      _V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(x * x + y * y + z * z);
  _V3 get normalized {
    final l = length;
    return l == 0 ? this : _V3(x / l, y / l, z / l);
  }
}

/// Face poligonal (3+ vértices coplanares) com uma cor base.
class _Face {
  final List<_V3> verts;
  final Color color;
  const _Face(this.verts, this.color);
}

const _corCorpo = Color(0xFF2E6B46); // verde — corpo das bandejas
const _corColuna = Color(0xFF1F4A30); // verde escuro — colunas e pés
const _corBorda = Color(0xFF4A9D6A); // verde claro — bordas
const _corChao = Color(0xFF12181E); // disco do chão

List<_Face> _buildGondola() {
  final faces = <_Face>[];

  // ── Chão: disco escuro recebendo a gôndola ──
  faces.add(_disc(radius: 9, y: 0, segments: 48, color: _corChao));

  // ── 8 pés cilíndricos na base (raio 2.8) ──
  for (int i = 0; i < 8; i++) {
    final a = i * math.pi / 4;
    _addPrism(
      faces,
      radius: 0.12,
      yBottom: 0,
      yTop: 0.5,
      segments: 8,
      color: _corColuna,
      cx: 2.8 * math.cos(a),
      cz: 2.8 * math.sin(a),
    );
  }

  // ── Andar 1: base (raio 3.4) ──
  _addTray(faces, radius: 3.4, yCenter: 0.675, altura: 0.35);
  _addPrism(faces, radius: 0.28, yBottom: 0.85, yTop: 2.0, segments: 16,
      color: _corColuna);

  // ── Andar 2: meio (raio 2.4) ──
  _addTray(faces, radius: 2.4, yCenter: 2.15, altura: 0.30);
  _addPrism(faces, radius: 0.28, yBottom: 2.30, yTop: 3.30, segments: 16,
      color: _corColuna);

  // ── Andar 3: topo (raio 1.5) ──
  _addTray(faces, radius: 1.5, yCenter: 3.43, altura: 0.26);

  return faces;
}

/// Bandeja octogonal + anel de acabamento mais claro no topo.
void _addTray(List<_Face> faces,
    {required double radius, required double yCenter, required double altura}) {
  const rot = math.pi / 8; // alinha uma face plana para a frente
  _addPrism(faces,
      radius: radius,
      yBottom: yCenter - altura / 2,
      yTop: yCenter + altura / 2,
      segments: 8,
      color: _corCorpo,
      rot: rot);
  _addPrism(faces,
      radius: radius + 0.13,
      yBottom: yCenter + altura / 2,
      yTop: yCenter + altura / 2 + 0.06,
      segments: 8,
      color: _corBorda,
      rot: rot);
}

/// Prisma vertical (cilindro/octógono) com tampas. `cx`/`cz` deslocam o eixo.
void _addPrism(
  List<_Face> faces, {
  required double radius,
  required double yBottom,
  required double yTop,
  required int segments,
  required Color color,
  double cx = 0,
  double cz = 0,
  double rot = 0,
}) {
  final bottom = <_V3>[];
  final top = <_V3>[];
  for (int i = 0; i < segments; i++) {
    final a = rot + i * 2 * math.pi / segments;
    final x = cx + radius * math.cos(a);
    final z = cz + radius * math.sin(a);
    bottom.add(_V3(x, yBottom, z));
    top.add(_V3(x, yTop, z));
  }
  // Laterais
  for (int i = 0; i < segments; i++) {
    final j = (i + 1) % segments;
    faces.add(_Face([bottom[i], bottom[j], top[j], top[i]], color));
  }
  // Tampas
  faces.add(_Face(List.of(top), color));
  faces.add(_Face(List.of(bottom.reversed), color));
}

/// Polígono plano voltado para cima (chão).
_Face _disc(
    {required double radius,
    required double y,
    required int segments,
    required Color color}) {
  final pts = <_V3>[];
  for (int i = 0; i < segments; i++) {
    final a = i * 2 * math.pi / segments;
    pts.add(_V3(radius * math.cos(a), y, radius * math.sin(a)));
  }
  return _Face(pts, color);
}

// ─────────────────────────── Renderer ───────────────────────────

class _RenderFace {
  final List<Offset> pts;
  final double depth;
  final Color color;
  _RenderFace(this.pts, this.depth, this.color);
}

class _GondolaPainter extends CustomPainter {
  final List<_Face> faces;
  final double yaw, pitch, distance;

  _GondolaPainter(this.faces, this.yaw, this.pitch, this.distance);

  static const _target = _V3(0, 1.7, 0);
  static final _lightDir = const _V3(5, 10, 7).normalized;
  static const _fov = 45 * math.pi / 180;
  static const _near = 0.2;
  static const _ambient = 0.45;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF0E1014));
    if (size.width <= 0 || size.height <= 0) return;

    // Posição da câmera em coordenadas esféricas ao redor do alvo.
    final cosP = math.cos(pitch), sinP = math.sin(pitch);
    final camPos = _V3(
      _target.x + distance * cosP * math.sin(yaw),
      _target.y + distance * sinP,
      _target.z + distance * cosP * math.cos(yaw),
    );
    final forward = (_target - camPos).normalized;
    final right = forward.cross(const _V3(0, 1, 0)).normalized;
    final up = right.cross(forward).normalized;

    final f = (size.height / 2) / math.tan(_fov / 2);
    final cxp = size.width / 2, cyp = size.height / 2;

    final items = <_RenderFace>[];
    for (final face in faces) {
      final screen = <Offset>[];
      double sumZ = 0;
      bool ok = true;
      for (final v in face.verts) {
        final rel = v - camPos;
        final cz = rel.dot(forward);
        if (cz < _near) {
          ok = false;
          break;
        }
        final camX = rel.dot(right);
        final camY = rel.dot(up);
        screen.add(Offset(cxp + camX / cz * f, cyp - camY / cz * f));
        sumZ += cz;
      }
      if (!ok) continue;

      // Normal da face, virada para a câmera.
      var normal =
          (face.verts[1] - face.verts[0]).cross(face.verts[2] - face.verts[0]);
      normal = normal.normalized;
      if (normal.dot(camPos - face.verts[0]) < 0) {
        normal = _V3(-normal.x, -normal.y, -normal.z);
      }
      final diffuse = math.max(0.0, normal.dot(_lightDir));
      final shade = (_ambient + (1 - _ambient) * diffuse).clamp(0.0, 1.0);
      final c = face.color;
      final shaded = Color.fromARGB(
        255,
        (c.red * shade).round(),
        (c.green * shade).round(),
        (c.blue * shade).round(),
      );
      items.add(_RenderFace(screen, sumZ / face.verts.length, shaded));
    }

    // Painter's algorithm: desenha do mais distante para o mais próximo.
    items.sort((a, b) => b.depth.compareTo(a.depth));

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final it in items) {
      paint.color = it.color;
      canvas.drawPath(Path()..addPolygon(it.pts, true), paint);
    }
  }

  @override
  bool shouldRepaint(_GondolaPainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.distance != distance ||
      !identical(old.faces, faces);
}
