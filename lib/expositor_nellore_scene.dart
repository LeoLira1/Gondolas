import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'gondola_scene.dart' show Vec3, Camera, Face, addBadgeEnderecoDesatualizado;
import 'models.dart'
    show CaixaColocadaEstante, chaveEnderecoEstoque, colunasNivelNellore,
         corConferenciaCiano, expositorNelloreNum, letraEstanteCelula;

// ─────────────────────────────────────────────────────────────────────────────
// Expositor Nellore Isoflex/Avant — estrutura amarela com painel slatwall
// creme e testeira amarela (branding Nellore Isoflex à esquerda, AVANT /
// multiloc.com.br à direita). De cima pra baixo: 2 fileiras de 5 ganchos em J,
// 1 linha de 4 cestos bin pretos com frente amarela, 2 prateleiras creme com
// borda amarela (5 espaços cada) e a base amarela com deck creme que também
// recebe produtos.
//
// São 24 endereços nos níveis 1–5 com colunas variando por nível, slot = 0
// sempre, reaproveitando o esquema (coluna, nivel, slot) do estante_layout
// na Turso como "estante" nº expositorNelloreNum:
//   níveis 1–2 = prateleiras, 5 espaços — letras T–X e O–S
//   nível 3    = cestos bin, 4 cestos   — letras K–N
//   níveis 4–5 = ganchos, 5 por fileira — letras F–J e A–E (topo)
//
// O nível 0 era a base (deck, rotulada 1–4), mas a estante real não tem essa
// prateleira: a base continua desenhada (o pé da estrutura existe), só não
// gera mais células — sem labels, sem toque e sem produtos ali.
// ─────────────────────────────────────────────────────────────────────────────

enum NelloreTipoNivel { base, prateleira, cesto, gancho }

class ExpositorNelloreCell {
  final int              coluna;
  final int              nivel;      // 0 = base, 5 = fileira de ganchos do topo
  final NelloreTipoNivel tipo;
  final double           xCenter;    // centro da coluna em X
  final double           ySurface;   // gancho: altura do pino; demais: piso de apoio

  const ExpositorNelloreCell({
    required this.coluna,
    required this.nivel,
    required this.tipo,
    required this.xCenter,
    required this.ySurface,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorNelloreGeometry — base + prateleiras + cestos + painel + ganchos
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorNelloreGeometry {
  final double width;      // largura total (m)
  final double height;     // altura do painel slatwall (sem testeira)
  final bool   showFloor;

  const ExpositorNelloreGeometry({
    this.width     = 1.10,
    this.height    = 2.05,
    this.showFloor = true,
  });

  static const int niveis = 6;

  // Altura total incluindo a testeira (usada pra centrar a câmera).
  double get alturaTotal => height + _testeiraH + 0.02;

  // ── Dimensões dos produtos ─────────────────────────────────────────────────
  static const double wPacote = 0.115;  // pacote pendurado no gancho
  static const double hPacote = 0.195;
  static const double dPacote = 0.035;
  static const double _hAba   = 0.045;  // aba amarela no topo do pacote
  static const double wCaixa  = 0.17;   // caixa apoiada em prateleira/base
  static const double hCaixa  = 0.17;
  static const double dCaixa  = 0.17;

  // ── Estrutura ──────────────────────────────────────────────────────────────
  static const double _painelT     = 0.035;  // espessura do painel slatwall
  static const double _ranhuraH    = 0.010;  // altura da ranhura (canaleta)
  static const double _ranhuraGap  = 0.075;  // passo entre ranhuras
  static const double _molduraW    = 0.045;  // montante lateral amarelo
  static const double _ganchoLen   = 0.16;   // comprimento do gancho em J
  static const double _ganchoR     = 0.005;  // meia-espessura do pino
  static const double _baseH       = 0.10;   // rodapé amarelo da base
  static const double _deckT       = 0.03;   // deck creme sobre o rodapé
  static const double _baseD       = 0.48;   // profundidade da base
  static const double _shelfD      = 0.32;   // profundidade das prateleiras
  static const double _shelfT      = 0.025;  // espessura da prateleira
  static const double _bordaH      = 0.045;  // borda amarela frontal
  static const double _binD        = 0.26;   // profundidade dos cestos bin
  static const double _binH        = 0.155;  // altura dos cestos bin
  static const double _testeiraH   = 0.32;   // altura da testeira
  static const double _testeiraD   = 0.12;   // avanço da testeira sobre o painel

  // ── Paleta (da foto do expositor real) ─────────────────────────────────────
  static const _amarelo     = Color(0xFFf2b41d);  // amarelo Nellore/Avant
  static const _amareloEsc  = Color(0xFFcd9410);  // sombra/montantes
  static const _painel      = Color(0xFFe6e0cf);  // slatwall creme
  static const _ranhura     = Color(0xFFb4ac93);  // sombra da canaleta
  static const _creme       = Color(0xFFede8d8);  // deck e prateleiras
  static const _binPreto    = Color(0xFF1c1d1f);  // corpo dos cestos
  static const _floor       = Color(0xFF12161d);

  // Aba amarela fixa no topo de todo pacote pendurado, independe do produto.
  static const corAbaNellore    = _amarelo;
  static const corVermelhoAvant = Color(0xFF9c1f1f);

  static NelloreTipoNivel tipoDoNivel(int nivel) => nivel == 0
      ? NelloreTipoNivel.base
      : nivel <= 2
          ? NelloreTipoNivel.prateleira
          : nivel == 3
              ? NelloreTipoNivel.cesto
              : NelloreTipoNivel.gancho;

  // Y do nível: superfície de apoio (base/prateleira/cesto) ou centro do pino
  // (gancho). Frações da altura calibradas pelas fotos da loja: 2 fileiras de
  // ganchos em cima, cestos no meio, prateleiras e deck embaixo.
  double nivelY(int nivel) => switch (nivel) {
        0 => _baseH + _deckT,
        1 => height * 0.29,
        2 => height * 0.47,
        3 => height * 0.60,
        4 => height * 0.78,
        _ => height * 0.93,
      };

  // X do centro da coluna c no nível dado — o nº de colunas varia por nível
  // (ganchos/prateleiras: 5, cestos/base: 4), todos na mesma largura útil.
  double colunaX(int c, int nivel) {
    final nCols = colunasNivelNellore(nivel);
    final util  = width - _molduraW * 2 - 0.21;
    final xMin  = -util / 2;
    return nCols > 1 ? xMin + util * c / (nCols - 1) : 0;
  }

  // Nível 0 (base) fora: a estante real não tem essa prateleira de produtos.
  List<ExpositorNelloreCell> get cells => [
        for (var niv = 1; niv < niveis; niv++)
          for (var col = 0; col < colunasNivelNellore(niv); col++)
            ExpositorNelloreCell(
              coluna:   col,
              nivel:    niv,
              tipo:     tipoDoNivel(niv),
              xCenter:  colunaX(col, niv),
              ySurface: nivelY(niv),
            ),
      ];

  static double get zFrente => _painelT / 2;

  // Plano frontal de cada tipo de nível — usado no hit-test e nos labels
  // (a base avança mais que a prateleira, que avança mais que o gancho).
  double zFrenteNivel(int nivel) => switch (tipoDoNivel(nivel)) {
        NelloreTipoNivel.base       => _baseD * 0.70,
        NelloreTipoNivel.prateleira => _shelfD * 0.75,
        NelloreTipoNivel.cesto      => zFrente + _binD,
        NelloreTipoNivel.gancho     => zFrente + _ganchoLen / 2,
      };

  // ── Pacote pendurado num gancho (como no MagnoJet) ─────────────────────────
  static void addPacoteProduto(
    List<Face> faces, {
    required ExpositorNelloreCell celula,
    required Color color,
    bool desatualizado = false,
  }) {
    final xc = celula.xCenter;
    final yTopo = celula.ySurface + 0.008;
    final z0 = zFrente + _ganchoLen - dPacote - 0.01;
    final z1 = z0 + dPacote;

    // Aba (cabeçalho amarelo)
    _box(faces,
      x0: xc - wPacote / 2, x1: xc + wPacote / 2,
      y0: yTopo - _hAba,     y1: yTopo,
      z0: z0,                z1: z1,
      color: corAbaNellore);

    // Corpo (cor do produto)
    _box(faces,
      x0: xc - wPacote / 2, x1: xc + wPacote / 2,
      y0: yTopo - hPacote,   y1: yTopo - _hAba,
      z0: z0,                z1: z1,
      color: color);

    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces,
          x1: xc + wPacote / 2, y1: yTopo, z1: z1, tamanho: wPacote * 0.55);
    }
  }

  // ── Caixa apoiada (prateleiras, base e cestos, como nas estantes) ──────────
  static void addCaixaProduto(
    List<Face> faces, {
    required ExpositorNelloreCell celula,
    required Color color,
    bool desatualizado = false,
  }) {
    final xc = celula.xCenter;
    final double w, h, z0, z1;
    if (celula.tipo == NelloreTipoNivel.cesto) {
      // Caixa menor, dentro do cesto, aparecendo acima da frente amarela.
      w  = 0.16;
      h  = 0.13;
      z0 = zFrente + 0.02;
      z1 = zFrente + _binD - 0.05;
    } else {
      w  = wCaixa;
      h  = hCaixa;
      z0 = zFrente + 0.015;
      z1 = zFrente + 0.015 + dCaixa;
    }
    final y0 = celula.ySurface + (celula.tipo == NelloreTipoNivel.cesto ? 0.02 : 0.0);
    _box(faces,
      x0: xc - w / 2, x1: xc + w / 2,
      y0: y0,          y1: y0 + h,
      z0: z0,          z1: z1,
      color: color);
    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces,
          x1: xc + w / 2, y1: y0 + h, z1: z1, tamanho: w * 0.45);
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

    final hw = width / 2;

    // ── Base: rodapé amarelo + deck creme (nível 0) ────────────────────────
    _box(faces,
      x0: -hw,          x1: hw,
      y0: 0,            y1: _baseH,
      z0: -_painelT/2,  z1: _baseD,
      color: _amarelo);
    _box(faces,
      x0: -hw + 0.01,   x1: hw - 0.01,
      y0: _baseH,       y1: _baseH + _deckT,
      z0: -_painelT/2,  z1: _baseD - 0.01,
      color: _creme);

    // ── Painel slatwall creme ──────────────────────────────────────────────
    _box(faces,
      x0: -hw + _molduraW, x1: hw - _molduraW,
      y0: _baseH,           y1: height,
      z0: -_painelT / 2,    z1: _painelT / 2,
      color: _painel);

    // Montantes laterais amarelos
    for (final sinal in [-1.0, 1.0]) {
      _box(faces,
        x0: sinal * hw - (sinal > 0 ? _molduraW : 0),
        x1: sinal * hw + (sinal > 0 ? 0 : _molduraW),
        y0: _baseH,          y1: height,
        z0: -_painelT / 2 - 0.004, z1: _painelT / 2 + 0.02,
        color: _amareloEsc);
    }

    // Ranhuras horizontais do slatwall — tiras finas levemente à frente do
    // painel pra vencer o depth-sort.
    var y = _baseH + _deckT + _ranhuraGap;
    while (y < height - 0.04) {
      faces.add(Face([
        Vec3(-hw + _molduraW, y,             _painelT / 2 + 0.002),
        Vec3( hw - _molduraW, y,             _painelT / 2 + 0.002),
        Vec3( hw - _molduraW, y + _ranhuraH, _painelT / 2 + 0.002),
        Vec3(-hw + _molduraW, y + _ranhuraH, _painelT / 2 + 0.002),
      ], _ranhura));
      y += _ranhuraGap;
    }

    // ── Testeira amarela (branding desenhado no painter) ───────────────────
    _box(faces,
      x0: -hw,           x1: hw,
      y0: height,        y1: height + _testeiraH,
      z0: -_painelT / 2, z1: _painelT / 2 + _testeiraD,
      color: _amarelo);
    // Filete escuro no topo da testeira
    _box(faces,
      x0: -hw,                x1: hw,
      y0: height + _testeiraH - 0.015, y1: height + _testeiraH,
      z0: -_painelT / 2 - 0.002,       z1: _painelT / 2 + _testeiraD + 0.002,
      color: _amareloEsc);

    // ── Prateleiras creme com borda amarela (níveis 1 e 2) ─────────────────
    for (final niv in [1, 2]) {
      final ys = nivelY(niv);
      _box(faces,
        x0: -hw + _molduraW, x1: hw - _molduraW,
        y0: ys - _shelfT,     y1: ys,
        z0: -_painelT / 2,    z1: _shelfD,
        color: _creme);
      // Borda amarela frontal
      _box(faces,
        x0: -hw + _molduraW, x1: hw - _molduraW,
        y0: ys - _bordaH,     y1: ys + 0.005,
        z0: _shelfD,          z1: _shelfD + 0.012,
        color: _amarelo);
    }

    // ── Cestos bin pretos com frente amarela (nível 3) ─────────────────────
    final yBin = nivelY(3);
    // Suporte amarelo dos cestos
    _box(faces,
      x0: -hw + _molduraW, x1: hw - _molduraW,
      y0: yBin - 0.02,      y1: yBin,
      z0: -_painelT / 2,    z1: _painelT / 2 + _binD + 0.02,
      color: _amarelo);
    for (var col = 0; col < colunasNivelNellore(3); col++) {
      final cx = colunaX(col, 3);
      // Corpo preto (levemente mais baixo: o topo escuro sugere a abertura)
      _box(faces,
        x0: cx - 0.115, x1: cx + 0.115,
        y0: yBin,        y1: yBin + _binH - 0.025,
        z0: _painelT / 2 - 0.01, z1: _painelT / 2 + _binD - 0.02,
        color: _binPreto);
      // Frente amarela
      _box(faces,
        x0: cx - 0.12,  x1: cx + 0.12,
        y0: yBin,        y1: yBin + _binH,
        z0: _painelT / 2 + _binD - 0.02, z1: _painelT / 2 + _binD,
        color: _amarelo);
    }

    // ── Ganchos em J amarelos (níveis 4–6) ─────────────────────────────────
    for (final c in cells) {
      if (c.tipo != NelloreTipoNivel.gancho) continue;
      // Haste horizontal saindo do painel
      _box(faces,
        x0: c.xCenter - _ganchoR, x1: c.xCenter + _ganchoR,
        y0: c.ySurface - _ganchoR, y1: c.ySurface + _ganchoR,
        z0: _painelT / 2,           z1: _painelT / 2 + _ganchoLen,
        color: _amarelo);
      // Pontinha levantada na extremidade (o "J")
      _box(faces,
        x0: c.xCenter - _ganchoR, x1: c.xCenter + _ganchoR,
        y0: c.ySurface,            y1: c.ySurface + 0.020,
        z0: _painelT / 2 + _ganchoLen - _ganchoR * 2,
        z1: _painelT / 2 + _ganchoLen,
        color: _amarelo);
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
// ExpositorNellorePainter
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorNellorePainter extends CustomPainter {
  final Camera                    camera;
  final ExpositorNelloreGeometry  geometry;
  final bool                      wireframe;
  final bool                      showLabels;
  final List<Face>                extraFaces;

  static final Vec3 _lightDir = Vec3(4, 10, 5).normalized;

  const ExpositorNellorePainter(this.camera, this.geometry, {
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
    _drawMarca(canvas, size);
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

  // Branding da testeira — texto 2D projetado em cima do 3D, mesma técnica dos
  // labels: placa "Nellore ISOFLEX" à esquerda, "AVANT / multiloc.com.br" à
  // direita. Só desenha quando a testeira está de frente pra câmera.
  void _drawMarca(Canvas canvas, Size size) {
    if (camera.position.z <= 0.3) return;

    final g  = geometry;
    final yC = g.height + ExpositorNelloreGeometry._testeiraH * 0.52;
    final zC = ExpositorNelloreGeometry._painelT / 2 +
        ExpositorNelloreGeometry._testeiraD + 0.01;

    // Placa branca "Nellore ISOFLEX" à esquerda
    final hitEsq = _projectPoint(Vec3(-g.width * 0.26, yC, zC), size);
    if (hitEsq != null) {
      final (screen, cz) = hitEsq;
      final fontSize = 20.0 * (2.6 / cz).clamp(0.4, 1.6);
      final tp = TextPainter(
        textAlign: TextAlign.center,
        text: TextSpan(children: [
          TextSpan(
            text: 'Nellore\n',
            style: TextStyle(
              color:      const Color(0xFF2a2415),
              fontSize:   fontSize,
              height:     1.0,
              fontWeight: FontWeight.w900,
              fontStyle:  FontStyle.italic,
            ),
          ),
          TextSpan(
            text: 'ISOFLEX',
            style: TextStyle(
              color:         ExpositorNelloreGeometry.corVermelhoAvant,
              fontSize:      fontSize * 0.42,
              fontWeight:    FontWeight.w800,
              letterSpacing: fontSize * 0.10,
            ),
          ),
        ]),
        textDirection: TextDirection.ltr,
      )..layout();
      final rect = Rect.fromCenter(
        center: screen,
        width:  tp.width + fontSize * 0.9,
        height: tp.height + fontSize * 0.5,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(fontSize * 0.35)),
        Paint()..color = const Color(0xFFf8f6ef));
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }

    // "AVANT / multiloc.com.br" à direita, direto sobre o amarelo
    final hitDir = _projectPoint(Vec3(g.width * 0.26, yC, zC), size);
    if (hitDir != null) {
      final (screen, cz) = hitDir;
      final fontSize = 17.0 * (2.6 / cz).clamp(0.4, 1.6);
      final tp = TextPainter(
        textAlign: TextAlign.center,
        text: TextSpan(children: [
          TextSpan(
            text: 'AVANT\n',
            style: TextStyle(
              color:         ExpositorNelloreGeometry.corVermelhoAvant,
              fontSize:      fontSize,
              height:        1.05,
              fontWeight:    FontWeight.w900,
              letterSpacing: fontSize * 0.06,
            ),
          ),
          TextSpan(
            text: 'multiloc.com.br',
            style: TextStyle(
              color:      const Color(0xFFfdfbf4),
              fontSize:   fontSize * 0.48,
              fontWeight: FontWeight.w700,
            ),
          ),
        ]),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
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
      // Posição do disco por tipo: acima do gancho, na boca do cesto, no
      // meio da frente das prateleiras/deck.
      final double yLabel = switch (c.tipo) {
        NelloreTipoNivel.gancho => c.ySurface + 0.045,
        NelloreTipoNivel.cesto  => c.ySurface + 0.085,
        _                       => c.ySurface + 0.055,
      };
      final hit = _projectPoint(
          Vec3(c.xCenter, yLabel, geometry.zFrenteNivel(c.nivel) + 0.02),
          size);
      if (hit == null) continue;

      final (screen, cz) = hit;
      final fontSize = 14.0 * (3.2 / cz).clamp(0.5, 1.6);
      final radius   = fontSize * 0.72;

      canvas.drawCircle(screen, radius, bgPaint);
      canvas.drawCircle(screen, radius, rimPaint);

      // Nível 0 mostra números 1–4; níveis 1–6 letras contínuas de cima pra
      // baixo (A–D no topo até U–X) — mesma regra de letraEstanteCelula.
      final rotulo = letraEstanteCelula(expositorNelloreNum, c.coluna, c.nivel);
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
  bool shouldRepaint(ExpositorNellorePainter old) =>
      old.camera.rotY        != camera.rotY        ||
      old.camera.rotX        != camera.rotX        ||
      old.camera.dist        != camera.dist        ||
      old.wireframe          != wireframe          ||
      old.showLabels         != showLabels         ||
      old.extraFaces         != extraFaces         ||
      old.geometry.width     != geometry.width     ||
      old.geometry.height    != geometry.height    ||
      old.geometry.showFloor != geometry.showFloor;
}

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorNelloreScene — 3D interativo com suporte a produtos
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorNelloreScene extends StatefulWidget {
  final ExpositorNelloreGeometry geometry;
  final bool                     wireframe;
  final bool                     autoRotate;
  final bool                     showLabels;
  // Reutiliza CaixaColocadaEstante: coluna = coluna, nivel = nível (0 = base,
  // 5 = ganchos do topo), slot = 0 sempre (um produto por endereço).
  final List<CaixaColocadaEstante> caixas;
  final String?                    produtoSelecionadoId;
  final Map<String, Color>         corPorProduto;
  final void Function(int coluna, int nivel)? onTapCelula;
  final void Function(int coluna, int nivel)? onTapCelulaVisualizar;
  final String?                    destacadoCodigo;
  final Set<String>                desatualizados;
  final Set<String>                destacadosCodigos;

  const ExpositorNelloreScene({
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
    this.destacadosCodigos    = const {},
  });

  @override
  State<ExpositorNelloreScene> createState() =>
      _ExpositorNelloreSceneState();
}

class _ExpositorNelloreSceneState extends State<ExpositorNelloreScene>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  late Camera _camera;

  final _painterKey = GlobalKey();
  Offset? _gestureOrigin;
  Camera? _cameraAtStart;
  bool    _isDragging = false;
  static const double _dragThreshold = 6.0;

  @override
  void initState() {
    super.initState();
    _camera = Camera(
      rotY:   0.35,
      rotX:   0.18,
      dist:   3.6,
      target: Vec3(0, widget.geometry.alturaTotal / 2, 0),
    );
    _ticker = createTicker((_) {
      if (widget.autoRotate) {
        setState(() => _camera = _camera.copyWith(rotY: _camera.rotY + 0.0025));
      }
    })..start();
  }

  @override
  void didUpdateWidget(ExpositorNelloreScene old) {
    super.didUpdateWidget(old);
    if (old.geometry.height != widget.geometry.height) {
      _camera = Camera(
        rotY:   _camera.rotY,
        rotX:   _camera.rotX,
        dist:   _camera.dist,
        target: Vec3(0, widget.geometry.alturaTotal / 2, 0),
      );
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onScaleStart(ScaleStartDetails d) {
    _gestureOrigin = d.focalPoint;
    _cameraAtStart = _camera;
    _isDragging    = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final origin = _gestureOrigin;
    final c0     = _cameraAtStart;
    if (origin == null || c0 == null) return;
    final delta = d.focalPoint - origin;
    if (delta.distance > _dragThreshold || (d.scale - 1.0).abs() > 0.02) {
      _isDragging = true;
    }
    setState(() {
      _camera = c0.copyWith(
        rotY: c0.rotY - delta.dx * 0.008,
        rotX: (c0.rotX + delta.dy * 0.008).clamp(-0.1, math.pi / 2 - 0.05),
        dist: (c0.dist / d.scale).clamp(1.2, 8.0),
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (!_isDragging && _gestureOrigin != null) {
      _tryFireTap(_gestureOrigin!);
    }
    _gestureOrigin = null;
    _cameraAtStart = null;
    _isDragging    = false;
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

  // Hit-test: cada nível tem seu próprio plano frontal (o deck avança mais
  // que a prateleira, que avança mais que o gancho), então o raio do toque é
  // intersectado plano a plano e testado contra a área clicável das células
  // daquele nível.
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

    ({int coluna, int nivel, double d2})? nearest;
    for (final c in widget.geometry.cells) {
      // Meia-largura clicável da coluna — níveis de 5 colunas têm passo
      // menor, então a área é mais estreita pra não sobrepor a vizinha.
      final hwCelula = colunasNivelNellore(c.nivel) == 5 ? 0.095 : 0.125;
      final zPlano = widget.geometry.zFrenteNivel(c.nivel);
      final t = (zPlano - eye.z) / dir.z;
      if (t <= 0.1) continue;
      final hx = eye.x + t * dir.x;
      final hy = eye.y + t * dir.y;

      final double yMin, yMax;
      if (c.tipo == NelloreTipoNivel.gancho) {
        // Área do pacote pendurado no gancho
        yMin = c.ySurface - ExpositorNelloreGeometry.hPacote - 0.02;
        yMax = c.ySurface + 0.05;
      } else if (c.tipo == NelloreTipoNivel.cesto) {
        yMin = c.ySurface - 0.02;
        yMax = c.ySurface + ExpositorNelloreGeometry._binH + 0.05;
      } else {
        // Prateleira/deck: da superfície até a altura da caixa apoiada
        yMin = c.ySurface - 0.05;
        yMax = c.ySurface + ExpositorNelloreGeometry.hCaixa + 0.05;
      }

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
      final cor = isConferencia
          ? corConferenciaCiano
          : isHighlighted
              ? const Color(0xFFe87722)
              : (widget.corPorProduto[caixa.produtoId] ?? const Color(0xFF888888));
      final celulaList = widget.geometry.cells
          .where((c) => c.coluna == caixa.coluna && c.nivel == caixa.nivel)
          .toList();
      if (celulaList.isEmpty) continue;
      final celula = celulaList.first;
      final chave = chaveEnderecoEstoque(
        produtoCodigo: caixa.produtoId,
        localTipo:     'estante',
        localNum:      expositorNelloreNum,
        faceOuColuna:  caixa.coluna,
        andarOuNivel:  caixa.nivel,
      );
      final desatualizado = widget.desatualizados.contains(chave);
      // Ganchos penduram pacotes; cestos, prateleiras e base empilham caixas.
      if (celula.tipo == NelloreTipoNivel.gancho) {
        ExpositorNelloreGeometry.addPacoteProduto(extraFaces,
            celula: celula, color: cor, desatualizado: desatualizado);
      } else {
        ExpositorNelloreGeometry.addCaixaProduto(extraFaces,
            celula: celula, color: cor, desatualizado: desatualizado);
      }
    }

    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        key:     _painterKey,
        painter: ExpositorNellorePainter(_camera, widget.geometry,
            wireframe:  widget.wireframe,
            showLabels: widget.showLabels,
            extraFaces: extraFaces),
        child:   const SizedBox.expand(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Miniatura do expositor pro mapa da loja (LojaScene) — base amarela, painel
// fino vertical e testeira reta. Chamada no switch de tipos em buildFaces da
// LojaGeometry:
//
//   } else if (item.numero == expositorNelloreNum) {
//     expositorNelloreLoja(faces, item.x, item.z, item.w, item.d, cor);
//   }
// ─────────────────────────────────────────────────────────────────────────────

void expositorNelloreLoja(
  List<Face> faces,
  double cx, double cz, double w, double d,
  Color cor,
) {
  final hw = w / 2, hd = d / 2;
  // Mesma altura das demais estruturas do mapa (LojaGeometry._estanteH).
  const h = 0.85;
  final corTest = Color.lerp(cor, Colors.white, 0.35)!;

  void box(double x0, double x1, double y0, double y1,
           double z0, double z1, Color c) {
    faces.add(Face([Vec3(x0,y1,z0), Vec3(x0,y1,z1), Vec3(x1,y1,z1), Vec3(x1,y1,z0)], c));
    faces.add(Face([Vec3(x0,y0,z1), Vec3(x1,y0,z1), Vec3(x1,y1,z1), Vec3(x0,y1,z1)], c));
    faces.add(Face([Vec3(x1,y0,z0), Vec3(x0,y0,z0), Vec3(x0,y1,z0), Vec3(x1,y1,z0)], c));
    faces.add(Face([Vec3(x1,y0,z1), Vec3(x1,y0,z0), Vec3(x1,y1,z0), Vec3(x1,y1,z1)], c));
    faces.add(Face([Vec3(x0,y0,z0), Vec3(x0,y0,z1), Vec3(x0,y1,z1), Vec3(x0,y1,z0)], c));
  }

  // Base
  box(cx - hw, cx + hw, 0, 0.10, cz - hd, cz + hd, cor);
  // Painel vertical fino (encostado no fundo do footprint)
  box(cx - hw, cx + hw, 0.10, h * 0.80, cz - hd, cz - hd + 0.05, cor);
  // Testeira reta, levemente mais profunda que o painel
  box(cx - hw, cx + hw, h * 0.80, h, cz - hd, cz - hd + 0.14, corTest);
}
