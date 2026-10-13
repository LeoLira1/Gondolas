import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'gondola_scene.dart'
    show Vec3, Camera, Face, addBadgeEnderecoDesatualizado, corEnderecoDivergente,
        corEnderecoDivergentePositiva;
import 'models.dart';
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CelulaPalete — uma das 15 posições de produto do palete
// ─────────────────────────────────────────────────────────────────────────────
//
// ATENÇÃO à convenção, que é diferente da das estantes: no palete a grade é
// HORIZONTAL, então `nivel` não é altura — é a FILEIRA em profundidade
// (0 = fileira do corredor/frente, 2 = fileira do fundo). Ele se chama
// `nivel` porque é o que vai na coluna andar_ou_nivel de estoque_localizado e
// no `nivel` de estante_layout, reaproveitando a infra de estante sem
// alteração de schema. `coluna` é a posição ao longo da frente (0 = esquerda).
class CelulaPalete {
  final int coluna;   // 0..colunasPalete-1, ao longo da frente (eixo X)
  final int nivel;    // 0..fileirasPalete-1, em profundidade (eixo Z)
  final double yTop;  // topo do deck: as caixas se apoiam aqui
  final double xMin, xMax;
  final double zMin, zMax;

  const CelulaPalete({
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
// PaleteGeometry — palete de madeira PBR padrão, medidas reais em metros
// ─────────────────────────────────────────────────────────────────────────────
//
// UMA geometria serve todos os paletes: eles são todos iguais (mesmo tamanho,
// mesma grade de 15 posições), então N paletes cadastrados são N linhas na
// tabela `paletes`, não N geometrias. É por isso que esta classe não recebe o
// número do palete — só o painter recebe, e só para rotular as células.
//
// Empilhamento vertical, de baixo pra cima, somando os 14,4 cm reais:
//   0,000 – 0,022  3 tábuas de base correndo no comprimento (X)
//   0,022 – 0,122  9 blocos de 10 × 10 × 10 cm
//   0,100 – 0,122  3 travessas correndo na profundidade (Z), sobre os blocos
//   0,122 – 0,144  deck de 5 tábuas (larga/estreita/larga/estreita/larga)
// As travessas ocupam a fatia de cima do curso dos blocos em vez de um curso
// próprio: é o que amarra os 3 blocos de cada coluna e ainda fecha a altura
// total em 14,4 cm (0,022 + 0,100 + 0,022), como o palete real.
class PaleteGeometry {
  static const double largura      = 1.20;  // frente, eixo X
  static const double profundidade = 1.00;  // fundo, eixo Z
  static const double alturaTotal  = 0.144;

  static const double espTabua = 0.022;     // tábuas de base e do deck
  static const double ladoBloco = 0.10;     // blocos 10 × 10 × 10 cm

  static const double yBaseTopo   = espTabua;               // 0,022
  static const double yBlocoTopo  = espTabua + ladoBloco;   // 0,122
  static const double yDeckTopo   = alturaTotal;            // 0,144
  static const double yTravessa0  = yBlocoTopo - espTabua;  // 0,100

  // Deck: 5 tábuas larga/estreita/larga/estreita/larga, com 4 vãos iguais.
  // 3×0,16 + 2×0,11 = 0,70 m de madeira; os 0,30 m restantes viram 4 vãos de
  // 7,5 cm, fechando exatamente a profundidade de 1,00 m.
  static const List<double> largurasDeck = [0.16, 0.11, 0.16, 0.11, 0.16];
  static double get vaoDeck =>
      (profundidade - largurasDeck.fold(0.0, (s, w) => s + w)) /
      (largurasDeck.length - 1);

  // Blocos e travessas: X = início / centro / fim, Z = início / centro / fim.
  static const List<double> xBlocos = [
    0.0,
    (largura - ladoBloco) / 2,       // 0,55
    largura - ladoBloco,             // 1,10
  ];
  static const List<double> zBlocos = [
    0.0,
    (profundidade - ladoBloco) / 2,  // 0,45
    profundidade - ladoBloco,        // 0,90
  ];

  // Caixa de papelão padrão do palete: 22 × 30 × 27 cm. Todas as 15 posições
  // são caixa de papelão — o palete nunca recebe balde.
  static const double wCaixa = 0.22;  // eixo X
  static const double hCaixa = 0.30;  // altura
  static const double dCaixa = 0.27;  // eixo Z

  static const _corTabuaTopo = Color(0xFFC08A4E);
  static const _corTabuaLado = Color(0xFF8A5C30);
  static const _corBloco     = Color(0xFF6E4622);
  static const _corTravessa  = Color(0xFF7A5029);
  static const _corVinco     = Color(0xFF6E4A28);
  static const _corFita      = Color(0xFFE3D5B4);

  /// As 15 posições, em ordem de coluna e fileira. A célula é a fatia da
  /// grade (24 cm × 33,3 cm), não a caixa: é ela que recebe o toque, então
  /// cobre todo o vão entre as posições vizinhas.
  static List<CelulaPalete> celulas() {
    final lista = <CelulaPalete>[];
    final wCol = largura / colunasPalete;         // 0,24
    final dFil = profundidade / fileirasPalete;   // 0,3333
    for (var col = 0; col < colunasPalete; col++) {
      for (var fil = 0; fil < fileirasPalete; fil++) {
        lista.add(CelulaPalete(
          coluna: col,
          nivel:  fil,
          yTop:   yDeckTopo,
          xMin:   wCol * col,
          xMax:   wCol * (col + 1),
          zMin:   dFil * fil,
          zMax:   dFil * (fil + 1),
        ));
      }
    }
    return lista;
  }

  static List<Face> buildFaces() {
    final faces = <Face>[];

    // 3 tábuas de base correndo no comprimento (X), alinhadas sob cada
    // fileira de blocos.
    for (final z0 in zBlocos) {
      _tabua(faces,
          x0: 0,   x1: largura,
          y0: 0,   y1: yBaseTopo,
          z0: z0,  z1: z0 + ladoBloco);
    }

    // 9 blocos de 10 × 10 × 10 cm.
    for (final x0 in xBlocos) {
      for (final z0 in zBlocos) {
        _box(faces,
            x0: x0,         x1: x0 + ladoBloco,
            y0: yBaseTopo,  y1: yBlocoTopo,
            z0: z0,         z1: z0 + ladoBloco,
            color: _corBloco);
      }
    }

    // 3 travessas correndo na profundidade (Z), ligando os 3 blocos de cada
    // coluna de X.
    for (final x0 in xBlocos) {
      _box(faces,
          x0: x0,          x1: x0 + ladoBloco,
          y0: yTravessa0,  y1: yBlocoTopo,
          z0: 0,           z1: profundidade,
          color: _corTravessa);
    }

    // Deck: 5 tábuas correndo no comprimento, com vãos iguais entre elas.
    var z = 0.0;
    for (final w in largurasDeck) {
      _tabua(faces,
          x0: 0,            x1: largura,
          y0: yBlocoTopo,   y1: yDeckTopo,
          z0: z,            z1: z + w);
      z += w + vaoDeck;
    }

    return faces;
  }

  /// Caixa de papelão de uma posição: corpo na cor do produto, vinco das abas
  /// no topo e fita crepe clara sobre o vinco.
  static void addBoxProduto(
    List<Face> faces, {
    required CelulaPalete celula,
    required Color color,
    bool desatualizado = false,
  }) {
    final x0 = celula.xCenter - wCaixa / 2;
    final x1 = x0 + wCaixa;
    final z0 = celula.zCenter - dCaixa / 2;
    final z1 = z0 + dCaixa;
    final y1 = celula.yTop + hCaixa;

    _box(faces,
        x0: x0, x1: x1,
        y0: celula.yTop, y1: y1,
        z0: z0, z1: z1,
        color: color);

    // Vinco das abas: as duas abas se encontram no meio da caixa, ao longo do
    // eixo X. Desenhado um fio acima do topo pra não brigar com a face do topo
    // no sort por profundidade.
    const eps  = 0.0015;
    final zMid = celula.zCenter;
    faces.add(Face([
      Vec3(x0, y1 + eps, zMid - 0.004),
      Vec3(x0, y1 + eps, zMid + 0.004),
      Vec3(x1, y1 + eps, zMid + 0.004),
      Vec3(x1, y1 + eps, zMid - 0.004),
    ], _corVinco));

    // Fita crepe clara sobre o vinco, mais larga que ele e um fio acima.
    faces.add(Face([
      Vec3(x0, y1 + eps * 2, zMid - 0.024),
      Vec3(x0, y1 + eps * 2, zMid + 0.024),
      Vec3(x1, y1 + eps * 2, zMid + 0.024),
      Vec3(x1, y1 + eps * 2, zMid - 0.024),
    ], _corFita));

    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces,
          x1: x1, y1: y1, z1: z1, tamanho: wCaixa * 0.4);
    }
  }

  /// Tábua de madeira: corpo escuro + lâmina de topo mais clara, como as
  /// prateleiras da Estante Parede — o palete é visto de cima, então é o topo
  /// que dá a leitura da madeira.
  static void _tabua(
    List<Face> faces, {
    required double x0, required double x1,
    required double y0, required double y1,
    required double z0, required double z1,
  }) {
    _box(faces,
        x0: x0, x1: x1, y0: y0, y1: y1, z0: z0, z1: z1,
        color: _corTabuaLado);
    _box(faces,
        x0: x0, x1: x1, y0: y1, y1: y1 + 0.004, z0: z0, z1: z1,
        color: _corTabuaTopo);
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
// PaletePainter
// ─────────────────────────────────────────────────────────────────────────────

class PaletePainter extends CustomPainter {
  final Camera     camera;
  final List<Face> extraFaces;
  final bool       showLabels;
  final int        estanteAtual; // >= paleteNumMin — define os rótulos 1–15

  static final Vec3 _lightDir = Vec3(-3, 10, 6).normalized;

  PaletePainter(this.camera, {
    this.extraFaces   = const <Face>[],
    this.showLabels   = true,
    this.estanteAtual = paleteNumMin,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF120e0a));

    final faces = PaleteGeometry.buildFaces()..addAll(extraFaces);
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
    final bgPaint  = Paint()..color = const Color(0xC70b0c0e);
    final rimPaint = Paint()
      ..color       = camda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    // Rótulo 1–15 de cada posição. O texto vem SEMPRE de letraEstanteCelula
    // (nunca calculado aqui), pra etiqueta desenhada e endereço salvo não
    // poderem divergir.
    for (final celula in PaleteGeometry.celulas()) {
      final hit = project(Vec3(celula.xCenter, celula.yTop + 0.06, celula.zCenter));
      if (hit == null) continue;

      final (screen, cz) = hit;
      // Base menor que nas estantes: o palete é raso e as 15 posições ficam
      // todas visíveis de uma vez, então etiqueta grande cobre o deck e as
      // caixas. O clamp de escala também é mais curto pelo mesmo motivo.
      final fontSize = 11.0 * (2.2 / cz).clamp(0.6, 1.5);

      final texto = letraEstanteCelula(estanteAtual, celula.coluna, celula.nivel);
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
  bool shouldRepaint(PaletePainter old) =>
      old.camera.rotY  != camera.rotY  ||
      old.camera.rotX  != camera.rotX  ||
      old.camera.dist  != camera.dist  ||
      old.showLabels   != showLabels   ||
      old.estanteAtual != estanteAtual ||
      old.extraFaces   != extraFaces;
}

// ─────────────────────────────────────────────────────────────────────────────
// PaleteScene widget — renderiza UM palete (o ativo do carrossel)
// ─────────────────────────────────────────────────────────────────────────────

class PaleteScene extends StatefulWidget {
  final int estanteAtual; // >= paleteNumMin
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
  // Códigos destacados pelo Modo Conferência (Fase 3) — cor própria (ciano)
  // pra não se confundir com o laranja da busca.
  final Set<String> destacadosCodigos;

  const PaleteScene({
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
  State<PaleteScene> createState() => _PaleteSceneState();
}

class _PaleteSceneState extends State<PaleteScene>
    with SceneGestureGuard<PaleteScene> {
  // Pivô no CENTRO do palete (0,60 / 0,50), não no canto (0,0): a geometria é
  // escrita com as medidas reais a partir da origem, então orbitar (0,0,0)
  // faria o palete descrever um arco pela tela em vez de girar no lugar — era
  // o bug do protótipo HTML. As outras cenas não têm esse problema porque
  // centram a geometria na origem.
  static const Vec3 _pivo = Vec3(
    PaleteGeometry.largura / 2,       // 0,60
    PaleteGeometry.alturaTotal,
    PaleteGeometry.profundidade / 2,  // 0,50
  );

  Camera _camera = const Camera(
    rotY:   0.55,
    rotX:   0.62,   // bem de cima: o palete é baixo e a grade é horizontal
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
      // O palete fica no chão e é acessível por todos os lados: a órbita em Y
      // é livre (sem clamp, ao contrário da parede). Em X o limite inferior
      // não deixa a câmera descer abaixo do deck, senão a grade desaparece.
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.008,
        rotX: (c0.rotX + delta.dy * 0.008).clamp(0.12, math.pi / 2 - 0.05),
        dist: (c0.dist / d.scale).clamp(1.1, 6.0),
      );
    });
  }

  void _tryFireTap(Offset globalTap) {
    final rb = _painterKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final hit = _hitTest(rb.globalToLocal(globalTap), rb.size);
    if (hit == null) return;
    // Slot é sempre 0 no palete (uma caixa por posição), então o hx que sai
    // daqui é só o ponto tocado — quem consome converte pra slot 0.
    if (widget.produtoSelecionadoId != null) {
      widget.onTapCelula?.call(hit.coluna, hit.nivel, hit.hx);
    } else {
      widget.onTapCelulaVisualizar?.call(hit.coluna, hit.nivel, hit.hx);
    }
  }

  /// Acha a posição tocada. Duas famílias de candidatos, e ganha o de menor t
  /// (o mais perto da câmera):
  ///
  ///  * posições OCUPADAS entram como volume (ray-AABB da caixa de 30 cm), pra
  ///    um toque na caixa da fileira do fundo não atravessar até o deck e cair
  ///    na fileira da frente;
  ///  * todas as 15 entram como plano do deck, que é o que resolve o toque em
  ///    posição vazia.
  ///
  /// Só as ocupadas viram volume de propósito: se posição vazia também fosse
  /// volume, ela ocluiria a caixa visível atrás dela e roubaria o toque.
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

    final ocupadas = widget.caixas
        .map((c) => '${c.coluna}|${c.nivel}')
        .toSet();

    ({int coluna, int nivel, double hx, double t})? nearest;
    void considerar(int coluna, int nivel, double hx, double t) {
      if (nearest == null || t < nearest!.t) {
        nearest = (coluna: coluna, nivel: nivel, hx: hx, t: t);
      }
    }

    for (final celula in PaleteGeometry.celulas()) {
      // Volume da caixa (só se ocupada).
      if (ocupadas.contains('${celula.coluna}|${celula.nivel}')) {
        final t = _rayAabb(
          eye, dir,
          x0: celula.xMin, x1: celula.xMax,
          y0: celula.yTop, y1: celula.yTop + PaleteGeometry.hCaixa,
          z0: celula.zMin, z1: celula.zMax,
        );
        if (t != null) considerar(celula.coluna, celula.nivel, eye.x + t * dir.x, t);
      }

      // Plano do deck.
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

  /// Distância até a entrada do raio na caixa alinhada aos eixos, ou null se
  /// não acerta (método dos slabs).
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
    final celulas    = PaleteGeometry.celulas();
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
        localNum:      widget.estanteAtual,
        faceOuColuna:  caixa.coluna,
        andarOuNivel:  caixa.nivel,
      );
      // Mesma precedência das outras cenas: destaques momentâneos
      // (conferência, busca) na frente da marcação de divergência.
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
      PaleteGeometry.addBoxProduto(extraFaces,
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
          painter: PaletePainter(_camera,
              extraFaces:   extraFaces,
              showLabels:   widget.showLabels,
              estanteAtual: widget.estanteAtual),
          child:   const SizedBox.expand(),
        ),
      ),
    );
  }
}
