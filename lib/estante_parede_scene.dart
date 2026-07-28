import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'gondola_scene.dart'
    show Vec3, Camera, Face, addBadgeEnderecoDesatualizado, corEnderecoDivergente,
        corEnderecoDivergentePositiva;
import 'models.dart';
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CelulaParede — célula de produto de uma seção da Estante Parede
// ─────────────────────────────────────────────────────────────────────────────

class CelulaParede {
  final int coluna;
  final int nivel;
  final double yTop;
  final double xMin, xMax;

  const CelulaParede({
    required this.coluna,
    required this.nivel,
    required this.yTop,
    required this.xMin,
    required this.xMax,
  });

  double get largura => xMax - xMin;
}

// ─────────────────────────────────────────────────────────────────────────────
// EstanteParedeGeometry — uma seção (2 posições) da prateleira de parede:
// prateleiras verdes "flutuantes" sem montantes na frente, ferros verticais
// traseiros nas bordas da seção e mãos francesas diagonais por nível.
// Unidades e alturas vêm do protótipo aprovado (estante-parede-3d.html).
// ─────────────────────────────────────────────────────────────────────────────

class EstanteParedeGeometry {
  // Topo de cada plano: índice 0 = base, 1..5 = níveis 1..5 (6 planos, como
  // a peça real da loja).
  static const List<double> ys = [0, 0.46, 0.94, 1.42, 1.90, 2.38];

  static const double espessura     = 0.08;
  static const double profundidade  = 0.58;
  static const double larguraColuna = 1.3;
  static const int    numColunas    = colunasParede;
  static const double larguraTotal  = larguraColuna * numColunas;
  // Altura da peça (topo da última prateleira) — usada para enquadrar a câmera
  // e limitar o pan, como o `height` da Edr300Geometry. Getter, e não const,
  // porque `ys.last` não é expressão constante — assim não duplica o 2.38.
  static double get alturaTotal => ys.last + espessura;

  // Cada número da parede comporta 6 caixas na prateleira real (era 4 no app).
  // As 2 novas entram à DIREITA — slots 4 e 5 —, então os slots 0–3 já salvos
  // em estante_layout mantêm o índice e o endereço não muda para ninguém
  // (mesma lição dos ganchos intercalados do MagnoJet, ver models.dart).
  static const int    maxSlots      = 6;
  static const double gap           = 0.03;
  static const double margemLateral = 0.02;

  // Largura da caixa DERIVADA de maxSlots, e não literal como o antigo 0.27
  // (dimensionado para 4): com 6 caixas o valor fixo estouraria a coluna
  // (6 × 0.27 + 5 × gap > larguraColuna) e as últimas vazariam para fora.
  static double get wCaixa =>
      (larguraColuna - 2 * margemLateral - (maxSlots - 1) * gap) / maxSlots;

  // Frente aberta (produtos, toques) voltada para a câmera em +Z; ferros e
  // mãos francesas no fundo (lado da parede), em -Z — como na loja real.
  static const double zFrente = profundidade / 2;
  static const double zParede = -profundidade / 2;

  static const _corPrateleiraTopo = Color(0xFF406C54);
  static const _corPrateleiraLado = Color(0xFF284838);
  static const _corFerro          = Color(0xFF18221D);
  static const _corMaoFrancesa    = Color(0xFF1C2822);

  // Margem interna que centraliza os 6 slots dentro da coluna. Com o wCaixa
  // derivado acima o resultado é exatamente margemLateral, mas a fórmula fica
  // como está para continuar valendo se wCaixa voltar a ser um valor fixo.
  static double get margemSlots =>
      (larguraColuna - (maxSlots * wCaixa + (maxSlots - 1) * gap)) / 2;

  static List<CelulaParede> celulas() {
    final lista = <CelulaParede>[];
    for (var col = 0; col < numColunas; col++) {
      final xMin = -larguraTotal / 2 + larguraColuna * col;
      for (var niv = 0; niv < niveisProdutoParede; niv++) {
        lista.add(CelulaParede(
          coluna: col,
          nivel:  niv,
          yTop:   ys[niv] + espessura,
          xMin:   xMin,
          xMax:   xMin + larguraColuna,
        ));
      }
    }
    return lista;
  }

  /// x0 da caixa no slot 0 da célula — usado também pelo _geometriaCelula do
  /// app para converter o toque (hx) em slot com a mesma régua do desenho.
  static double xSlot0(CelulaParede c) => c.xMin + margemSlots;

  // Altura útil da caixa: 74% do vão até a prateleira de cima (o último
  // nível usa um vão nominal, já que não tem prateleira acima).
  static double alturaCaixa(int nivel) {
    final vao = nivel < niveisProdutoParede - 1
        ? ys[nivel + 1] - ys[nivel] - espessura
        : 0.42;
    return vao * 0.74;
  }

  static List<Face> buildFaces() {
    final faces = <Face>[];
    const halfL = larguraTotal / 2;

    // 6 prateleiras full-width: corpo verde escuro + lâmina de topo mais clara.
    for (final y in ys) {
      _box(faces,
          x0: -halfL,   x1: halfL,
          y0: y,        y1: y + espessura,
          z0: zParede,  z1: zFrente,
          color: _corPrateleiraLado);
      _box(faces,
          x0: -halfL,           x1: halfL,
          y0: y + espessura,    y1: y + espessura + 0.004,
          z0: zParede,          z1: zFrente,
          color: _corPrateleiraTopo);
    }

    // Ferros verticais traseiros nas bordas da seção, subindo um pouco acima
    // do topo, + mão francesa diagonal por ferro × nível (1..6).
    for (final px in [-halfL, halfL]) {
      _box(faces,
          x0: px - 0.05,  x1: px + 0.05,
          y0: 0,          y1: ys.last + espessura + 0.12,
          z0: zParede - 0.03, z1: zParede + 0.05,
          color: _corFerro);

      for (var k = 1; k < ys.length; k++) {
        final drop = math.min(0.34, (ys[k] - ys[k - 1]) * 0.75);
        final pts = [
          Vec3(px - 0.028, ys[k] - drop,  zParede + 0.05),
          Vec3(px + 0.028, ys[k] - drop,  zParede + 0.05),
          Vec3(px + 0.028, ys[k] - 0.005, zFrente - 0.10),
          Vec3(px - 0.028, ys[k] - 0.005, zFrente - 0.10),
        ];
        faces.add(Face(pts, _corMaoFrancesa));
        faces.add(Face(pts.reversed.toList(), _corMaoFrancesa));
      }
    }

    return faces;
  }

  static void addBoxProduto(
    List<Face> faces, {
    required CelulaParede celula,
    required int slot,
    required Color color,
    bool desatualizado = false,
  }) {
    final x0 = xSlot0(celula) + slot * (wCaixa + gap);
    final x1 = x0 + wCaixa;
    final y1 = celula.yTop + alturaCaixa(celula.nivel);
    const z1 = zFrente - 0.08;
    _box(faces,
        x0: x0,               x1: x1,
        y0: celula.yTop,      y1: y1,
        z0: zParede + 0.10,   z1: z1,
        color: color);
    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces, x1: x1, y1: y1, z1: z1, tamanho: wCaixa * 0.4);
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

// ─────────────────────────────────────────────────────────────────────────────
// EstanteParedePainter
// ─────────────────────────────────────────────────────────────────────────────

class EstanteParedePainter extends CustomPainter {
  final Camera     camera;
  final List<Face> extraFaces;
  final bool       showLabels;
  final int        estanteAtual; // 13..18 — define letras e posições globais

  static final Vec3 _lightDir = Vec3(-3, 10, 6).normalized;

  EstanteParedePainter(this.camera, {
    this.extraFaces   = const <Face>[],
    this.showLabels   = true,
    this.estanteAtual = estanteParedeMin,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0e1310));

    final faces = EstanteParedeGeometry.buildFaces()..addAll(extraFaces);
    _project(faces, size);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
    if (showLabels) _drawLabels(canvas, size);
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

  void _drawLabels(Canvas canvas, Size size) {
    final eye   = camera.position;
    final fwd   = (camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    const fovY = 45.0 * math.pi / 180.0;
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

    // Endereço numérico contínuo por célula (1..72, coluna a coluna).
    for (final celula in EstanteParedeGeometry.celulas()) {
      final xCenter = (celula.xMin + celula.xMax) / 2;
      final hit = project(Vec3(xCenter, celula.yTop + 0.06, 0));
      if (hit == null) continue;

      final (screen, cz) = hit;
      final fontSize = 22.0 * (5.0 / cz).clamp(0.5, 1.8);

      final letter = letraEstanteCelula(estanteAtual, celula.coluna, celula.nivel);
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

      final radius = math.max(fontSize * 0.72, tp.width / 2 + fontSize * 0.28);

      canvas.drawCircle(screen, radius, bgPaint);
      canvas.drawCircle(screen, radius, rimPaint);
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }

    // Posição global P1–P12 na frente da base de cada coluna.
    for (var col = 0; col < EstanteParedeGeometry.numColunas; col++) {
      final xCenter = -EstanteParedeGeometry.larguraTotal / 2 +
          (col + 0.5) * EstanteParedeGeometry.larguraColuna;
      final y = (EstanteParedeGeometry.espessura + EstanteParedeGeometry.ys[1]) / 2;
      final hit = project(Vec3(xCenter, y, EstanteParedeGeometry.zFrente + 0.02));
      if (hit == null) continue;

      final (screen, cz) = hit;
      final fontSize = 12.0 * (5.0 / cz).clamp(0.5, 1.6);
      final texto    = 'P${posicaoGlobalParede(estanteAtual, col)}';

      final tp = TextPainter(
        text: TextSpan(
          text: texto,
          style: TextStyle(
            color:      const Color(0xFFf0a35e),
            fontSize:   fontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final rect = Rect.fromCenter(
        center: screen,
        width:  tp.width + fontSize * 0.9,
        height: tp.height + fontSize * 0.4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(fontSize * 0.35)),
        Paint()..color = const Color(0xB30b0d10),
      );
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(EstanteParedePainter old) =>
      old.camera.rotY  != camera.rotY  ||
      old.camera.rotX  != camera.rotX  ||
      old.camera.dist  != camera.dist  ||
      old.showLabels   != showLabels   ||
      old.estanteAtual != estanteAtual ||
      old.extraFaces   != extraFaces;
}

// ─────────────────────────────────────────────────────────────────────────────
// EstanteParedeScene widget — renderiza UMA seção (a estante ativa 13–18)
// ─────────────────────────────────────────────────────────────────────────────

class EstanteParedeScene extends StatefulWidget {
  final int estanteAtual; // 13..18
  final List<CaixaColocadaEstante> caixas;
  final String? produtoSelecionadoId;
  final Map<String, Color> corPorProduto;
  final void Function(int coluna, int nivel, double hx)? onTapCelula;
  // Fora do modo de edição (produtoSelecionadoId == null), toques na célula
  // caem aqui em vez de onTapCelula — usado pra abrir detalhe/quantidade.
  final void Function(int coluna, int nivel, double hx)? onTapCelulaVisualizar;
  final String? destacadoCodigo;
  final bool showLabels;
  // Chaves (chaveEnderecoEstoque) dos endereços desatualizados — carregado
  // uma vez ao abrir a cena; o painter só desenha, sem consultar o service.
  final Set<String> desatualizados;
  // Chaves (chaveEnderecoEstoque) dos endereços com divergência entre a
  // quantidade contada e a do sistema — badge vermelho, espelhado do âmbar.
  final Set<String> divergentes;
  // Subconjunto de [divergentes] cuja divergência é positiva (contado maior
  // que o sistema) — pintado de azul escuro em vez de vermelho.
  final Set<String> divergentesPositivas;
  // Códigos destacados pelo Modo Conferência (Fase 3) — generalização de
  // destacadoCodigo para acender várias caixas de uma vez, vindas de fora
  // (não da busca). Cor própria (ciano) pra não se confundir com a busca.
  final Set<String> destacadosCodigos;

  const EstanteParedeScene({
    super.key,
    required this.estanteAtual,
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
  State<EstanteParedeScene> createState() => _EstanteParedeSceneState();
}

class _EstanteParedeSceneState extends State<EstanteParedeScene>
    with SceneGestureGuard<EstanteParedeScene> {
  static Camera _cameraInicial() => Camera(
        rotY:   0.35,
        rotX:   0.12,
        dist:   _distInicial,
        target: Vec3(0, EstanteParedeGeometry.alturaTotal / 2, 0),
      );

  Camera _camera = _cameraInicial();
  final _painterKey = GlobalKey();

  Camera? _cameraAtGestureStart;

  // A peça é fixa na parede: a órbita não passa para trás dela.
  static const double _rotYLim = 1.35;

  // Zoom com a mesma folga da Estante 6 (Edr300Scene): dá pra colar numa caixa
  // e também afastar até a seção inteira caber na tela. Antes o mínimo era 3.2,
  // o que impedia chegar perto o bastante pra distinguir as caixas de um número.
  static const double _distMin     = 0.8;
  static const double _distMax     = 12.0;
  static const double _distInicial = 6.4;

  // Pan: o alvo não escapa de uma caixa em volta da seção, pra não ser possível
  // arrastar até perder a peça de vista.
  static const double _panMargem = 0.7;

  @override
  void didUpdateWidget(EstanteParedeScene old) {
    super.didUpdateWidget(old);
    // O carrossel reaproveita este State ao trocar de seção (13→14→…): todas
    // têm a mesma geometria, mas o pan feito na seção anterior deixaria a
    // seguinte fora de quadro. Recentraliza o alvo preservando ângulo e zoom.
    if (old.estanteAtual != widget.estanteAtual) {
      _camera = Camera(
        rotY:   _camera.rotY,
        rotX:   _camera.rotX,
        dist:   _camera.dist,
        target: Vec3(0, EstanteParedeGeometry.alturaTotal / 2, 0),
      );
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    beginGesture(d);
    _cameraAtGestureStart = _camera;
  }

  // Mesmo esquema de câmera da Estante 6 (Edr300Scene) e do mapa da loja: um
  // dedo arrasta (pan — o ponto tocado acompanha o dedo), dois dedos orbitam e
  // dão zoom com a pinça.
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

    if (d.pointerCount >= 2) {
      // Dois dedos: orbita (arrastar) + zoom (pinça). O limite de rotY continua
      // valendo — a peça é fixa na parede, não se olha por trás dela.
      setState(() {
        _camera = Camera(
          rotY:   (c0.rotY - delta.dx * 0.008).clamp(-_rotYLim, _rotYLim),
          rotX:   (c0.rotX + delta.dy * 0.008).clamp(-0.1, math.pi / 2 - 0.05),
          dist:   (c0.dist / d.scale).clamp(_distMin, _distMax),
          target: _camera.target,
        );
      });
      return;
    }

    // Um dedo: pan no plano da tela — converte pixels em metros pela altura do
    // viewport e pelo FOV do painter (45°, então meia-abertura de 22,5°), e
    // desloca o alvo ao longo dos eixos "direita" e "cima" da própria câmera.
    final rb  = _painterKey.currentContext?.findRenderObject() as RenderBox?;
    final hPx = rb?.size.height ?? 600.0;
    final worldPerPx = 2 * c0.dist * math.tan(22.5 * math.pi / 180) / hPx;
    final dxW = delta.dx * worldPerPx;
    final dyW = delta.dy * worldPerPx;

    final sinY = math.sin(c0.rotY), cosY = math.cos(c0.rotY);
    final sinX = math.sin(c0.rotX), cosX = math.cos(c0.rotX);
    // right = (cosY, 0, -sinY); up = (-sinY·sinX, cosX, -cosY·sinX)
    final limXZ  = EstanteParedeGeometry.larguraTotal / 2 + _panMargem;
    final limY   = EstanteParedeGeometry.alturaTotal + _panMargem;

    setState(() {
      _camera = Camera(
        rotY:   c0.rotY,
        rotX:   c0.rotX,
        dist:   c0.dist,
        target: Vec3(
          (c0.target.x - cosY * dxW - sinY * sinX * dyW).clamp(-limXZ, limXZ),
          (c0.target.y + cosX * dyW).clamp(-_panMargem, limY),
          (c0.target.z + sinY * dxW - cosY * sinX * dyW).clamp(-limXZ, limXZ),
        ),
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final tap = gestureOrigin;
    if (endGesture(d)) _tryFireTap(tap!);
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

  // Ray-plane intersection. Returns nearest hit whose (hx, hz) lands inside the cell bounding box.
  ({int coluna, int nivel, double hx})? _hitTest(Offset tap, Size size) {
    final eye   = _camera.position;
    final fwd   = (_camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    const fovY = 45.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;

    final ndcX = 2 * tap.dx / size.width  - 1;
    final ndcY = 1 - 2 * tap.dy / size.height;

    final dir = (right * (ndcX * tanH * aspect) +
                 up    * (ndcY * tanH) +
                 fwd).normalized;

    ({int coluna, int nivel, double hx, double t})? nearest;

    for (final celula in EstanteParedeGeometry.celulas()) {
      if (dir.y.abs() < 1e-6) continue;
      final t = (celula.yTop - eye.y) / dir.y;
      if (t <= 0.1) continue;

      final hx = eye.x + t * dir.x;
      final hz = eye.z + t * dir.z;

      if (hx < celula.xMin || hx > celula.xMax) continue;
      if (hz.abs() > EstanteParedeGeometry.profundidade / 2 + 0.05) continue;

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
      final celulaList = EstanteParedeGeometry.celulas()
          .where((c) => c.coluna == caixa.coluna && c.nivel == caixa.nivel)
          .toList();
      if (celulaList.isEmpty) continue;
      final chave = chaveEnderecoEstoque(
        produtoCodigo: caixa.produtoId,
        localTipo:     'estante',
        localNum:      widget.estanteAtual,
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
      EstanteParedeGeometry.addBoxProduto(extraFaces,
          celula: celulaList.first, slot: caixa.slot, color: cor,
          desatualizado: widget.desatualizados.contains(chave));
    }

    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        key:     _painterKey,
        painter: EstanteParedePainter(_camera,
            extraFaces:   extraFaces,
            showLabels:   widget.showLabels,
            estanteAtual: widget.estanteAtual),
        child:   const SizedBox.expand(),
      ),
    );
  }
}
