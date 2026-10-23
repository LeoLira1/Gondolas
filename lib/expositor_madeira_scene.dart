import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'gondola_scene.dart'
    show Vec3, Camera, Face, addBadgeEnderecoDesatualizado, corEnderecoDivergente,
        corEnderecoDivergentePositiva;
import 'models.dart'
    show CaixaColocadaEstante, chaveEnderecoEstoque, corConferenciaCiano,
         expositorMadeiraNum, letraEstanteCelula;
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Expositor de Madeira — escada de 3 degraus maciça, encostada no Balcão de
// Atendimento pelo lado do corredor (o degrau mais alto fica colado no
// balcão, o mais baixo virado para o cliente). 1 m de comprimento ao longo do
// balcão e 1 m de altura no degrau de cima; a profundidade total (0,40 m, três
// pisos de ~13 cm) é estimada — ajuste em [ExpositorMadeiraGeometry.depth] e
// no w do item no mapa (itensLoja), que é o que o corredor do cliente aguenta.
//
// São 18 endereços em 3 degraus × 6 produtos, slot = 0 sempre, reaproveitando
// o esquema (coluna, nivel, slot) do estante_layout na Turso como "estante"
// nº expositorMadeiraNum:
//   nível 0 = degrau de baixo (o da frente) — letras M–R
//   nível 1 = degrau do meio                 — letras G–L
//   nível 2 = degrau de cima (o do fundo)   — letras A–F
//
// Letras contínuas de cima pra baixo, como nas estantes de madeira: sai do
// fallback de letraEstanteCelula, sem caso especial.
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMadeiraCell {
  final int    coluna;
  final int    nivel;      // 0 = degrau de baixo, 2 = degrau de cima
  final double xCenter;    // centro da coluna em X
  final double ySurface;   // piso do degrau

  const ExpositorMadeiraCell({
    required this.coluna,
    required this.nivel,
    required this.xCenter,
    required this.ySurface,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorMadeiraGeometry — 3 blocos empilhados, cada um mais raso que o de
// baixo, com um tampo de madeira mais clara em cada piso
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMadeiraGeometry {
  final double width;      // comprimento ao longo do balcão (m)
  final double height;     // altura do degrau de cima (m)
  final double depth;      // profundidade total, do balcão ao corredor (m)
  final bool   showFloor;

  const ExpositorMadeiraGeometry({
    this.width     = 1.00,
    this.height    = 1.00,
    this.depth     = 0.40,
    this.showFloor = true,
  });

  static const int niveis  = 3;
  static const int colunas = 6;

  // ── Dimensões dos produtos (caixas apoiadas, uma por endereço) ─────────────
  static const double wCaixa = 0.13;
  static const double hCaixa = 0.15;
  static const double dCaixa = 0.11;

  // ── Estrutura ──────────────────────────────────────────────────────────────
  static const double _tampoT   = 0.02;   // tampo de cada piso
  static const double _tampoAba = 0.012;  // quanto o tampo avança sobre o espelho
  static const double _margemX  = 0.03;   // folga entre a 1ª caixa e a ponta

  // ── Paleta (madeira crua) ──────────────────────────────────────────────────
  static const _madeira      = Color(0xFF9c6b3c);  // espelhos e laterais
  static const _madeiraClara = Color(0xFFc8965e);  // tampos dos pisos
  static const _floor        = Color(0xFF12161d);

  double get _passoY => height / niveis;
  double get _piso   => depth / niveis;

  // Y da superfície de apoio do degrau (topo do tampo).
  double nivelY(int nivel) => _passoY * (nivel + 1);

  // Frente do degrau em Z: o de baixo vai até a frente do expositor, cada um
  // acima recua um piso. O fundo (encostado no balcão) é sempre -depth/2.
  double zFrenteNivel(int nivel) => depth / 2 - _piso * nivel;

  // X do centro da coluna c — 6 colunas no comprimento útil.
  double colunaX(int c) {
    final util = width - _margemX * 2 - wCaixa;
    final xMin = -util / 2;
    return colunas > 1 ? xMin + util * c / (colunas - 1) : 0;
  }

  List<ExpositorMadeiraCell> get cells => [
        for (var niv = 0; niv < niveis; niv++)
          for (var col = 0; col < colunas; col++)
            ExpositorMadeiraCell(
              coluna:   col,
              nivel:    niv,
              xCenter:  colunaX(col),
              ySurface: nivelY(niv),
            ),
      ];

  // ── Caixa apoiada no piso do degrau, encostada na frente dele ──────────────
  void addCaixaProduto(
    List<Face> faces, {
    required ExpositorMadeiraCell celula,
    required Color color,
    bool desatualizado = false,
  }) {
    final xc = celula.xCenter;
    final y0 = celula.ySurface;
    final z1 = zFrenteNivel(celula.nivel) - 0.015;
    final d  = math.min(dCaixa, _piso - 0.03);
    _box(faces,
      x0: xc - wCaixa / 2, x1: xc + wCaixa / 2,
      y0: y0,               y1: y0 + hCaixa,
      z0: z1 - d,           z1: z1,
      color: color);
    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces,
          x1: xc + wCaixa / 2, y1: y0 + hCaixa, z1: z1, tamanho: wCaixa * 0.45);
    }
  }

  List<Face> buildFaces() {
    final faces = <Face>[];

    if (showFloor) {
      const s = 2.0;
      faces.add(Face([
        Vec3(-s, -0.001, -s), Vec3(-s, -0.001,  s),
        Vec3( s, -0.001,  s), Vec3( s, -0.001, -s),
      ], _floor));
    }

    final hw = width / 2;
    final zFundo = -depth / 2;

    // Um bloco por degrau, empilhados sem se sobrepor (o painter ordena por
    // profundidade de face; volumes encaixados brigariam no depth-sort). Cada
    // bloco vai do piso do degrau de baixo até o tampo, e o tampo cobre o
    // bloco inteiro — o degrau de cima apoia nele.
    for (var niv = 0; niv < niveis; niv++) {
      final y0 = niv == 0 ? 0.0 : nivelY(niv - 1);
      final yT = nivelY(niv) - _tampoT;
      final zF = zFrenteNivel(niv);
      _box(faces,
        x0: -hw,    x1: hw,
        y0: y0,     y1: yT,
        z0: zFundo, z1: zF,
        color: _madeira);
      _box(faces,
        x0: -hw - 0.005, x1: hw + 0.005,
        y0: yT,           y1: nivelY(niv),
        z0: zFundo,       z1: zF + _tampoAba,
        color: _madeiraClara);
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
// ExpositorMadeiraPainter
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMadeiraPainter extends CustomPainter {
  final Camera                   camera;
  final ExpositorMadeiraGeometry geometry;
  final bool                     wireframe;
  final bool                     showLabels;
  final List<Face>               extraFaces;

  static final Vec3 _lightDir = Vec3(4, 10, 5).normalized;

  const ExpositorMadeiraPainter(this.camera, this.geometry, {
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

      final rotulo = letraEstanteCelula(expositorMadeiraNum, c.coluna, c.nivel);
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
  bool shouldRepaint(ExpositorMadeiraPainter old) =>
      old.camera.rotY        != camera.rotY        ||
      old.camera.rotX        != camera.rotX        ||
      old.camera.dist        != camera.dist        ||
      old.wireframe          != wireframe          ||
      old.showLabels         != showLabels         ||
      old.extraFaces         != extraFaces         ||
      old.geometry.width     != geometry.width     ||
      old.geometry.height    != geometry.height    ||
      old.geometry.depth     != geometry.depth     ||
      old.geometry.showFloor != geometry.showFloor;
}

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorMadeiraScene — 3D interativo com suporte a produtos
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMadeiraScene extends StatefulWidget {
  final ExpositorMadeiraGeometry geometry;
  final bool                     wireframe;
  final bool                     autoRotate;
  final bool                     showLabels;
  // Reutiliza CaixaColocadaEstante: coluna = coluna, nivel = degrau (0 = de
  // baixo, 2 = de cima), slot = 0 sempre (um produto por endereço).
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

  const ExpositorMadeiraScene({
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
  State<ExpositorMadeiraScene> createState() =>
      _ExpositorMadeiraSceneState();
}

class _ExpositorMadeiraSceneState extends State<ExpositorMadeiraScene>
    with SingleTickerProviderStateMixin, SceneGestureGuard<ExpositorMadeiraScene> {
  late Ticker _ticker;
  late Camera _camera;

  final _painterKey = GlobalKey();
  Camera? _cameraAtStart;

  @override
  void initState() {
    super.initState();
    _camera = Camera(
      rotY:   0.45,
      rotX:   0.32,
      dist:   2.6,
      target: Vec3(0, widget.geometry.height / 2, 0),
    );
    _ticker = createTicker((_) {
      if (widget.autoRotate) {
        setState(() => _camera = _camera.copyWith(rotY: _camera.rotY + 0.0025));
      }
    })..start();
  }

  @override
  void didUpdateWidget(ExpositorMadeiraScene old) {
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
        dist: (c0.dist / d.scale).clamp(1.0, 7.0),
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

  // Hit-test: cada degrau tem seu próprio plano frontal (o de baixo avança
  // mais), então o raio do toque é intersectado plano a plano e testado contra
  // a área clicável das células daquele degrau — mesma técnica do Monitor.
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
      final yMax = c.ySurface + ExpositorMadeiraGeometry.hCaixa + 0.06;

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
        localNum:      expositorMadeiraNum,
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
          painter: ExpositorMadeiraPainter(_camera, widget.geometry,
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
// Miniatura do expositor pro mapa da loja (LojaScene). No mapa ele fica de
// lado: o comprimento corre em Z (ao longo do balcão) e os degraus descem em
// +X, do balcão para o corredor. [w] é a profundidade em X e [d] o
// comprimento. Chamada no switch de tipos em buildFaces da LojaGeometry:
//
//   } else if (item.numero == expositorMadeiraNum) {
//     expositorMadeiraLoja(faces, item.x, item.z, item.w, item.d, cor);
//   }
// ─────────────────────────────────────────────────────────────────────────────

void expositorMadeiraLoja(
  List<Face> faces,
  double cx, double cz, double w, double d,
  Color cor,
) {
  final hw = w / 2, hd = d / 2;
  // 1 m real na escala de altura do mapa: as estantes usam 0,85 para ~1,9 m e
  // o balcão 0,50 para 1,10 m — o expositor fica um pouco abaixo do balcão.
  const h = 0.45;
  const n = ExpositorMadeiraGeometry.niveis;
  final corTampo = Color.lerp(cor, Colors.white, 0.25)!;

  void box(double x0, double x1, double y0, double y1,
           double z0, double z1, Color c) {
    faces.add(Face([Vec3(x0,y1,z0), Vec3(x0,y1,z1), Vec3(x1,y1,z1), Vec3(x1,y1,z0)], c));
    faces.add(Face([Vec3(x0,y0,z1), Vec3(x1,y0,z1), Vec3(x1,y1,z1), Vec3(x0,y1,z1)], c));
    faces.add(Face([Vec3(x1,y0,z0), Vec3(x0,y0,z0), Vec3(x0,y1,z0), Vec3(x1,y1,z0)], c));
    faces.add(Face([Vec3(x1,y0,z1), Vec3(x1,y0,z0), Vec3(x1,y1,z0), Vec3(x1,y1,z1)], c));
    faces.add(Face([Vec3(x0,y0,z0), Vec3(x0,y0,z1), Vec3(x0,y1,z1), Vec3(x0,y1,z0)], c));
  }

  // Encostado no balcão em x = cx - hw; cada degrau recua um piso em direção
  // a ele. O tampo claro marca o piso de cada degrau.
  final xBalcao = cx - hw;
  const tampoT = 0.02;
  for (var k = 0; k < n; k++) {
    final xFrente = xBalcao + w * (n - k) / n;
    final y0 = h * k / n, y1 = h * (k + 1) / n;
    box(xBalcao, xFrente, y0, y1 - tampoT, cz - hd, cz + hd, cor);
    box(xBalcao, xFrente, y1 - tampoT, y1, cz - hd, cz + hd, corTampo);
  }
}
