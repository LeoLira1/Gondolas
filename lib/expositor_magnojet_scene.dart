import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'gondola_scene.dart'
    show Vec3, Camera, Face, addBadgeEnderecoDesatualizado, corEnderecoDivergente,
        corEnderecoDivergentePositiva;
import 'models.dart'
    show CaixaColocadaEstante, chaveEnderecoEstoque, colunasBaseMagnojet,
         corConferenciaCiano, expositorMagnojetNum, letraDoIndice;
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorCell — posição de gancho no painel canaletado (ou espaço da base)
//
// O expositor MagnoJet é um painel canaletado (slatwall) com ganchos de arame
// em grade. Cada gancho é um endereço: (coluna, linha). Diferente das estantes,
// aqui não há slots — cada gancho segura UM produto (várias sacolinhas do
// mesmo item empilhadas no pino). Pra reutilizar a infra existente
// (estante_layout no Turso, busca, Modo Conferência), o expositor se apresenta
// como "estante" nº expositorMagnojetNum, com coluna=coluna, nivel=linha e
// slot=0 sempre.
//
// A base (o pé do expositor) também recebe produtos: 5 caixas apoiadas no
// deck, rotuladas 1–5. Ela entra como linha extra APÓS os ganchos
// (linha = linhas, ou seja, nivel 6 na grade padrão), pra não invalidar os
// endereços A–X já salvos no banco.
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorCell {
  final int    coluna;
  final int    linha;      // 0 = linha de baixo; linha == linhas → base
  final bool   ehBase;     // true = espaço de caixa na base (deck)
  final double xCenter;    // centro do gancho/caixa em X
  final double yCenter;    // altura do gancho (ou superfície da base) em Y

  const ExpositorCell({
    required this.coluna,
    required this.linha,
    this.ehBase = false,
    required this.xCenter,
    required this.yCenter,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorMagnojetGeometry — painel canaletado + testeira + ganchos + cesto
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMagnojetGeometry {
  final int    colunas;         // ganchos primários por linha (A–X)
  final int    linhas;          // linhas de ganchos
  final bool   intercalados;    // ganchos NOVOS entre os primários (A1, B1, …)
  final double width;           // largura total do painel (m)
  final double height;          // altura do painel canaletado (sem testeira)
  final bool   showFloor;
  final bool   showCesto;       // cestinho aramado na base

  const ExpositorMagnojetGeometry({
    this.colunas      = 4,
    this.linhas       = 6,
    this.intercalados = true,
    this.width        = 1.05,
    this.height       = 1.70,
    this.showFloor    = true,
    this.showCesto    = true,
  });

  // Ganchos intercalados por linha: um em cada vão entre colunas primárias.
  int get colunasIntercaladas => intercalados ? math.max(0, colunas - 1) : 0;

  // Total de ganchos por linha (primários + intercalados). Também é o número
  // de posições físicas na régua horizontal (2·colunas-1 quando cheio).
  int get colunasPorLinha => colunas + colunasIntercaladas;

  // Altura total incluindo a testeira inclinada (usada pra centrar a câmera).
  double get alturaTotal => height + _testeiraH * math.cos(_testeiraAng) + 0.02;

  // ── Dimensões das sacolinhas (pacotes pendurados) ──────────────────────────
  static const double wPacote = 0.115;  // largura da sacolinha
  static const double hPacote = 0.195;  // altura pendurada
  static const double dPacote = 0.035;  // espessura (pilha de sacolas no pino)
  static const double _hAba   = 0.045;  // aba/cabeçalho azul MagnoJet no topo

  // ── Dimensões das caixas apoiadas na base (espaços 1–5) ────────────────────
  static const double wCaixa = 0.16;
  static const double hCaixa = 0.16;
  static const double dCaixa = 0.16;

  // ── Painel / estrutura ─────────────────────────────────────────────────────
  static const double _painelT     = 0.035;  // espessura do painel
  static const double _ranhuraH    = 0.010;  // altura da ranhura (canaleta)
  static const double _ranhuraGap  = 0.075;  // passo entre ranhuras
  static const double _molduraW    = 0.030;  // moldura lateral preta
  static const double _ganchoLen   = 0.16;   // comprimento do pino de arame
  static const double _ganchoR     = 0.005;  // meia-espessura do pino
  static const double _baseH       = 0.10;   // base/pé do expositor
  static const double _baseD       = 0.42;   // profundidade da base
  static const double _testeiraH   = 0.42;   // altura da placa da testeira
  static const double _testeiraAng = 0.30;   // inclinação p/ frente (rad)

  // ── Paleta (das fotos do expositor real) ───────────────────────────────────
  static const _painel      = Color(0xFFeef0ea);  // branco esverdeado
  static const _ranhura     = Color(0xFF9aa098);  // sombra da canaleta
  static const _moldura     = Color(0xFF23262b);  // moldura preta lateral
  static const _testeira    = Color(0xFFf7f8fa);  // placa branca
  static const _faixaAzul   = Color(0xFF2f6db5);  // faixa azul do topo
  static const _faixaLaranja= Color(0xFFd9985e);  // borda laranja/madeira
  static const _gancho      = Color(0xFFd9dbd5);  // arame branco
  static const _arame       = Color(0xFFe4e6e0);  // cesto aramado
  static const _floor       = Color(0xFF12161d);

  // Azul MagnoJet — aba fixa no topo de toda sacolinha, independe do produto.
  static const corAbaMagnojet = Color(0xFF1f4e9c);

  // Y do centro do gancho na linha i (0 = baixo). Linhas distribuídas na
  // área útil do painel, deixando folga pro pacote pendurado não bater
  // na linha de baixo nem na base.
  double linhaY(int i) {
    final yMin = _baseH + hPacote + 0.06;
    final yMax = height - 0.10;
    return linhas > 1
        ? yMin + (yMax - yMin) * i / (linhas - 1)
        : (yMin + yMax) / 2;
  }

  // X do centro do gancho na coluna lógica c.
  //
  // A régua tem colunasPorLinha posições físicas. As primárias (c < colunas)
  // ocupam as posições PARES (0,2,4,…) e as intercaladas (c ≥ colunas) as
  // ÍMPARES (1,3,5,…) — assim cada intercalado cai no ponto médio entre duas
  // primárias. Como 2·colunas-1 posições com as primárias nos índices pares
  // dá o MESMO X das colunas primárias sem intercalados, os endereços A–X não
  // se deslocam: os novos ganchos só preenchem os vãos.
  double colunaX(int c) {
    final util = width - _molduraW * 2 - wPacote;
    final xMin = -util / 2;
    final n = colunasPorLinha;
    if (n <= 1) return 0;
    // O mapeamento para posições pares só vale quando os intercalados existem
    // (régua de 2·colunas-1 posições). Sem eles a régua tem só `colunas`
    // posições, então a primária c é a posição c — multiplicar por 2 jogaria
    // as últimas colunas para fora do painel.
    final fisica = intercalados
        ? (c < colunas ? c * 2 : (c - colunas) * 2 + 1)
        : c;
    return xMin + util * fisica / (n - 1);
  }

  // Linha reservada pra base (deck): logo após a última fileira de ganchos.
  int get linhaBase => linhas;

  // X do centro do espaço c da base — 5 caixas distribuídas na largura toda.
  double colunaXBase(int c) {
    final util = width - 0.06 * 2 - wCaixa;
    final xMin = -util / 2;
    return colunasBaseMagnojet > 1
        ? xMin + util * c / (colunasBaseMagnojet - 1)
        : 0;
  }

  List<ExpositorCell> get cells => [
        for (var lin = 0; lin < linhas; lin++)
          for (var col = 0; col < colunasPorLinha; col++)
            ExpositorCell(
              coluna:  col,
              linha:   lin,
              xCenter: colunaX(col),
              yCenter: linhaY(lin),
            ),
        for (var col = 0; col < colunasBaseMagnojet; col++)
          ExpositorCell(
            coluna:  col,
            linha:   linhaBase,
            ehBase:  true,
            xCenter: colunaXBase(col),
            yCenter: _baseH,
          ),
      ];

  // Plano frontal do painel — onde o hit-test cruza o raio do toque.
  static double get zFrente => _painelT / 2;

  // Plano frontal da base — o deck avança bem mais que o painel; hit-test e
  // labels dos espaços 1–5 usam este plano.
  static double get zFrenteBase => _baseD * 0.75;

  // ── Sacolinha pendurada num gancho ─────────────────────────────────────────
  //
  // Pacote = aba azul MagnoJet no topo (onde o pino atravessa) + corpo na cor
  // do produto. Pendurado: o topo da aba fica na altura do gancho.
  static void addPacoteProduto(
    List<Face> faces, {
    required ExpositorCell celula,
    required Color color,
    bool desatualizado = false,
  }) {
    final xc = celula.xCenter;
    final yTopo = celula.yCenter + 0.008;
    final z0 = zFrente + _ganchoLen - dPacote - 0.01;
    final z1 = z0 + dPacote;

    // Aba (cabeçalho azul)
    _box(faces,
      x0: xc - wPacote / 2, x1: xc + wPacote / 2,
      y0: yTopo - _hAba,     y1: yTopo,
      z0: z0,                z1: z1,
      color: corAbaMagnojet);

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

  // ── Caixa apoiada num espaço da base (como no Nellore/Monitor) ─────────────
  static void addCaixaProduto(
    List<Face> faces, {
    required ExpositorCell celula,
    required Color color,
    bool desatualizado = false,
  }) {
    final xc = celula.xCenter;
    final y0 = celula.yCenter;
    final z1 = _baseD - 0.03;
    final z0 = z1 - dCaixa;
    _box(faces,
      x0: xc - wCaixa / 2, x1: xc + wCaixa / 2,
      y0: y0,               y1: y0 + hCaixa,
      z0: z0,               z1: z1,
      color: color);
    if (desatualizado) {
      addBadgeEnderecoDesatualizado(faces,
          x1: xc + wCaixa / 2, y1: y0 + hCaixa, z1: z1, tamanho: wCaixa * 0.45);
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

    // ── Base / pé ──────────────────────────────────────────────────────────
    // Segmentada numa grade de blocos: faces grandes empatam no depth-sort
    // com as caixas de produto apoiadas no deck (espaços 1–5) e pintam por
    // cima delas; faces pequenas ordenam direito.
    const nxBase = 5, nzBase = 4;
    for (var i = 0; i < nxBase; i++) {
      for (var j = 0; j < nzBase; j++) {
        _box(faces,
          x0: -hw + 2 * hw * i / nxBase,
          x1: -hw + 2 * hw * (i + 1) / nxBase,
          y0: 0,
          y1: _baseH,
          z0: -_painelT / 2 + (_baseD + _painelT / 2) * j / nzBase,
          z1: -_painelT / 2 + (_baseD + _painelT / 2) * (j + 1) / nzBase,
          color: _painel);
      }
    }

    // ── Painel canaletado ──────────────────────────────────────────────────
    _box(faces,
      x0: -hw + _molduraW, x1: hw - _molduraW,
      y0: _baseH,           y1: height,
      z0: -_painelT / 2,    z1: _painelT / 2,
      color: _painel);

    // Molduras laterais pretas
    for (final sinal in [-1.0, 1.0]) {
      _box(faces,
        x0: sinal * hw - (sinal > 0 ? _molduraW : 0),
        x1: sinal * hw + (sinal > 0 ? 0 : _molduraW),
        y0: _baseH,          y1: height,
        z0: -_painelT / 2 - 0.004, z1: _painelT / 2 + 0.004,
        color: _moldura);
    }

    // Ranhuras horizontais (canaletas) na face frontal — tiras finas escuras
    // levemente à frente do painel pra vencer o depth-sort.
    var y = _baseH + _ranhuraGap;
    while (y < height - 0.04) {
      faces.add(Face([
        Vec3(-hw + _molduraW, y,             _painelT / 2 + 0.002),
        Vec3( hw - _molduraW, y,             _painelT / 2 + 0.002),
        Vec3( hw - _molduraW, y + _ranhuraH, _painelT / 2 + 0.002),
        Vec3(-hw + _molduraW, y + _ranhuraH, _painelT / 2 + 0.002),
      ], _ranhura));
      y += _ranhuraGap;
    }

    // ── Testeira inclinada com a placa MagnoJet ────────────────────────────
    final sinA = math.sin(_testeiraAng), cosA = math.cos(_testeiraAng);
    final y0t = height;
    final y1t = height + _testeiraH * cosA;
    final z0t = _painelT / 2;
    final z1t = _painelT / 2 + _testeiraH * sinA;

    // Placa branca (frente inclinada)
    faces.add(Face([
      Vec3(-hw, y0t, z1t), Vec3( hw, y0t, z1t),
      Vec3( hw, y1t, z0t), Vec3(-hw, y1t, z0t),
    ], _testeira));

    // Faixa azul no alto da placa
    final fy0 = y0t + (y1t - y0t) * 0.80;
    final fz0 = z1t + (z0t - z1t) * 0.80;
    faces.add(Face([
      Vec3(-hw, fy0, fz0 + 0.002), Vec3( hw, fy0, fz0 + 0.002),
      Vec3( hw, y1t, z0t + 0.002), Vec3(-hw, y1t, z0t + 0.002),
    ], _faixaAzul));

    // Borda laranja/madeira na base da testeira
    faces.add(Face([
      Vec3(-hw, y0t - 0.035, z1t + 0.004), Vec3( hw, y0t - 0.035, z1t + 0.004),
      Vec3( hw, y0t + 0.015, z1t + 0.004), Vec3(-hw, y0t + 0.015, z1t + 0.004),
    ], _faixaLaranja));

    // Verso e topo da testeira
    faces.add(Face([
      Vec3( hw, y0t, -_painelT / 2), Vec3(-hw, y0t, -_painelT / 2),
      Vec3(-hw, y1t,  z0t - 0.02),   Vec3( hw, y1t,  z0t - 0.02),
    ], _painel));
    faces.add(Face([
      Vec3(-hw, y1t, z0t - 0.02), Vec3(-hw, y1t, z0t),
      Vec3( hw, y1t, z0t),        Vec3( hw, y1t, z0t - 0.02),
    ], _moldura));

    // ── Ganchos de arame ───────────────────────────────────────────────────
    for (final c in cells) {
      if (c.ehBase) continue;   // espaços da base não têm gancho
      // Haste horizontal saindo do painel
      _box(faces,
        x0: c.xCenter - _ganchoR, x1: c.xCenter + _ganchoR,
        y0: c.yCenter - _ganchoR, y1: c.yCenter + _ganchoR,
        z0: _painelT / 2,          z1: _painelT / 2 + _ganchoLen,
        color: _gancho);
      // Pontinha levantada na extremidade (trava das sacolas)
      _box(faces,
        x0: c.xCenter - _ganchoR, x1: c.xCenter + _ganchoR,
        y0: c.yCenter,             y1: c.yCenter + 0.018,
        z0: _painelT / 2 + _ganchoLen - _ganchoR * 2,
        z1: _painelT / 2 + _ganchoLen,
        color: _gancho);
    }

    // ── Cestinho aramado na base ───────────────────────────────────────────
    if (showCesto) {
      final cw = width * 0.55;
      const cd = 0.16, ch = 0.24;
      final cx0 = hw - _molduraW - cw;
      final cy0 = _baseH + 0.15;
      final cz0 = _painelT / 2 + 0.01;
      const t = 0.006;

      // Aro superior (4 barras)
      _box(faces, x0: cx0, x1: cx0 + cw, y0: cy0 + ch - t, y1: cy0 + ch,
          z0: cz0, z1: cz0 + t, color: _arame);
      _box(faces, x0: cx0, x1: cx0 + cw, y0: cy0 + ch - t, y1: cy0 + ch,
          z0: cz0 + cd - t, z1: cz0 + cd, color: _arame);
      _box(faces, x0: cx0, x1: cx0 + t, y0: cy0 + ch - t, y1: cy0 + ch,
          z0: cz0, z1: cz0 + cd, color: _arame);
      _box(faces, x0: cx0 + cw - t, x1: cx0 + cw, y0: cy0 + ch - t,
          y1: cy0 + ch, z0: cz0, z1: cz0 + cd, color: _arame);

      // Verticais frontais (grade de arame)
      for (var i = 0; i <= 6; i++) {
        final x = cx0 + cw * i / 6;
        _box(faces, x0: x - t / 2, x1: x + t / 2, y0: cy0, y1: cy0 + ch,
            z0: cz0 + cd - t, z1: cz0 + cd, color: _arame);
      }
      // Fundo do cesto
      _box(faces, x0: cx0, x1: cx0 + cw, y0: cy0, y1: cy0 + t,
          z0: cz0, z1: cz0 + cd, color: _arame);
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
// ExpositorMagnojetPainter
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMagnojetPainter extends CustomPainter {
  final Camera                     camera;
  final ExpositorMagnojetGeometry  geometry;
  final bool                       wireframe;
  final bool                       showLabels;
  final List<Face>                 extraFaces;

  static final Vec3 _lightDir = Vec3(4, 10, 5).normalized;

  const ExpositorMagnojetPainter(this.camera, this.geometry, {
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

  // Escreve "MagnoJet" projetado no centro da testeira — texto 2D em cima do
  // 3D, mesma técnica dos labels de nível. Só desenha quando a placa está
  // aproximadamente de frente pra câmera (evita texto "flutuando" no verso).
  void _drawMarca(Canvas canvas, Size size) {
    // Centro da placa inclinada, levemente à frente
    const ang = ExpositorMagnojetGeometry._testeiraAng;
    final g   = geometry;
    final yC  = g.height + _testeiraMeiaAltura * math.cos(ang);
    final zC  = ExpositorMagnojetGeometry._painelT / 2 +
                _testeiraMeiaAltura * math.sin(ang) + 0.01;

    // Só mostra se a câmera está no hemisfério frontal (+Z)
    if (camera.position.z <= 0.3) return;

    final hit = _projectPoint(Vec3(0, yC, zC), size);
    if (hit == null) return;
    final (screen, cz) = hit;

    final fontSize = 26.0 * (2.6 / cz).clamp(0.4, 1.6);
    final tp = TextPainter(
      text: TextSpan(children: [
        TextSpan(
          text: 'Magno',
          style: TextStyle(
            color:      ExpositorMagnojetGeometry.corAbaMagnojet,
            fontSize:   fontSize,
            fontWeight: FontWeight.w800,
            fontStyle:  FontStyle.italic,
          ),
        ),
        TextSpan(
          text: 'Jet',
          style: TextStyle(
            color:      const Color(0xFF4ba3dd),
            fontSize:   fontSize,
            fontWeight: FontWeight.w800,
            fontStyle:  FontStyle.italic,
          ),
        ),
      ]),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
  }

  static const double _testeiraMeiaAltura =
      ExpositorMagnojetGeometry._testeiraH * 0.45;

  void _drawLabels(Canvas canvas, Size size) {
    const camda   = Color(0xFFe87722);
    const bgColor = Color(0xC70b0c0e);

    final bgPaint  = Paint()..color = bgColor;
    final rimPaint = Paint()
      ..color       = camda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Letra por gancho: linhas de cima pra baixo, colunas da esquerda pra
    // direita — mesma convenção de leitura das estantes (A = topo-esquerda).
    // Os espaços da base mostram números 1–5.
    for (final c in geometry.cells) {
      final hit = _projectPoint(
          c.ehBase
              ? Vec3(c.xCenter,
                     c.yCenter + 0.06,
                     ExpositorMagnojetGeometry.zFrenteBase + 0.02)
              : Vec3(c.xCenter,
                     c.yCenter + 0.045,
                     ExpositorMagnojetGeometry.zFrente +
                         ExpositorMagnojetGeometry._ganchoLen + 0.01),
          size);
      if (hit == null) continue;

      final (screen, cz) = hit;
      final fontSize = 15.0 * (3.0 / cz).clamp(0.5, 1.6);
      final radius   = fontSize * 0.72;

      canvas.drawCircle(screen, radius, bgPaint);
      canvas.drawCircle(screen, radius, rimPaint);

      final row   = geometry.linhas - 1 - c.linha;
      // Base → número; gancho primário → letra A–X; gancho intercalado →
      // letra da primária à esquerda + "1" (A1, B1, …).
      final letra = c.ehBase
          ? '${c.coluna + 1}'
          : c.coluna < geometry.colunas
              ? letraDoIndice(row * geometry.colunas + c.coluna)
              : '${letraDoIndice(row * geometry.colunas + (c.coluna - geometry.colunas))}1';
      final tp = TextPainter(
        text: TextSpan(
          text: letra,
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
  bool shouldRepaint(ExpositorMagnojetPainter old) =>
      old.camera.rotY         != camera.rotY         ||
      old.camera.rotX         != camera.rotX         ||
      old.camera.dist         != camera.dist         ||
      old.wireframe           != wireframe           ||
      old.showLabels          != showLabels          ||
      old.extraFaces          != extraFaces          ||
      old.geometry.colunas      != geometry.colunas      ||
      old.geometry.intercalados != geometry.intercalados ||
      old.geometry.linhas       != geometry.linhas       ||
      old.geometry.width      != geometry.width      ||
      old.geometry.height     != geometry.height     ||
      old.geometry.showCesto  != geometry.showCesto  ||
      old.geometry.showFloor  != geometry.showFloor;
}

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorMagnojetScene — 3D interativo com suporte a produtos
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMagnojetScene extends StatefulWidget {
  final ExpositorMagnojetGeometry geometry;
  final bool                      wireframe;
  final bool                      autoRotate;
  final bool                      showLabels;
  // Reutiliza CaixaColocadaEstante: coluna = coluna do gancho (ou espaço
  // 0–4 da base), nivel = linha do gancho (linhaBase = deck), slot = 0
  // sempre (um produto por endereço).
  final List<CaixaColocadaEstante> caixas;
  final String?                    produtoSelecionadoId;
  final Map<String, Color>         corPorProduto;
  final void Function(int coluna, int linha)? onTapGancho;
  final void Function(int coluna, int linha)? onTapGanchoVisualizar;
  final String?                    destacadoCodigo;
  final Set<String>                desatualizados;
  final Set<String>                divergentes;
  final Set<String>                divergentesPositivas;
  final Set<String>                destacadosCodigos;

  const ExpositorMagnojetScene({
    super.key,
    required this.geometry,
    this.wireframe            = false,
    this.autoRotate           = true,
    this.showLabels           = true,
    this.caixas               = const [],
    this.produtoSelecionadoId,
    this.corPorProduto        = const {},
    this.onTapGancho,
    this.onTapGanchoVisualizar,
    this.destacadoCodigo,
    this.desatualizados       = const {},
    this.divergentes          = const {},
    this.divergentesPositivas = const {},
    this.destacadosCodigos    = const {},
  });

  @override
  State<ExpositorMagnojetScene> createState() =>
      _ExpositorMagnojetSceneState();
}

class _ExpositorMagnojetSceneState extends State<ExpositorMagnojetScene>
    with SingleTickerProviderStateMixin, SceneGestureGuard<ExpositorMagnojetScene> {
  late Ticker _ticker;
  late Camera _camera;

  final _painterKey = GlobalKey();
  Camera? _cameraAtStart;

  @override
  void initState() {
    super.initState();
    _camera = Camera(
      rotY:   0.35,
      rotX:   0.18,
      dist:   3.2,
      target: Vec3(0, widget.geometry.alturaTotal / 2, 0),
    );
    _ticker = createTicker((_) {
      if (widget.autoRotate) {
        setState(() => _camera = _camera.copyWith(rotY: _camera.rotY + 0.0025));
      }
    })..start();
  }

  @override
  void didUpdateWidget(ExpositorMagnojetScene old) {
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
        dist: (c0.dist / d.scale).clamp(1.2, 8.0),
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
      widget.onTapGancho?.call(hit.coluna, hit.linha);
    } else {
      widget.onTapGanchoVisualizar?.call(hit.coluna, hit.linha);
    }
  }

  // Hit-test: os ganchos vivem no plano frontal do painel e a base avança
  // bem mais, então o raio do toque é intersectado plano a plano — o do
  // gancho pra área do pacote pendurado, o do deck pra área da caixa.
  ({int coluna, int linha})? _hitTest(Offset tap, Size size) {
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

    // Plano vertical z = const só é atingível se dir.z tem componente
    if (dir.z.abs() < 1e-6) return null;

    const hp = ExpositorMagnojetGeometry.hPacote;

    ({int coluna, int linha, double d2})? nearest;
    for (final c in widget.geometry.cells) {
      final zPlano = c.ehBase
          ? ExpositorMagnojetGeometry.zFrenteBase
          : ExpositorMagnojetGeometry.zFrente +
              ExpositorMagnojetGeometry._ganchoLen / 2;
      final t = (zPlano - eye.z) / dir.z;
      if (t <= 0.1) continue;

      final hx = eye.x + t * dir.x;
      final hy = eye.y + t * dir.y;

      // Área clicável: retângulo do pacote pendurado (gancho) ou da caixa
      // apoiada no deck (base).
      final double hw, yMin, yMax;
      if (c.ehBase) {
        hw   = ExpositorMagnojetGeometry.wCaixa / 2 + 0.02;
        yMin = c.yCenter - 0.05;
        yMax = c.yCenter + ExpositorMagnojetGeometry.hCaixa + 0.05;
      } else {
        hw   = ExpositorMagnojetGeometry.wPacote / 2 + 0.015;
        yMin = c.yCenter - hp - 0.02;
        yMax = c.yCenter + 0.04;
      }
      if ((hx - c.xCenter).abs() > hw) continue;
      if (hy < yMin || hy > yMax) continue;

      final dx = hx - c.xCenter;
      final dy = hy - (yMin + yMax) / 2;
      final d2 = dx * dx + dy * dy;
      if (nearest == null || d2 < nearest.d2) {
        nearest = (coluna: c.coluna, linha: c.linha, d2: d2);
      }
    }

    return nearest == null
        ? null
        : (coluna: nearest.coluna, linha: nearest.linha);
  }

  @override
  Widget build(BuildContext context) {
    final extraFaces = <Face>[];
    for (final caixa in widget.caixas) {
      final isConferencia = widget.destacadosCodigos.contains(caixa.produtoId);
      final isHighlighted = caixa.produtoId == widget.destacadoCodigo;
      final celulaList = widget.geometry.cells
          .where((c) => c.coluna == caixa.coluna && c.linha == caixa.nivel)
          .toList();
      if (celulaList.isEmpty) continue;
      final celula = celulaList.first;
      final chave = chaveEnderecoEstoque(
        produtoCodigo: caixa.produtoId,
        localTipo:     'estante',
        localNum:      expositorMagnojetNum,
        faceOuColuna:  caixa.coluna,
        andarOuNivel:  caixa.nivel,
      );
      final desatualizado = widget.desatualizados.contains(chave);
      // Divergência de contagem pinta a caixa inteira: azul escuro quando é
      // positiva (contado > sistema), vermelho nas demais. Destaques de
      // conferência e busca (momentâneos) têm prioridade sobre ela.
      final divergente = widget.divergentes.contains(chave);
      final divergentePositiva = widget.divergentesPositivas.contains(chave);
      final cor = isConferencia
          ? corConferenciaCiano
          : isHighlighted
              ? const Color(0xFFe87722)
              : divergentePositiva
                  ? corEnderecoDivergentePositiva
                  : divergente
                      ? corEnderecoDivergente
                      : (widget.corPorProduto[caixa.produtoId] ?? const Color(0xFF888888));
      // Ganchos penduram sacolinhas; a base apoia caixas no deck.
      if (celula.ehBase) {
        ExpositorMagnojetGeometry.addCaixaProduto(extraFaces,
            celula: celula, color: cor, desatualizado: desatualizado);
      } else {
        ExpositorMagnojetGeometry.addPacoteProduto(extraFaces,
            celula: celula, color: cor, desatualizado: desatualizado);
      }
    }

    return GestureDetector(
      onScaleStart:  _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd:    _onScaleEnd,
      child: CustomPaint(
        key:     _painterKey,
        painter: ExpositorMagnojetPainter(_camera, widget.geometry,
            wireframe:  widget.wireframe,
            showLabels: widget.showLabels,
            extraFaces: extraFaces),
        child:   const SizedBox.expand(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Miniatura do expositor pro mapa da loja (LojaScene) — painel fino vertical
// com testeira inclinada. Copie a chamada pro switch de tipos em buildFaces
// da LojaGeometry:
//
//   } else if (item.numero == expositorMagnojetNum) {
//     expositorMagnojetLoja(faces, item.x, item.z, item.w, item.d, cor);
//   }
// ─────────────────────────────────────────────────────────────────────────────

void expositorMagnojetLoja(
  List<Face> faces,
  double cx, double cz, double w, double d,
  Color cor,
) {
  final hw = w / 2, hd = d / 2;
  // Mesma altura das demais estruturas do mapa (LojaGeometry._estanteH),
  // pra não estourar a linha da parede na miniatura.
  const h  = 0.85;
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
  box(cx - hw, cx + hw, 0.10, h * 0.82, cz - hd, cz - hd + 0.05, cor);
  // Testeira inclinada
  faces.add(Face([
    Vec3(cx - hw, h * 0.82, cz - hd + 0.05),
    Vec3(cx + hw, h * 0.82, cz - hd + 0.05),
    Vec3(cx + hw, h,        cz - hd + 0.18),
    Vec3(cx - hw, h,        cz - hd + 0.18),
  ], corTest));
}
