import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'gondola_scene.dart';
import 'models.dart';
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CelulaEstante
// ─────────────────────────────────────────────────────────────────────────────

class CelulaEstante {
  final int coluna;
  final int nivel;
  final double yTop;
  final double xMin, xMax;

  const CelulaEstante({
    required this.coluna,
    required this.nivel,
    required this.yTop,
    required this.xMin,
    required this.xMax,
  });

  double get largura => xMax - xMin;
}

// ─────────────────────────────────────────────────────────────────────────────
// EstanteGeometry — 3 colunas × 4 níveis (12 células) no padrão; Estantes 3 e
// 4 têm 3 colunas × 5 níveis de produto (15 células) mais um nível de topo
// reservado aos pulverizadores, fora do sistema de labels.
// ─────────────────────────────────────────────────────────────────────────────

class EstanteGeometry {
  static const _corMadeira      = Color(0xFF8a5a2e);
  static const _corMadeiraEscura = Color(0xFF5e3d1f);

  static const double larguraTotal = 6.0;
  static const double alturaTotal  = 4.2;
  static const double profundidade = 1.0;
  static const double espessura    = 0.08;
  static const int    numColunas   = numColunasEstante;

  static const double wCaixa = 0.42, hCaixa = 0.50, dCaixa = 0.42, gap = 0.04;

  static double get larguraColuna {
    final espacoUtil = larguraTotal - espessura * (numColunas + 1);
    return espacoUtil / numColunas;
  }

  // Nº de níveis de produto (label) + o nível de topo reservado aos
  // pulverizadores nas Estantes 3 e 4 (fora do sistema de labels).
  static int numNiveisTotal(int estanteNum) =>
      niveisProdutoPara(estanteNum) + (temNivelTopoPara(estanteNum) ? 1 : 0);

  static double alturaNivel(int estanteNum) =>
      alturaTotal / numNiveisTotal(estanteNum);

  // A grade de células é função pura do número da estante (numColunas é
  // constante de compilação e niveisProdutoPara só compara faixas de número),
  // então dá para memoizar. Sem isso, `build` chamava celulasPara UMA VEZ POR
  // CAIXA — cada chamada realocando a grade inteira antes do firstWhere — e
  // _drawLabels e _hitTest realocavam de novo a cada invocação.
  static final Map<int, List<CelulaEstante>> _memoCelulas = {};

  static List<CelulaEstante> celulasPara(int estanteNum) =>
      _memoCelulas.putIfAbsent(estanteNum, () {
        final lista        = <CelulaEstante>[];
        final nivProduto   = niveisProdutoPara(estanteNum);
        final alturaNiv    = alturaNivel(estanteNum);
        for (var col = 0; col < numColunas; col++) {
          final xMin =
              -larguraTotal / 2 + espessura * (col + 1) + larguraColuna * col;
          final xMax = xMin + larguraColuna;
          for (var niv = 0; niv < nivProduto; niv++) {
            lista.add(CelulaEstante(
              coluna: col,
              nivel:  niv,
              yTop:   espessura + alturaNiv * niv + espessura,
              xMin:   xMin,
              xMax:   xMax,
            ));
          }
        }
        // Congelada: a lista agora é compartilhada entre todos os chamadores.
        return List<CelulaEstante>.unmodifiable(lista);
      });

  static int slotsPorCelula(CelulaEstante c) =>
      (c.largura / (wCaixa + gap)).floor();

  static List<Face> buildFaces(int estanteNum) {
    final faces      = <Face>[];
    final halfL      = larguraTotal / 2;
    final halfD      = profundidade / 2;
    final nivTotal   = numNiveisTotal(estanteNum);
    final alturaNiv  = alturaNivel(estanteNum);

    // prateleiras horizontais (base + uma por nível, incluindo o nível de
    // topo dos pulverizadores quando houver)
    for (var niv = 0; niv <= nivTotal; niv++) {
      final y = espessura + alturaNiv * niv;
      _box(faces,
          x0: -halfL, x1: halfL,
          y0: y,      y1: y + espessura,
          z0: -halfD, z1: halfD,
          color: _corMadeira);
    }

    // lateral esquerda
    _box(faces,
        x0: -halfL,            x1: -halfL + espessura,
        y0: 0,                 y1: alturaTotal,
        z0: -halfD,            z1: halfD,
        color: _corMadeiraEscura);

    // lateral direita
    _box(faces,
        x0: halfL - espessura, x1: halfL,
        y0: 0,                 y1: alturaTotal,
        z0: -halfD,            z1: halfD,
        color: _corMadeiraEscura);

    // divisórias internas
    for (var col = 1; col < numColunas; col++) {
      final xDiv = -halfL + espessura * col + larguraColuna * col;
      _box(faces,
          x0: xDiv,            x1: xDiv + espessura,
          y0: 0,               y1: alturaTotal,
          z0: -halfD,          z1: halfD,
          color: _corMadeiraEscura);
    }

    return faces;
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

  static void addBoxProduto(
    List<Face> faces, {
    required CelulaEstante celula,
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
        y0: celula.yTop,          y1: y1,
        z0: -dCaixa / 2,          z1: z1,
        color: color);
    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces, x1: x1, y1: y1, z1: z1, tamanho: wCaixa * 0.4);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EstantePainter
// ─────────────────────────────────────────────────────────────────────────────

class EstantePainter extends CustomPainter {
  final Camera     camera;
  final List<Face> extraFaces;
  final bool       showLabels;
  final int        estanteAtual;

  static final Vec3 _lightDir = Vec3(5, 10, 7).normalized;

  EstantePainter(this.camera, {
    this.extraFaces  = const <Face>[],
    this.showLabels  = true,
    this.estanteAtual = 1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF14110d));

    final faces = EstanteGeometry.buildFaces(estanteAtual)..addAll(extraFaces);
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

    const camda      = Color(0xFFe87722);
    const bgColor    = Color(0xC70b0c0e);
    final nNiveis    = niveisProdutoPara(estanteAtual);
    const nColunas   = EstanteGeometry.numColunas;
    final letraOffset = letraOffsetPara(estanteAtual);

    final bgPaint  = Paint()..color = bgColor;
    final rimPaint = Paint()
      ..color       = camda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    for (final celula in EstanteGeometry.celulasPara(estanteAtual)) {
      final xCenter = (celula.xMin + celula.xMax) / 2;
      final hit = project(Vec3(xCenter, celula.yTop + 0.06, 0));
      if (hit == null) continue;

      final (screen, cz) = hit;
      final fontSize = 19.0 * (6.0 / cz).clamp(0.5, 1.5);

      final row    = nNiveis - 1 - celula.nivel;
      final letter = letraDoIndice(letraOffset + row * nColunas + celula.coluna);
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

      // O raio do selo acompanha a largura do texto para não cortar labels
      // de duas letras (AA, AB, AC, AD...).
      final radius = math.max(fontSize * 0.72, tp.width / 2 + fontSize * 0.28);

      canvas.drawCircle(screen, radius, bgPaint);
      canvas.drawCircle(screen, radius, rimPaint);
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(EstantePainter old) =>
      old.camera.rotY   != camera.rotY   ||
      old.camera.rotX   != camera.rotX   ||
      old.camera.dist   != camera.dist   ||
      old.showLabels    != showLabels    ||
      old.estanteAtual  != estanteAtual  ||
      old.extraFaces    != extraFaces;
}

// ─────────────────────────────────────────────────────────────────────────────
// EstanteScene widget
// ─────────────────────────────────────────────────────────────────────────────

class EstanteScene extends StatefulWidget {
  final int estanteAtual;
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

  const EstanteScene({
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
  State<EstanteScene> createState() => _EstanteSceneState();
}

class _EstanteSceneState extends State<EstanteScene>
    with SceneGestureGuard<EstanteScene> {
  static Camera _cameraInicial() => const Camera(
        rotY:   0.5,
        rotX:   0.25,
        dist:   _distInicial,
        target: Vec3(0, EstanteGeometry.alturaTotal / 2, 0),
      );

  Camera _camera = _cameraInicial();
  final _painterKey = GlobalKey();

  Camera? _cameraAtGestureStart;

  // Zoom com a mesma folga da Estante 8 (Edr300Scene): o mínimo de 0.8 é o que
  // deixa colar numa caixa só — antes o piso era 4.0 e as caixas de uma célula
  // ficavam indistinguíveis. O teto continua em 18 (e não nos 12 da EDR-300)
  // porque a estante de madeira tem 6 m de largura: a 12 ela já não cabe
  // inteira numa tela de celular em pé.
  static const double _distMin     = 0.8;
  static const double _distMax     = 18.0;
  static const double _distInicial = 9.0;

  // Pan: o alvo não escapa de uma caixa em volta da estante, pra não ser
  // possível arrastar até perder o modelo de vista.
  static const double _panMargem = 0.7;

  @override
  void didUpdateWidget(EstanteScene old) {
    super.didUpdateWidget(old);
    // O carrossel reaproveita este State ao trocar de estante (1→2→5→…):
    // todas têm a mesma armação, mas o pan feito na anterior deixaria a
    // seguinte fora de quadro. Recentraliza o alvo preservando ângulo e zoom.
    if (old.estanteAtual != widget.estanteAtual) {
      _camera = Camera(
        rotY:   _camera.rotY,
        rotX:   _camera.rotX,
        dist:   _camera.dist,
        target: Vec3(0, EstanteGeometry.alturaTotal / 2, 0),
      );
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    beginGesture(d);
    _cameraAtGestureStart = _camera;
  }

  // Mesmo esquema de câmera da Estante 8 (Edr300Scene), da Estante Parede e do
  // mapa da loja: um dedo arrasta (pan — o ponto tocado acompanha o dedo),
  // dois dedos orbitam e dão zoom com a pinça.
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
      // Dois dedos: orbita (arrastar) + zoom (pinça).
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
    final limXZ = EstanteGeometry.larguraTotal / 2 + _panMargem;
    final limY  = EstanteGeometry.alturaTotal + _panMargem;

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

    for (final celula in EstanteGeometry.celulasPara(widget.estanteAtual)) {
      if (dir.y.abs() < 1e-6) continue;
      final t = (celula.yTop - eye.y) / dir.y;
      if (t <= 0.1) continue;

      final hx = eye.x + t * dir.x;
      final hz = eye.z + t * dir.z;

      if (hx < celula.xMin || hx > celula.xMax) continue;
      if (hz.abs() > EstanteGeometry.profundidade / 2 + 0.05) continue;

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
    // Índice (coluna, nível) → célula montado UMA vez: era um firstWhere linear
    // sobre a grade inteira por caixa desenhada.
    final celulas = <(int, int), CelulaEstante>{
      for (final c in EstanteGeometry.celulasPara(widget.estanteAtual))
        (c.coluna, c.nivel): c,
    };
    for (final caixa in widget.caixas) {
      final isConferencia = widget.destacadosCodigos.contains(caixa.produtoId);
      final isHighlighted = caixa.produtoId == widget.destacadoCodigo;
      // Caixa em endereço que não existe mais nesta estante (layout antigo):
      // antes o firstWhere estourava; agora simplesmente não desenha.
      final celula = celulas[(caixa.coluna, caixa.nivel)];
      if (celula == null) continue;
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
      EstanteGeometry.addBoxProduto(extraFaces,
          celula: celula, slot: caixa.slot, color: cor,
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
          painter: EstantePainter(_camera,
              extraFaces:   extraFaces,
              showLabels:   widget.showLabels,
              estanteAtual: widget.estanteAtual),
          child:   const SizedBox.expand(),
        ),
      ),
    );
  }
}
