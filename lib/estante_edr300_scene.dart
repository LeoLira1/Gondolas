import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'gondola_scene.dart'
    show Vec3, Camera, Face, addBadgeEnderecoDesatualizado, corEnderecoDivergente,
        corEnderecoDivergentePositiva;
import 'models.dart'
    show CaixaColocadaEstante, chaveEnderecoEstoque, corConferenciaCiano,
        letraDoIndice;

// ─────────────────────────────────────────────────────────────────────────────
// Edr300Cell — célula de produto na estante metálica
// ─────────────────────────────────────────────────────────────────────────────

class Edr300Cell {
  final int    coluna;
  final int    nivel;
  final double yTop;
  final double xMin, xMax;

  const Edr300Cell({
    required this.coluna,
    required this.nivel,
    required this.yTop,
    required this.xMin,
    required this.xMax,
  });

  double get largura => xMax - xMin;
}

// ─────────────────────────────────────────────────────────────────────────────
// Edr300Geometry — estante de aço com montantes em L perfurados. Com
// colunas > 1 desenha vários módulos EDR-300 encostados lado a lado (a
// Estante 6 da loja é a junção física de 3 deles); cada módulo tem sua
// própria armação de 4 montantes, como as peças reais.
// ─────────────────────────────────────────────────────────────────────────────

class Edr300Geometry {
  final int    shelves;
  final double height;
  final double width;   // largura de UM módulo
  final double depth;
  final int    colunas; // módulos encostados lado a lado (1 = EDR-300 solo)
  final bool   showHoles;
  final bool   showFloor;

  const Edr300Geometry({
    this.shelves   = 6,
    this.height    = 1.98,
    this.width     = 0.92,
    this.depth     = 0.30,
    this.colunas   = 1,
    this.showHoles = false,
    this.showFloor = true,
  });

  // Dimensões das caixas de produto (em metros). Cada nível de um módulo é
  // uma única fileira que comporta 5 caixas lado a lado ocupando a largura
  // toda do módulo (a letra do label já é por módulo × nível, não por slot).
  static const double wCaixa    = 0.15;
  static const double hCaixa    = 0.20;
  static const double dCaixa    = 0.13;
  static const double gap       = 0.016;

  double get larguraTotal => width * colunas;

  /// Centro em X do módulo [col] (0 = mais à esquerda).
  double xCentroModulo(int col) => -larguraTotal / 2 + width * (col + 0.5);

  static const _steel     = Color(0xFFb8bcc2);
  static const _steelDark = Color(0xFF9a9ea6);
  static const _hole      = Color(0xFF4a5060);
  static const _floor     = Color(0xFF12161d);

  static const double _postW  = 0.035;
  static const double _shelfT = 0.018;

  double shelfY(int i) => shelves > 1
      ? (height - _shelfT) * i / (shelves - 1)
      : height / 2;

  // Grade de células para posicionar produtos: uma célula por módulo × nível
  // (coluna = módulo físico, mesma convenção salva no banco).
  List<Edr300Cell> get cells {
    final lista = <Edr300Cell>[];
    final colW  = width - 0.01;
    for (var col = 0; col < colunas; col++) {
      final xMin = -larguraTotal / 2 + width * col + 0.005;
      final xMax = xMin + colW - 0.003;
      for (var niv = 0; niv < shelves; niv++) {
        lista.add(Edr300Cell(
          coluna: col,
          nivel:  niv,
          yTop:   shelfY(niv) + _shelfT,
          xMin:   xMin,
          xMax:   xMax,
        ));
      }
    }
    return lista;
  }

  static int slotsPorCelula(Edr300Cell c) =>
      (c.largura / (wCaixa + gap)).floor().clamp(1, 99);

  static void addBoxProduto(
    List<Face> faces, {
    required Edr300Cell celula,
    required int slot,
    required Color color,
    bool desatualizado = false,
  }) {
    final xCenter = celula.xMin + wCaixa / 2 + slot * (wCaixa + gap);
    final x1 = xCenter + wCaixa / 2;
    final y1 = celula.yTop + hCaixa;
    final z1 = dCaixa / 2;
    _box(faces,
      x0: xCenter - wCaixa / 2, x1: x1,
      y0: celula.yTop,           y1: y1,
      z0: -dCaixa / 2,           z1: z1,
      color: color);
    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces, x1: x1, y1: y1, z1: z1, tamanho: wCaixa * 0.6);
    }
  }

  List<Face> buildFaces() {
    final faces = <Face>[];

    if (showFloor) {
      const s = 2.5;
      faces.add(Face([
        Vec3(-s, -0.001, -s), Vec3(-s, -0.001,  s),
        Vec3( s, -0.001,  s), Vec3( s, -0.001, -s),
      ], _floor));
    }

    for (var col = 0; col < colunas; col++) {
      _moduloFaces(faces, xCentroModulo(col));
    }

    return faces;
  }

  // Armação completa de um módulo EDR-300 centrado em [cx]: 4 montantes em L
  // + prateleiras. Módulos vizinhos ficam encostados, com os montantes de um
  // lado a lado com os do outro, como as estantes reais enfileiradas.
  void _moduloFaces(List<Face> faces, double cx) {
    final half  = width  / 2 - _postW / 2;
    final halfD = depth  / 2 - _postW / 2;

    // 4 montantes com perfil em L
    for (final pos in [
      (half,  halfD), (-half,  halfD),
      (half, -halfD), (-half, -halfD),
    ]) {
      final px = cx + pos.$1, pz = pos.$2;

      _box(faces,
        x0: px - _postW / 2, x1: px + _postW / 2,
        y0: 0,               y1: height,
        z0: pz - 0.003,      z1: pz + 0.003,
        color: _steel);

      // A aba lateral do L aponta pra dentro do módulo (sinal LOCAL de x).
      final sideX = px + (pos.$1 > 0 ? -_postW / 2 : _postW / 2);
      _box(faces,
        x0: sideX - 0.003,  x1: sideX + 0.003,
        y0: 0,               y1: height,
        z0: pz - _postW / 2, z1: pz + _postW / 2,
        color: _steel);

      if (showHoles) {
        final rows = (height / 0.04).floor();
        for (var i = 2; i < rows - 1; i++) {
          _box(faces,
            x0: px - 0.007,       x1: px + 0.007,
            y0: i * 0.04 - 0.005, y1: i * 0.04 + 0.005,
            z0: pz + 0.001,       z1: pz + 0.007,
            color: _hole);
        }
      }
    }

    // Prateleiras
    for (var i = 0; i < shelves; i++) {
      final y = shelfY(i);

      _box(faces,
        x0: cx - width / 2 + 0.005, x1: cx + width / 2 - 0.005,
        y0: y,                       y1: y + _shelfT,
        z0: -depth / 2 + 0.005,     z1: depth / 2 - 0.005,
        color: _steel);

      _box(faces,
        x0: cx - (width - 0.01) / 2, x1: cx + (width - 0.01) / 2,
        y0: y - 0.03,                 y1: y,
        z0: depth / 2 - 0.015,       z1: depth / 2 - 0.005,
        color: _steelDark);

      _box(faces,
        x0: cx - (width - 0.01) / 2,  x1: cx + (width - 0.01) / 2,
        y0: y - 0.03,                  y1: y,
        z0: -(depth / 2 - 0.005),     z1: -(depth / 2 - 0.015),
        color: _steelDark);
    }
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
  final bool           showLabels;
  final List<Face>     extraFaces;

  static final Vec3 _lightDir = Vec3(4, 10, 5).normalized;

  const Edr300Painter(this.camera, this.geometry, {
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
    final eye    = camera.position;
    final fwd    = (camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 42.0 * math.pi / 180.0;
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

    final bgPaint  = Paint()..color = bgColor;
    final rimPaint = Paint()
      ..color       = camda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Um badge por módulo × prateleira, com letras contínuas por módulo de
    // cima pra baixo (mesma régua de letraEstanteCelula): solo A–F; tripla
    // A–F, G–L, M–R.
    for (var col = 0; col < geometry.colunas; col++) {
      for (var i = 0; i < geometry.shelves; i++) {
        final hit = project(
            Vec3(geometry.xCentroModulo(col), geometry.shelfY(i) + 0.05, 0));
        if (hit == null) continue;

        final (screen, cz) = hit;
        final fontSize = 22.0 * (3.0 / cz).clamp(0.5, 1.8);
        final radius   = fontSize * 0.72;

        canvas.drawCircle(screen, radius, bgPaint);
        canvas.drawCircle(screen, radius, rimPaint);

        final letter = letraDoIndice(
            col * geometry.shelves + (geometry.shelves - 1 - i));
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
  }

  @override
  bool shouldRepaint(Edr300Painter old) =>
      old.camera.rotY        != camera.rotY        ||
      old.camera.rotX        != camera.rotX        ||
      old.camera.dist        != camera.dist        ||
      old.wireframe          != wireframe          ||
      old.showLabels         != showLabels         ||
      old.extraFaces         != extraFaces         ||
      old.geometry.shelves   != geometry.shelves   ||
      old.geometry.height    != geometry.height    ||
      old.geometry.width     != geometry.width     ||
      old.geometry.depth     != geometry.depth     ||
      old.geometry.colunas   != geometry.colunas   ||
      old.geometry.showHoles != geometry.showHoles ||
      old.geometry.showFloor != geometry.showFloor;
}

// ─────────────────────────────────────────────────────────────────────────────
// Edr300Scene widget — 3D interativo com suporte a produtos
// ─────────────────────────────────────────────────────────────────────────────

class Edr300Scene extends StatefulWidget {
  final Edr300Geometry geometry;
  // Número da estante representada — 8 (EDR-300 solo) ou 6 (a tripla).
  // Entra na chave dos endereços (desatualizados/divergentes) e no salvar.
  final int            estanteNum;
  final bool           wireframe;
  final bool           autoRotate;
  final bool           showLabels;
  final List<CaixaColocadaEstante>                      caixas;
  final String?                                         produtoSelecionadoId;
  final Map<String, Color>                              corPorProduto;
  final void Function(int coluna, int nivel, double hx)? onTapCelula;
  // Fora do modo de edição (produtoSelecionadoId == null), toques na célula
  // caem aqui em vez de onTapCelula — usado pra abrir detalhe/quantidade.
  final void Function(int coluna, int nivel, double hx)? onTapCelulaVisualizar;
  final String?                                         destacadoCodigo;
  // Chaves (chaveEnderecoEstoque) dos endereços desatualizados — carregado
  // uma vez ao abrir a cena; o painter só desenha, sem consultar o service.
  final Set<String>                                     desatualizados;
  // Chaves (chaveEnderecoEstoque) dos endereços com divergência entre a
  // quantidade contada e a do sistema — badge vermelho, espelhado do âmbar.
  final Set<String>                                     divergentes;
  // Subconjunto de [divergentes] cuja divergência é positiva (contado maior
  // que o sistema) — pintado de azul escuro em vez de vermelho.
  final Set<String>                                     divergentesPositivas;
  // Códigos destacados pelo Modo Conferência (Fase 3) — generalização de
  // destacadoCodigo para acender várias caixas de uma vez, vindas de fora
  // (não da busca). Cor própria (ciano) pra não se confundir com a busca.
  final Set<String>                                     destacadosCodigos;

  const Edr300Scene({
    super.key,
    required this.geometry,
    required this.estanteNum,
    this.wireframe           = false,
    this.autoRotate          = true,
    this.showLabels          = true,
    this.caixas              = const [],
    this.produtoSelecionadoId,
    this.corPorProduto       = const {},
    this.onTapCelula,
    this.onTapCelulaVisualizar,
    this.destacadoCodigo,
    this.desatualizados      = const {},
    this.divergentes         = const {},
    this.divergentesPositivas = const {},
    this.destacadosCodigos   = const {},
  });

  @override
  State<Edr300Scene> createState() => _Edr300SceneState();
}

class _Edr300SceneState extends State<Edr300Scene>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  late Camera _camera;

  final _painterKey = GlobalKey();
  Offset? _gestureOrigin;
  Camera? _cameraAtStart;
  bool    _isDragging = false;
  int     _gesturePointers = 0;
  static const double _dragThreshold = 6.0;

  // Zoom: mesma folga do mapa da loja — dá pra chegar bem perto de uma caixa
  // e também afastar até a estante inteira caber na tela.
  static const double _distMin = 0.8;
  static const double _distMax = 12.0;

  // Pan: o alvo da câmera não escapa de uma caixa em volta da estante, pra
  // não ser possível arrastar até perder o modelo de vista.
  static const double _panMargem = 0.7;

  // Distância inicial da câmera: mais longe quanto mais módulos lado a lado,
  // pra tripla caber inteira na tela de primeira.
  static double _distPara(Edr300Geometry geo) =>
      3.5 + (geo.colunas - 1) * 1.15;

  @override
  void initState() {
    super.initState();
    _camera = Camera(
      rotY:   0.9,
      rotX:   0.35,
      dist:   _distPara(widget.geometry),
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
    // O carrossel reaproveita este State ao alternar entre as estantes 6 e 8
    // (mesmo tipo de widget na mesma posição da árvore): reenquadra o zoom
    // quando o número de módulos muda.
    if (old.geometry.colunas != widget.geometry.colunas) {
      // Reenquadra e recentraliza: o pan do usuário na estante anterior não
      // deve deixar a próxima fora de quadro.
      _camera = Camera(
        rotY:   _camera.rotY,
        rotX:   _camera.rotX,
        dist:   _distPara(widget.geometry),
        target: Vec3(0, widget.geometry.height / 2, 0),
      );
    }
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
    _gestureOrigin   = d.focalPoint;
    _cameraAtStart   = _camera;
    _isDragging      = false;
    _gesturePointers = d.pointerCount;
  }

  // Mesmo esquema de câmera do mapa da loja (LojaScene): um dedo arrasta
  // (pan — o ponto tocado acompanha o dedo), dois dedos orbitam e dão zoom
  // com a pinça.
  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_gestureOrigin == null || _cameraAtStart == null) return;

    // Reancora o gesto quando muda o número de dedos, senão o focal point
    // salta ao encostar/levantar o segundo dedo.
    if (d.pointerCount != _gesturePointers) {
      _gestureOrigin   = d.focalPoint;
      _cameraAtStart   = _camera;
      _gesturePointers = d.pointerCount;
    }

    final origin = _gestureOrigin!;
    final c0     = _cameraAtStart!;
    final delta  = d.focalPoint - origin;

    if (delta.distance > _dragThreshold ||
        (d.scale - 1.0).abs() > 0.02 ||
        d.pointerCount > 1) {
      _isDragging = true;
    }

    if (d.pointerCount >= 2) {
      // Dois dedos: orbita (arrastar) + zoom (pinça)
      setState(() {
        _camera = Camera(
          rotY:   c0.rotY - delta.dx * 0.008,
          rotX:   (c0.rotX + delta.dy * 0.008).clamp(-0.1, math.pi / 2 - 0.05),
          dist:   (c0.dist / d.scale).clamp(_distMin, _distMax),
          target: _camera.target,
        );
      });
      return;
    }

    // Um dedo: pan no plano da tela — converte pixels em metros pela altura
    // do viewport e pelo FOV do painter (42°), então desloca o alvo ao longo
    // dos eixos "direita" e "cima" da própria câmera.
    final rb  = _painterKey.currentContext?.findRenderObject() as RenderBox?;
    final hPx = rb?.size.height ?? 600.0;
    final worldPerPx = 2 * c0.dist * math.tan(21.0 * math.pi / 180) / hPx;
    final dxW = delta.dx * worldPerPx;
    final dyW = delta.dy * worldPerPx;

    final sinY = math.sin(c0.rotY), cosY = math.cos(c0.rotY);
    final sinX = math.sin(c0.rotX), cosX = math.cos(c0.rotX);
    // right = (cosY, 0, -sinY); up = (-sinY·sinX, cosX, -cosY·sinX)
    final geo    = widget.geometry;
    final limXZ  = geo.larguraTotal / 2 + _panMargem;

    setState(() {
      _camera = Camera(
        rotY:   c0.rotY,
        rotX:   c0.rotX,
        dist:   c0.dist,
        target: Vec3(
          (c0.target.x - cosY * dxW - sinY * sinX * dyW).clamp(-limXZ, limXZ),
          (c0.target.y + cosX * dyW)
              .clamp(-_panMargem, geo.height + _panMargem),
          (c0.target.z + sinY * dxW - cosY * sinX * dyW).clamp(-limXZ, limXZ),
        ),
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (!_isDragging && _gestureOrigin != null) {
      _tryFireTap(_gestureOrigin!);
    }
    _gestureOrigin   = null;
    _cameraAtStart   = null;
    _isDragging      = false;
    _gesturePointers = 0;
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

  ({int coluna, int nivel, double hx})? _hitTest(Offset tap, Size size) {
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

    ({int coluna, int nivel, double hx, double t})? nearest;

    for (final celula in widget.geometry.cells) {
      if (dir.y.abs() < 1e-6) continue;
      final t = (celula.yTop - eye.y) / dir.y;
      if (t <= 0.1) continue;

      final hx = eye.x + t * dir.x;
      final hz = eye.z + t * dir.z;

      if (hx < celula.xMin || hx > celula.xMax) continue;
      if (hz.abs() > widget.geometry.depth / 2 + 0.05) continue;

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
      final isConferencia = widget.destacadosCodigos.contains(caixa.produtoId);
      final isHighlighted = caixa.produtoId == widget.destacadoCodigo;
      final celulaList = widget.geometry.cells
          .where((c) => c.coluna == caixa.coluna && c.nivel == caixa.nivel)
          .toList();
      if (celulaList.isEmpty) continue;
      final chave = chaveEnderecoEstoque(
        produtoCodigo: caixa.produtoId,
        localTipo:     'estante',
        localNum:      widget.estanteNum,
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
      Edr300Geometry.addBoxProduto(extraFaces,
          celula: celulaList.first, slot: caixa.slot, color: cor,
          desatualizado: widget.desatualizados.contains(chave));
    }

    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        key:     _painterKey,
        painter: Edr300Painter(_camera, widget.geometry,
            wireframe:  widget.wireframe,
            showLabels: widget.showLabels,
            extraFaces: extraFaces),
        child:   const SizedBox.expand(),
      ),
    );
  }
}
