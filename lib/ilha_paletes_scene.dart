import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'gondola_scene.dart'
    show Vec3, Camera, Face, ProjecaoCamera, addBadgeEnderecoDesatualizado,
        corEnderecoDivergente, corEnderecoDivergentePositiva;
import 'models.dart';
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Ilha de paletes — 12 paletes forrados com tapume verde no meio da loja
// ─────────────────────────────────────────────────────────────────────────────
//
// Fica no corredor central, entre a Gôndola 7 (lado do caixa) e a Gôndola 6
// (lado da entrada): duas colunas de 6 paletes encostados, todos cobertos pelo
// mesmo tapume verde, formando UMA plataforma baixa. Cada palete é um ESPAÇO
// (1–12) e recebe até 5 produtos lado a lado.
//
// Numeração dos espaços igual ao croqui da loja: de 2 em 2, do caixa para a
// entrada, esquerda antes da direita (olhando da entrada para o caixa, como no
// mapa):
//
//        caixa
//      [ 1][ 2]
//      [ 3][ 4]
//      [ 5][ 6]
//      [ 7][ 8]
//      [ 9][10]
//      [11][12]
//       entrada
//
// Reaproveita a infra de estante como os expositores e os paletes soltos:
// local_tipo 'estante', número [ilhaPaletesNum], slot sempre 0. `nivel` é o
// ESPAÇO (0–11) e `coluna` é o PRODUTO dentro do espaço (0–4) — ver
// letraEstanteCelula. Nada muda no schema.

/// Uma das 60 posições de produto da ilha (12 espaços × 5 produtos).
class CelulaIlhaPaletes {
  final int coluna;   // produto no espaço, 0..produtosPorEspacoIlha-1
  final int nivel;    // espaço, 0..espacosIlhaPaletes-1
  final double yTop;  // topo do tapume: as caixas se apoiam aqui
  final double xMin, xMax;
  final double zMin, zMax;

  const CelulaIlhaPaletes({
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
// IlhaPaletesGeometry — medidas reais em metros
// ─────────────────────────────────────────────────────────────────────────────
//
// Palete PBR (1,20 × 1,00 m) com a frente de 1,20 m em X: as duas colunas
// somam 2,40 m de largura e as 6 fileiras 6,00 m de comprimento. A origem é o
// canto do espaço 1 (caixa, esquerda); Z cresce na direção da entrada.
class IlhaPaletesGeometry {
  static const double larguraPalete      = 1.20;  // eixo X
  static const double profundidadePalete = 1.00;  // eixo Z
  static const double alturaPalete       = 0.144;
  static const double espTapume          = 0.012;

  static const double largura      = larguraPalete * colunasEspacosIlha;
  static const double profundidade =
      profundidadePalete * (espacosIlhaPaletes ~/ colunasEspacosIlha);
  static const double yTopo        = alturaPalete + espTapume;

  /// Fresta entre dois paletes vizinhos: o tapume é um só, mas a emenda das
  /// placas aparece — é ela que deixa contar os 12 espaços de longe.
  static const double fresta = 0.012;

  // Produto: uma fila de caixas no sentido da profundidade, deixando uma faixa
  // livre na frente (rótulo do produto) e outra no fundo (número do espaço).
  static const double wCaixa = 0.21;
  static const double hCaixa = 0.32;
  static const double dCaixa = 0.66;
  static const int    caixasNaFila = 3;

  static const Color corTapume       = Color(0xFF2fbf5f);
  static const Color corTapumeBorda  = Color(0xFF1d8a43);
  static const Color _corMadeira     = Color(0xFF8A5C30);
  static const Color _corVinco       = Color(0xFF3a3a3a);

  /// Canto (x0, z0) do palete de um espaço (0-based).
  static ({double x0, double z0}) origemEspaco(int espaco) => (
        x0: (espaco % colunasEspacosIlha) * larguraPalete,
        z0: (espaco ~/ colunasEspacosIlha) * profundidadePalete,
      );

  static List<CelulaIlhaPaletes> celulas() {
    final lista = <CelulaIlhaPaletes>[];
    const wCol = larguraPalete / produtosPorEspacoIlha;
    for (var e = 0; e < espacosIlhaPaletes; e++) {
      final o = origemEspaco(e);
      for (var p = 0; p < produtosPorEspacoIlha; p++) {
        lista.add(CelulaIlhaPaletes(
          coluna: p,
          nivel:  e,
          yTop:   yTopo,
          xMin:   o.x0 + wCol * p,
          xMax:   o.x0 + wCol * (p + 1),
          zMin:   o.z0,
          zMax:   o.z0 + profundidadePalete,
        ));
      }
    }
    return lista;
  }

  static List<Face> buildFaces() {
    final faces = <Face>[];
    const f = fresta / 2;
    for (var e = 0; e < espacosIlhaPaletes; e++) {
      final o = origemEspaco(e);
      final x0 = o.x0 + f, x1 = o.x0 + larguraPalete - f;
      final z0 = o.z0 + f, z1 = o.z0 + profundidadePalete - f;
      // Madeira aparecendo só num fio embaixo: o tapume desce pelas laterais
      // e cobre quase tudo.
      _box(faces, x0: x0 + 0.02, x1: x1 - 0.02, y0: 0, y1: 0.02,
          z0: z0 + 0.02, z1: z1 - 0.02, color: _corMadeira);
      _box(faces, x0: x0, x1: x1, y0: 0.02, y1: yTopo,
          z0: z0, z1: z1, color: corTapume);
      // Friso mais escuro na borda do tampo, pra emenda entre placas ler.
      _box(faces, x0: x0, x1: x1, y0: yTopo, y1: yTopo + 0.002,
          z0: z1 - 0.025, z1: z1, color: corTapumeBorda);
    }
    return faces;
  }

  /// Produto numa posição: fila de [caixasNaFila] caixas no sentido da
  /// profundidade, com o vinco entre elas no topo.
  static void addProduto(
    List<Face> faces, {
    required CelulaIlhaPaletes celula,
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

    // Emenda entre uma caixa e a próxima, um fio acima do topo pra não brigar
    // com a face do topo no sort por profundidade.
    const eps = 0.0015;
    for (var i = 1; i < caixasNaFila; i++) {
      final z = z0 + dCaixa * i / caixasNaFila;
      faces.add(Face([
        Vec3(x0, y1 + eps, z - 0.004),
        Vec3(x0, y1 + eps, z + 0.004),
        Vec3(x1, y1 + eps, z + 0.004),
        Vec3(x1, y1 + eps, z - 0.004),
      ], _corVinco));
    }

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

/// Maquete da ilha pro mapa da loja: os 12 paletes como placas baixas, com a
/// fresta entre elas. [w]/[d] são a largura (X) e o comprimento (Z) da ilha
/// inteira no mapa; a grade 2 × 6 é dividida dentro deles.
void ilhaPaletesLoja(
    List<Face> faces, double cx, double cz, double w, double d, Color cor) {
  const fileiras = espacosIlhaPaletes ~/ colunasEspacosIlha;
  const h = 0.12;
  const fresta = 0.03;
  final pw = w / colunasEspacosIlha, pd = d / fileiras;
  final x0 = cx - w / 2, z0 = cz - d / 2;
  for (var e = 0; e < espacosIlhaPaletes; e++) {
    final col = e % colunasEspacosIlha, fil = e ~/ colunasEspacosIlha;
    IlhaPaletesGeometry._box(faces,
        x0: x0 + col * pw + fresta / 2, x1: x0 + (col + 1) * pw - fresta / 2,
        y0: 0, y1: h,
        z0: z0 + fil * pd + fresta / 2, z1: z0 + (fil + 1) * pd - fresta / 2,
        color: cor);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// IlhaPaletesPainter
// ─────────────────────────────────────────────────────────────────────────────

class IlhaPaletesPainter extends CustomPainter {
  final Camera     camera;
  final List<Face> extraFaces;
  final bool       showLabels;
  /// Posições com produto, como 'coluna|nivel': não levam número por cima,
  /// senão a etiqueta esconde a caixa.
  final Set<String> ocupadas;

  IlhaPaletesPainter(this.camera, {
    this.extraFaces = const <Face>[],
    this.showLabels = true,
    this.ocupadas   = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0b0c0e));

    final proj  = ProjecaoCamera(camera, size);
    final faces = IlhaPaletesGeometry.buildFaces()..addAll(extraFaces);
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

    // As etiquetas são desenhadas do fundo para a frente, como as faces: senão
    // o número de um palete do fundo cai por cima das etiquetas da frente.
    final etiquetas = <(Vec3, String, double, bool)>[];

    void badge(Vec3 pos, String texto, double base, {bool forte = false}) {
      final hit = proj.projetar(pos);
      if (hit == null) return;
      final (screen, cz) = hit;
      final fontSize = base * (9.0 / cz).clamp(0.6, 1.6);
      final tp = TextPainter(
        text: TextSpan(
          text: texto,
          style: TextStyle(
            color:      forte ? const Color(0xFF0b0c0e) : camda,
            fontSize:   fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final radius = math.max(fontSize * 0.72, tp.width / 2 + fontSize * 0.28);
      canvas.drawCircle(screen, radius,
          forte ? (Paint()..color = camda) : bgPaint);
      if (!forte) canvas.drawCircle(screen, radius, rimPaint);
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }

    // Número do espaço (1–12) deitado na faixa livre do FUNDO de cada palete
    // e o do produto (1–5) na faixa livre da frente — as duas fora da área
    // das caixas. Flutuando acima do palete, as etiquetas cobriam as caixas
    // na tela do celular, e a caixa recém-colocada parecia não ter entrado.
    // O número do produto sai quando a posição está ocupada: a caixa é a
    // marca, e o endereço aparece no chip ao tocar. Os dois vêm das mesmas
    // funções que montam o endereço em letraEstanteCelula, pra etiqueta e
    // endereço salvo não poderem divergir.
    const yRotulo = IlhaPaletesGeometry.yTopo + 0.01;
    for (var e = 0; e < espacosIlhaPaletes; e++) {
      final o = IlhaPaletesGeometry.origemEspaco(e);
      etiquetas.add((
        Vec3(o.x0 + IlhaPaletesGeometry.larguraPalete / 2, yRotulo,
            o.z0 + 0.09),
        '${espacoIlhaPaletes(e)}', 11, true));
    }
    for (final c in IlhaPaletesGeometry.celulas()) {
      if (ocupadas.contains('${c.coluna}|${c.nivel}')) continue;
      etiquetas.add((Vec3(c.xCenter, yRotulo, c.zMax - 0.08),
          '${produtoIlhaPaletes(c.coluna)}', 8, false));
    }
    etiquetas.sort((a, b) =>
        proj.profundidade(b.$1).compareTo(proj.profundidade(a.$1)));
    for (final (pos, texto, base, forte) in etiquetas) {
      badge(pos, texto, base, forte: forte);
    }
  }

  @override
  bool shouldRepaint(IlhaPaletesPainter old) =>
      old.camera.rotY  != camera.rotY  ||
      old.camera.rotX  != camera.rotX  ||
      old.camera.dist  != camera.dist  ||
      old.showLabels   != showLabels   ||
      old.extraFaces   != extraFaces   ||
      old.ocupadas     != ocupadas;
}

// ─────────────────────────────────────────────────────────────────────────────
// IlhaPaletesScene widget
// ─────────────────────────────────────────────────────────────────────────────

class IlhaPaletesScene extends StatefulWidget {
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

  const IlhaPaletesScene({
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
  State<IlhaPaletesScene> createState() => _IlhaPaletesSceneState();
}

class _IlhaPaletesSceneState extends State<IlhaPaletesScene>
    with SceneGestureGuard<IlhaPaletesScene> {
  // Pivô no centro da ilha: a geometria nasce no canto (0,0), e orbitar a
  // origem faria a ilha passear pela tela em vez de girar no lugar.
  static const Vec3 _pivo = Vec3(
    IlhaPaletesGeometry.largura / 2,
    IlhaPaletesGeometry.yTopo,
    IlhaPaletesGeometry.profundidade / 2,
  );

  // Vista de quem chega pela entrada (+Z), bem de cima: a ilha é baixa e
  // comprida, e é assim que o 11/12 fica na frente e o 1/2 no fundo, como no
  // mapa. Perto o bastante pra caixa de um produto ser vista na tela do
  // celular.
  Camera _camera = const Camera(
    rotY:   0.2,
    rotX:   1.05,
    dist:   10.0,
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
      // Ilha no chão, acessível por todos os lados: órbita livre em Y. Em X
      // a câmera não desce abaixo do tampo, senão a grade some.
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.008,
        rotX: (c0.rotX + delta.dy * 0.008).clamp(0.15, math.pi / 2 - 0.05),
        dist: (c0.dist / d.scale).clamp(2.0, 14.0),
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

  /// Mesma estratégia do palete solto: posições OCUPADAS entram como volume
  /// (a caixa da frente não deixa o toque atravessar até o tampo de trás) e
  /// todas entram como plano do tampo, que resolve o toque em posição vazia.
  ({int coluna, int nivel, double hx})? _hitTest(Offset tap, Size size) {
    final proj = ProjecaoCamera(_camera, size);
    final eye  = proj.eye;

    final ndcX = 2 * tap.dx / size.width  - 1;
    final ndcY = 1 - 2 * tap.dy / size.height;
    final dir = (proj.right * (ndcX * proj.tanH * proj.aspect) +
                 proj.up    * (ndcY * proj.tanH) +
                 proj.fwd).normalized;

    final ocupadas = widget.caixas
        .map((c) => '${c.coluna}|${c.nivel}')
        .toSet();

    ({int coluna, int nivel, double hx, double t})? nearest;
    void considerar(int coluna, int nivel, double hx, double t) {
      if (nearest == null || t < nearest!.t) {
        nearest = (coluna: coluna, nivel: nivel, hx: hx, t: t);
      }
    }

    for (final celula in IlhaPaletesGeometry.celulas()) {
      if (ocupadas.contains('${celula.coluna}|${celula.nivel}')) {
        final t = _rayAabb(
          eye, dir,
          x0: celula.xMin, x1: celula.xMax,
          y0: celula.yTop, y1: celula.yTop + IlhaPaletesGeometry.hCaixa,
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
    final celulas    = IlhaPaletesGeometry.celulas();
    for (final caixa in widget.caixas) {
      final celulaList = celulas
          .where((c) => c.coluna == caixa.coluna && c.nivel == caixa.nivel)
          .toList();
      if (celulaList.isEmpty) continue;

      final isConferencia = widget.destacadosCodigos.contains(caixa.produtoId);
      final isHighlighted = caixa.produtoId == widget.destacadoCodigo;
      final chave = chaveEnderecoEstoque(
        produtoCodigo: caixa.produtoId,
        localTipo:     'estante',
        localNum:      ilhaPaletesNum,
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
      IlhaPaletesGeometry.addProduto(extraFaces,
          celula: celulaList.first,
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
          painter: IlhaPaletesPainter(_camera,
              extraFaces: extraFaces,
              showLabels: widget.showLabels,
              ocupadas:   {
                for (final c in widget.caixas) '${c.coluna}|${c.nivel}'
              }),
          child:   const SizedBox.expand(),
        ),
      ),
    );
  }
}
