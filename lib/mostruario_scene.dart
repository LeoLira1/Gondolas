import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'gondola_scene.dart'
    show Vec3, Camera, Face, ProjecaoCamera, addBadgeEnderecoDesatualizado,
        corEnderecoDivergente, corEnderecoDivergentePositiva;
import 'models.dart';
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Mostruário — um palete de ferragens e ferramentas encostado na parede
// ─────────────────────────────────────────────────────────────────────────────
//
// Fica na parede da direita da loja, entre a Estante 1 e a cozinha. Não é
// estante: é um palete de madeira no chão (o mesmo PBR de 1,20 × 1,00 m do
// barracão) com uns 20 tipos de produto à mostra — porcas, arruelas, barras de
// ferro, correntes, pá, rastelo.
//
// 20 POSIÇÕES numeradas de 1 a 20 numa grade de 5 na frente × 4 no fundo.
// A fileira 1–5 é a da frente (lado do corredor, de onde se olha o palete) e
// a 16–20 a do fundo (lado da parede), da esquerda para a direita:
//
//        parede
//   [16][17][18][19][20]
//   [11][12][13][14][15]
//   [ 6][ 7][ 8][ 9][10]
//   [ 1][ 2][ 3][ 4][ 5]
//        corredor
//
// Reaproveita a infra de estante como a ilha de paletes: local_tipo
// 'estante', número [mostruarioNum], slot sempre 0. `nivel` é a POSIÇÃO
// (0–19) e `coluna` é sempre 0 — assim a busca, que agrupa por nível, já diz
// a posição exata ("Posição 7") em vez de uma faixa. Nada muda no schema.

/// Uma das 20 posições do mostruário.
class CelulaMostruario {
  final int coluna;   // sempre 0
  final int nivel;    // posição, 0..posicoesMostruario-1
  final double yTop;  // tampo do palete: os produtos se apoiam aqui
  final double xMin, xMax;
  final double zMin, zMax;

  const CelulaMostruario({
    required this.coluna,
    required this.nivel,
    required this.yTop,
    required this.xMin,
    required this.xMax,
    required this.zMin,
    required this.zMax,
  });

  double get xCenter => (xMin + xMax) / 2;
  double get zCenter => (zMin + zMax) / 2;
}

// ─────────────────────────────────────────────────────────────────────────────
// MostruarioGeometry — medidas reais em metros
// ─────────────────────────────────────────────────────────────────────────────
//
// Palete PBR com a frente de 1,20 m em X e 1,00 m de profundidade em Z. A
// origem é o canto do fundo à esquerda; Z cresce na direção do corredor, que
// é onde fica a câmera.
class MostruarioGeometry {
  static const double largura      = 1.20;  // eixo X (frente)
  static const double profundidade = 1.00;  // eixo Z
  static const double alturaPalete = 0.144;
  static const double espTabua     = 0.022;
  static const double yTopo        = alturaPalete;

  static const double wCelula = largura / colunasMostruario;
  static const double dCelula = profundidade / fileirasMostruario;

  // Produto: uma caixa baixa por posição (ferragem miúda vem em caixa).
  static const double wCaixa = 0.18;
  static const double hCaixa = 0.14;
  static const double dCaixa = 0.18;

  static const Color corMadeira       = Color(0xFF8a6a42);
  static const Color _corMadeiraClara = Color(0xFFa5825a);
  static const Color _corMadeiraFresta = Color(0xFF4e3a22);

  /// Canto (x0, z0) da posição [posicao] (0-based): fileira 0 na frente
  /// (z maior), da esquerda para a direita.
  static ({double x0, double z0}) origemPosicao(int posicao) {
    final col = posicao % colunasMostruario;
    final fil = posicao ~/ colunasMostruario;
    return (
      x0: col * wCelula,
      z0: profundidade - (fil + 1) * dCelula,
    );
  }

  static List<CelulaMostruario> celulas() => [
        for (var p = 0; p < posicoesMostruario; p++)
          () {
            final o = origemPosicao(p);
            return CelulaMostruario(
              coluna: 0,
              nivel:  p,
              yTop:   yTopo,
              xMin:   o.x0,
              xMax:   o.x0 + wCelula,
              zMin:   o.z0,
              zMax:   o.z0 + dCelula,
            );
          }(),
      ];

  static List<Face> buildFaces() {
    final faces = <Face>[];
    const y0Tampo = yTopo - espTabua;
    // Três blocos/travessas embaixo (esquerda, meio, direita), correndo na
    // profundidade como num PBR visto de frente.
    for (final xc in const [0.05, largura / 2, largura - 0.05]) {
      _box(faces, x0: xc - 0.05, x1: xc + 0.05, y0: 0, y1: y0Tampo,
          z0: 0, z1: profundidade, color: corMadeira);
    }
    // Tampo em 5 tábuas na largura, com fresta escura entre elas.
    const nTabuas = 5;
    const fresta  = 0.012;
    const wTabua  = (largura - fresta * (nTabuas - 1)) / nTabuas;
    for (var i = 0; i < nTabuas; i++) {
      final x0 = i * (wTabua + fresta);
      _box(faces, x0: x0, x1: x0 + wTabua, y0: y0Tampo, y1: yTopo,
          z0: 0, z1: profundidade, color: _corMadeiraClara);
      if (i > 0) {
        _box(faces, x0: x0 - fresta, x1: x0, y0: y0Tampo, y1: yTopo - 0.004,
            z0: 0, z1: profundidade, color: _corMadeiraFresta);
      }
    }
    return faces;
  }

  /// Produto numa posição: uma caixa baixa no meio da célula.
  static void addProduto(
    List<Face> faces, {
    required CelulaMostruario celula,
    required Color color,
    bool desatualizado = false,
  }) {
    final x0 = celula.xCenter - wCaixa / 2;
    final x1 = x0 + wCaixa;
    final z0 = celula.zCenter - dCaixa / 2;
    final z1 = z0 + dCaixa;
    final y1 = celula.yTop + hCaixa;

    _box(faces,
        x0: x0, x1: x1, y0: celula.yTop, y1: y1, z0: z0, z1: z1,
        color: color);

    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces,
          x1: x1, y1: y1, z1: z1, tamanho: wCaixa * 0.4);
    }
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
}

/// Maquete do mostruário pro mapa da loja: o estrado de madeira baixo, com
/// as frestas das tábuas no topo. [w]/[d] são o tamanho no mapa (X/Z).
void mostruarioLoja(
    List<Face> faces, double cx, double cz, double w, double d, Color cor) {
  const h = MostruarioGeometry.alturaPalete;
  MostruarioGeometry._box(faces,
      x0: cx - w / 2, x1: cx + w / 2, y0: 0, y1: h,
      z0: cz - d / 2, z1: cz + d / 2, color: cor);
  // Tábuas correndo ao longo da parede (Z): frestas escuras um fio acima do
  // topo, pra não brigar com ele no sort por profundidade.
  final fresta = Color.lerp(cor, Colors.black, 0.45)!;
  for (var i = 1; i < 5; i++) {
    final x = cx - w / 2 + w * i / 5;
    faces.add(Face([
      Vec3(x - 0.012, h + 0.002, cz - d / 2),
      Vec3(x - 0.012, h + 0.002, cz + d / 2),
      Vec3(x + 0.012, h + 0.002, cz + d / 2),
      Vec3(x + 0.012, h + 0.002, cz - d / 2),
    ], fresta));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MostruarioPainter
// ─────────────────────────────────────────────────────────────────────────────

class MostruarioPainter extends CustomPainter {
  final Camera     camera;
  final List<Face> extraFaces;
  final bool       showLabels;
  /// Posições (nivel) com produto: não levam número por cima, senão a
  /// etiqueta esconde a caixa.
  final Set<int>   ocupadas;

  MostruarioPainter(this.camera, {
    this.extraFaces = const <Face>[],
    this.showLabels = true,
    this.ocupadas   = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0b0c0e));

    final proj  = ProjecaoCamera(camera, size);
    final faces = MostruarioGeometry.buildFaces()..addAll(extraFaces);
    proj.projetarFaces(faces);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
    if (showLabels) _drawLabels(canvas, proj);
  }

  void _draw(Canvas canvas, List<Face> faces) {
    final fill   = Paint();
    final stroke = Paint()
      ..color       = const Color(0x33000000)
      ..style       = PaintingStyle.stroke
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

  void _drawLabels(Canvas canvas, ProjecaoCamera proj) {
    const camda = Color(0xFFe87722);
    final bgPaint  = Paint()..color = const Color(0xC70b0c0e);
    final rimPaint = Paint()
      ..color       = camda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    // Número da posição deitado no tampo, só nas posições LIVRES: em cima de
    // uma caixa a etiqueta a escondia. Na ocupada a caixa é a marca, e o
    // endereço aparece no chip ao tocar. Vem da mesma função que monta o
    // endereço em letraEstanteCelula.
    final etiquetas = <(Vec3, String)>[
      for (final c in MostruarioGeometry.celulas())
        if (!ocupadas.contains(c.nivel))
          (Vec3(c.xCenter, c.yTop + 0.01, c.zCenter),
              '${posicaoMostruario(c.nivel)}'),
    ]..sort((a, b) =>
        proj.profundidade(b.$1).compareTo(proj.profundidade(a.$1)));

    for (final (pos, texto) in etiquetas) {
      final hit = proj.projetar(pos);
      if (hit == null) continue;
      final (screen, cz) = hit;
      final fontSize = 9 * (4.0 / cz).clamp(0.6, 1.6);
      final tp = TextPainter(
        text: TextSpan(
          text: texto,
          style: TextStyle(
            color:      camda,
            fontSize:   fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final radius = math.max(fontSize * 0.72, tp.width / 2 + fontSize * 0.28);
      canvas.drawCircle(screen, radius, bgPaint);
      canvas.drawCircle(screen, radius, rimPaint);
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(MostruarioPainter old) =>
      old.camera.rotY  != camera.rotY  ||
      old.camera.rotX  != camera.rotX  ||
      old.camera.dist  != camera.dist  ||
      old.showLabels   != showLabels   ||
      old.extraFaces   != extraFaces   ||
      old.ocupadas     != ocupadas;
}

// ─────────────────────────────────────────────────────────────────────────────
// MostruarioScene widget
// ─────────────────────────────────────────────────────────────────────────────

class MostruarioScene extends StatefulWidget {
  final List<CaixaColocadaEstante> caixas;
  final String? produtoSelecionadoId;
  final Map<String, Color> corPorProduto;
  final void Function(int coluna, int nivel, double hx)? onTapCelula;
  // Fora do modo de edição (produtoSelecionadoId == null), toques na célula
  // caem aqui em vez de onTapCelula — usado pra abrir detalhe/quantidade.
  final void Function(int coluna, int nivel, double hx)? onTapCelulaVisualizar;
  final String? destacadoCodigo;
  final bool showLabels;
  final Set<String> desatualizados;
  final Set<String> divergentes;
  final Set<String> divergentesPositivas;
  final Set<String> destacadosCodigos;

  const MostruarioScene({
    super.key,
    this.caixas               = const [],
    this.produtoSelecionadoId,
    this.corPorProduto        = const {},
    this.onTapCelula,
    this.onTapCelulaVisualizar,
    this.destacadoCodigo,
    this.showLabels           = true,
    this.desatualizados       = const {},
    this.divergentes          = const {},
    this.divergentesPositivas = const {},
    this.destacadosCodigos    = const {},
  });

  @override
  State<MostruarioScene> createState() => _MostruarioSceneState();
}

class _MostruarioSceneState extends State<MostruarioScene>
    with SceneGestureGuard<MostruarioScene> {
  // Pivô no centro do tampo: a geometria nasce no canto (0,0).
  static const Vec3 _pivo = Vec3(
    MostruarioGeometry.largura / 2,
    MostruarioGeometry.yTopo,
    MostruarioGeometry.profundidade / 2,
  );

  // Vista de quem está no corredor (+Z), de cima: a fileira 1–5 na frente.
  Camera _camera = const Camera(
    rotY:   0.0,
    rotX:   0.9,
    dist:   2.6,
    target: _pivo,
  );
  final _painterKey = GlobalKey();

  Camera? _cameraAtGestureStart;

  void _onScaleStart(ScaleStartDetails d) {
    beginGesture(d);
    _cameraAtGestureStart = _camera;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final origin = gestureOrigin;
    final c0     = _cameraAtGestureStart;
    if (origin == null || c0 == null) return;

    if (reanchorIfPointersChanged(d)) {
      _cameraAtGestureStart = _camera;
      return;
    }
    markDragIfMoved(d);

    final delta = d.focalPoint - origin;

    setState(() {
      // O palete encosta na parede, mas a órbita fica livre como na ilha;
      // em X a câmera não desce abaixo do tampo, senão a grade some.
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.008,
        rotX: (c0.rotX + delta.dy * 0.008).clamp(0.15, math.pi / 2 - 0.05),
        dist: (c0.dist / d.scale).clamp(1.2, 6.0),
      );
    });
  }

  void _tryFireTap(Offset globalTap) {
    final rb = _painterKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final hit = _hitTest(rb.globalToLocal(globalTap), rb.size);
    if (hit == null) return;
    if (widget.produtoSelecionadoId != null) {
      widget.onTapCelula?.call(hit.coluna, hit.nivel, hit.hx);
    } else {
      widget.onTapCelulaVisualizar?.call(hit.coluna, hit.nivel, hit.hx);
    }
  }

  /// Mesma estratégia da ilha: posições OCUPADAS entram como volume (a caixa
  /// da frente não deixa o toque atravessar) e todas entram como plano do
  /// tampo, que resolve o toque em posição vazia.
  ({int coluna, int nivel, double hx})? _hitTest(Offset tap, Size size) {
    final proj = ProjecaoCamera(_camera, size);
    final eye  = proj.eye;

    final ndcX = 2 * tap.dx / size.width  - 1;
    final ndcY = 1 - 2 * tap.dy / size.height;
    final dir = (proj.right * (ndcX * proj.tanH * proj.aspect) +
                 proj.up    * (ndcY * proj.tanH) +
                 proj.fwd).normalized;

    final ocupadas = widget.caixas.map((c) => c.nivel).toSet();

    ({int coluna, int nivel, double hx, double t})? nearest;
    void considerar(int coluna, int nivel, double hx, double t) {
      if (nearest == null || t < nearest!.t) {
        nearest = (coluna: coluna, nivel: nivel, hx: hx, t: t);
      }
    }

    for (final celula in MostruarioGeometry.celulas()) {
      if (ocupadas.contains(celula.nivel)) {
        final t = _rayAabb(
          eye, dir,
          x0: celula.xMin, x1: celula.xMax,
          y0: celula.yTop, y1: celula.yTop + MostruarioGeometry.hCaixa,
          z0: celula.zMin, z1: celula.zMax,
        );
        if (t != null) considerar(celula.coluna, celula.nivel, eye.x + t * dir.x, t);
      }

      if (dir.y.abs() < 1e-6) continue;
      final t = (celula.yTop - eye.y) / dir.y;
      if (t <= 0.05) continue;
      final hx = eye.x + t * dir.x;
      final hz = eye.z + t * dir.z;
      if (hx < celula.xMin || hx > celula.xMax) continue;
      if (hz < celula.zMin || hz > celula.zMax) continue;
      considerar(celula.coluna, celula.nivel, hx, t);
    }

    final hit = nearest;
    return hit == null
        ? null
        : (coluna: hit.coluna, nivel: hit.nivel, hx: hit.hx);
  }

  static double? _rayAabb(
    Vec3 eye, Vec3 dir, {
    required double x0, required double x1,
    required double y0, required double y1,
    required double z0, required double z1,
  }) {
    var tMin = 0.05;
    var tMax = double.infinity;

    bool slab(double origem, double d, double min, double max) {
      if (d.abs() < 1e-9) return origem >= min && origem <= max;
      var tA = (min - origem) / d;
      var tB = (max - origem) / d;
      if (tA > tB) { final tmp = tA; tA = tB; tB = tmp; }
      if (tA > tMin) tMin = tA;
      if (tB < tMax) tMax = tB;
      return tMax >= tMin;
    }

    if (!slab(eye.x, dir.x, x0, x1)) return null;
    if (!slab(eye.y, dir.y, y0, y1)) return null;
    if (!slab(eye.z, dir.z, z0, z1)) return null;
    return tMin;
  }

  @override
  Widget build(BuildContext context) {
    final extraFaces = <Face>[];
    final celulas    = MostruarioGeometry.celulas();
    for (final caixa in widget.caixas) {
      if (caixa.nivel < 0 || caixa.nivel >= celulas.length) continue;

      final isConferencia = widget.destacadosCodigos.contains(caixa.produtoId);
      final isHighlighted = caixa.produtoId == widget.destacadoCodigo;
      final chave = chaveEnderecoEstoque(
        produtoCodigo: caixa.produtoId,
        localTipo:     'estante',
        localNum:      mostruarioNum,
        faceOuColuna:  caixa.coluna,
        andarOuNivel:  caixa.nivel,
      );
      final isDivergente         = widget.divergentes.contains(chave);
      final isDivergentePositiva = widget.divergentesPositivas.contains(chave);
      final cor = isConferencia
          ? corConferenciaCiano
          : isHighlighted
              ? const Color(0xFFe87722)
              : isDivergentePositiva
                  ? corEnderecoDivergentePositiva
                  : isDivergente
                      ? corEnderecoDivergente
                      : (widget.corPorProduto[caixa.produtoId] ??
                          const Color(0xFF888888));
      MostruarioGeometry.addProduto(extraFaces,
          celula: celulas[caixa.nivel],
          color: cor,
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
          painter: MostruarioPainter(_camera,
              extraFaces: extraFaces,
              showLabels: widget.showLabels,
              ocupadas:   {for (final c in widget.caixas) c.nivel}),
          child:   const SizedBox.expand(),
        ),
      ),
    );
  }
}
