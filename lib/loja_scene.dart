import 'dart:math' as math;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'expositor_magnojet_scene.dart' show expositorMagnojetLoja;
import 'expositor_monitor_scene.dart' show expositorMonitorLoja;
import 'expositor_nellore_scene.dart' show expositorNelloreLoja;
import 'gondola_scene.dart' show Vec3, Camera, Face, faceAngle;
import 'models.dart'
    show colunasEdr300Tripla, corConferenciaCiano, ehEstanteEdr300,
         ehEstanteParede, estanteEdr300TriplaNum, estanteParedeMin,
         expositorMagnojetNum, expositorMonitorNum, expositorNelloreNum;
import 'scene_gestures.dart';

/// Número usado para achar a estrutura em itensLoja: as 6 seções da Estante
/// Parede (13–18) são um retângulo único no mapa, registrado como o número da
/// primeira seção (13).
int numeroNoMapaLoja(String tipo, int numero) =>
    tipo == 'estante' && ehEstanteParede(numero) ? estanteParedeMin : numero;

// ── Data classes ──────────────────────────────────────────────────────────────

class ItemLoja {
  final String tipo;   // 'gondola' ou 'estante'
  final int numero;
  final double x, z;
  final double w, d;
  final double rotacao;

  const ItemLoja({
    required this.tipo,
    required this.numero,
    required this.x,
    required this.z,
    this.w = 0.7,
    this.d = 1.6,
    this.rotacao = 0,
  });
}

class ProdutoLoja {
  final String nome;
  final String tipo;           // 'gondola' ou 'estante'
  final int    numero;
  final String nivel;
  final String produtoCodigo;  // código do produto para destacar na cena
  final int?   face;           // 1-6 (só gôndolas), para pré-selecionar no detalhe
  final int?   andar;          // 0-2 (só gôndolas)

  const ProdutoLoja({
    required this.nome,
    required this.tipo,
    required this.numero,
    required this.nivel,
    required this.produtoCodigo,
    this.face,
    this.andar,
  });
}

// ── Layout fixo da loja (posições do protótipo HTML) ─────────────────────────

const double lojaW = 10.0;
const double lojaH = 14.0;

// Pontos de referência fixos da loja, escritos no chão do mapa.
const List<({String nome, double x, double z})> referenciasLoja = [
  (nome: 'CAIXA',       x: 5.0, z: 0.8),
  (nome: 'BALCÃO LOJA', x: 0.9, z: 8.0),
  (nome: 'COZINHA',     x: 9.2, z: 8.0),
  (nome: 'ENTRADA',     x: 7.5, z: 13.6),
  (nome: 'ENTRADA 2',   x: 2.5, z: 13.6),
];

const List<ItemLoja> itensLoja = [
  // 12 gôndolas
  ItemLoja(tipo: 'gondola', numero: 12, x: 3.0, z:  4.0),
  ItemLoja(tipo: 'gondola', numero:  7, x: 5.0, z:  4.0),
  ItemLoja(tipo: 'gondola', numero:  5, x: 7.0, z:  4.0),
  ItemLoja(tipo: 'gondola', numero: 11, x: 3.0, z:  6.0),
  ItemLoja(tipo: 'gondola', numero:  4, x: 7.0, z:  6.0),
  ItemLoja(tipo: 'gondola', numero: 10, x: 3.0, z:  8.0),
  ItemLoja(tipo: 'gondola', numero:  3, x: 7.0, z:  8.0),
  ItemLoja(tipo: 'gondola', numero:  9, x: 3.0, z: 10.0),
  ItemLoja(tipo: 'gondola', numero:  2, x: 7.0, z: 10.0),
  ItemLoja(tipo: 'gondola', numero:  8, x: 3.0, z: 12.0),
  ItemLoja(tipo: 'gondola', numero:  6, x: 5.0, z: 12.0),
  ItemLoja(tipo: 'gondola', numero:  1, x: 7.0, z: 12.0),
  // 8 estantes encostadas nas paredes
  ItemLoja(tipo: 'estante', numero: 7, x: 1.00, z:  1.0, w: 0.7, d: 1.6),
  ItemLoja(tipo: 'estante', numero: 8, x: 2.10, z: 0.55, w: 1.4, d: 0.7),
  ItemLoja(tipo: 'estante', numero: 9, x: 6.45, z: 0.55, w: 1.05, d: 0.55),
  ItemLoja(tipo: 'estante', numero: 6, x: 3.20, z:  1.0, w: 0.7, d: 1.6),
  // Expositor Monitor Produtos Agropecuários: entre a estante 6 e o Nellore
  ItemLoja(tipo: 'estante', numero: expositorMonitorNum,
      x: 4.20, z: 0.55, w: 1.14, d: 0.62),
  // Expositor Nellore Isoflex/Avant: entre o Monitor e o MagnoJet (E9)
  ItemLoja(tipo: 'estante', numero: expositorNelloreNum,
      x: 5.35, z: 0.55, w: 0.85, d: 0.55),
  ItemLoja(tipo: 'estante', numero: 2, x: 9.45, z:  2.0, w: 0.7, d: 1.6),
  ItemLoja(tipo: 'estante', numero: 1, x: 9.45, z:  4.0, w: 0.7, d: 1.6),
  // Estante Parede (seções 13–18): peça única comprida e baixa na parede
  // esquerda, no lugar das antigas estantes 3 e 4. Toque leva à seção 1
  // (E13). Posição aproximada — ajuste fino em x/z/d conforme a loja real.
  ItemLoja(tipo: 'estante', numero: estanteParedeMin,
      x: 0.45, z: 10.6, w: 0.55, d: 4.4),
];

// Catálogo mock — substituir por query Turso quando disponível
const List<ProdutoLoja> catalogoLojaFake = [
  ProdutoLoja(nome: 'CHINCHA P/ARREIO 2 ARGOLAS PASFIL C099', tipo: 'gondola', numero: 11, nivel: 'Andar Base', produtoCodigo: 'C099'),
  ProdutoLoja(nome: 'HERBICIDA NORTOX 2,4-D 806 SL 5L',       tipo: 'gondola', numero:  5, nivel: 'Andar 2',   produtoCodigo: 'HERB001'),
  ProdutoLoja(nome: 'FUNGICIDA OUROFINO AZOX 200 1L',         tipo: 'gondola', numero:  7, nivel: 'Andar 1',   produtoCodigo: 'FUNG001'),
  ProdutoLoja(nome: 'ADUBO FOLIAR ZOETIS BORO 20L',           tipo: 'estante', numero:  4, nivel: 'Nível 2',   produtoCodigo: 'ADUB001'),
  ProdutoLoja(nome: 'SEMENTE MILHO HIBRIDO SC 60kg',          tipo: 'estante', numero:  3, nivel: 'Nível 1',   produtoCodigo: 'SEM001'),
  ProdutoLoja(nome: 'INSETICIDA FMC LANNATE BR 1L',           tipo: 'gondola', numero:  9, nivel: 'Andar Base', produtoCodigo: 'INSE001'),
  ProdutoLoja(nome: 'CORDA SISAL 10MM ROLO 50M',              tipo: 'estante', numero:  6, nivel: 'Nível 3',   produtoCodigo: 'CORD001'),
  ProdutoLoja(nome: 'LUVA NITRILICA PROTECAO PAR',            tipo: 'estante', numero:  1, nivel: 'Nível 4',   produtoCodigo: 'LUVA001'),
  ProdutoLoja(nome: 'FERTILIZANTE NPK 04-14-08 SC 50kg',      tipo: 'gondola', numero:  3, nivel: 'Andar 1',   produtoCodigo: 'FERT001'),
  ProdutoLoja(nome: 'BALDE PLASTICO 20L AZUL',                tipo: 'gondola', numero:  2, nivel: 'Andar Base', produtoCodigo: 'BALD001'),
];

// ── Colors ────────────────────────────────────────────────────────────────────

const Color corGondolaLoja = Color(0xFF4caf50);
const Color corEstanteLoja = Color(0xFF4a93d8);
const Color _corApagado    = Color(0xFF2d2e31);
const Color _corParede     = Color(0xFF2a2b2f);
const Color _corBg         = Color(0xFF0b0c0e);

// ── LojaGeometry ──────────────────────────────────────────────────────────────

class LojaGeometry {
  static const double gondolaR      = 0.62;
  static const double _estanteH     = 0.85;
  static const double _paredeH      = 0.90;
  static const double _paredeEsp    = 0.18;
  static const int    _estanteNiveis = 5;
  static const double _shelfT       = 0.013;

  static double _nivelY(int i) =>
      i * (_estanteH - _shelfT) / (_estanteNiveis - 1);

  static List<Face> buildFaces(
    int? selecionadoIdx,
    double pulseT, {
    bool modoConferencia = false,
    Set<int> idxConferencia = const {},
  }) {
    final faces = <Face>[];

    // Paredes perimetrais
    _wallBox(faces, 0, _paredeEsp, 0, lojaH);
    _wallBox(faces, 0, lojaW, 0, _paredeEsp);
    _wallBox(faces, 0, lojaW, lojaH - _paredeEsp, lojaH);
    _wallBox(faces, lojaW - _paredeEsp, lojaW, 0, lojaH);

    // Estruturas
    for (var i = 0; i < itensLoja.length; i++) {
      final item   = itensLoja[i];
      final isSel  = selecionadoIdx == i;
      final hasSel = selecionadoIdx != null;

      final Color cor;
      if (modoConferencia) {
        // Modo Conferência (Fase 3) substitui o esquema de seleção normal:
        // ciano pulsante nas estruturas com pendentes, apagado nas demais.
        if (idxConferencia.contains(i)) {
          final pulse = (0.35 + 0.25 * math.sin(pulseT * 2.2)).clamp(0.0, 1.0);
          cor = Color.lerp(corConferenciaCiano, Colors.white, pulse * 0.3)!;
        } else {
          cor = _corApagado;
        }
      } else if (!hasSel) {
        cor = item.tipo == 'gondola' ? corGondolaLoja : corEstanteLoja;
      } else if (isSel) {
        final base  = item.tipo == 'gondola' ? corGondolaLoja : corEstanteLoja;
        final pulse = (0.35 + 0.25 * math.sin(pulseT * 2.2)).clamp(0.0, 1.0);
        cor = Color.lerp(base, Colors.white, pulse * 0.35)!;
      } else {
        cor = _corApagado;
      }

      if (item.tipo == 'gondola') {
        _gondola(faces, item, cor);
      } else if (item.numero == estanteEdr300TriplaNum) {
        _estanteEdr300Tripla(faces, item, cor);
      } else if (item.numero == 8) {
        _estanteEdr300(faces, item, cor);
      } else if (item.numero == expositorMagnojetNum) {
        expositorMagnojetLoja(faces, item.x, item.z, item.w, item.d, cor);
      } else if (item.numero == expositorNelloreNum) {
        expositorNelloreLoja(faces, item.x, item.z, item.w, item.d, cor);
      } else if (item.numero == expositorMonitorNum) {
        expositorMonitorLoja(faces, item.x, item.z, item.w, item.d, cor);
      } else if (ehEstanteParede(item.numero)) {
        _estanteParede(faces, item, cor);
      } else {
        _estante(faces, item, cor);
      }
    }

    return faces;
  }

  static void _wallBox(List<Face> f, double x0, double x1, double z0, double z1) {
    const h = _paredeH;
    const c = _corParede;
    f.add(Face([Vec3(x0,0,z1), Vec3(x1,0,z1), Vec3(x1,h,z1), Vec3(x0,h,z1)], c));
    f.add(Face([Vec3(x1,0,z0), Vec3(x0,0,z0), Vec3(x0,h,z0), Vec3(x1,h,z0)], c));
    f.add(Face([Vec3(x0,0,z0), Vec3(x0,0,z1), Vec3(x0,h,z1), Vec3(x0,h,z0)], c));
    f.add(Face([Vec3(x1,0,z1), Vec3(x1,0,z0), Vec3(x1,h,z0), Vec3(x1,h,z1)], c));
    f.add(Face([Vec3(x0,h,z0), Vec3(x0,h,z1), Vec3(x1,h,z1), Vec3(x1,h,z0)], c));
  }

  static void _gondola(List<Face> faces, ItemLoja item, Color cor) {
    // 3-shelf silhouette scaled to match gondolaR footprint.
    // Uses 6-sided prisms (no feet, no borda) to keep face count low
    // while 12 gondolas render simultaneously on the map.
    const scale = gondolaR / 3.4;
    const shelves = [(3.4, 0.675, 0.35), (2.4, 2.15, 0.30), (1.5, 3.43, 0.26)];
    for (final (r, yc, h) in shelves) {
      _prism6(faces, cx: item.x, cz: item.z,
              r: r * scale,
              y0: (yc - h / 2) * scale, y1: (yc + h / 2) * scale, cor: cor);
    }
    // Central pillar
    _prism6(faces, cx: item.x, cz: item.z,
            r: 0.28 * scale, y0: 0.85 * scale, y1: 3.30 * scale, cor: cor);
  }

  static void _prism6(List<Face> faces, {
    required double cx, required double cz,
    required double r, required double y0, required double y1,
    required Color cor,
  }) {
    const sides = 6;
    for (var i = 0; i < sides; i++) {
      final a0 = i * 2 * math.pi / sides;
      final a1 = (i + 1) * 2 * math.pi / sides;
      faces.add(Face([
        Vec3(cx + r * math.cos(a0), y0, cz + r * math.sin(a0)),
        Vec3(cx + r * math.cos(a0), y1, cz + r * math.sin(a0)),
        Vec3(cx + r * math.cos(a1), y1, cz + r * math.sin(a1)),
        Vec3(cx + r * math.cos(a1), y0, cz + r * math.sin(a1)),
      ], cor));
    }
    faces.add(Face([
      for (var i = sides - 1; i >= 0; i--)
        Vec3(cx + r * math.cos(i * 2 * math.pi / sides), y1,
             cz + r * math.sin(i * 2 * math.pi / sides)),
    ], cor));
  }

  static void _estante(List<Face> faces, ItemLoja item, Color cor) {
    final cx = item.x, cz = item.z;
    final hw = item.w / 2, hd = item.d / 2;
    const h  = _estanteH;
    const pW = 0.040;
    const pD = 0.028;
    const sT = _shelfT;

    final corPost = Color.lerp(cor, const Color(0xFF000000), 0.45)!;

    // 4 corner posts
    for (final (px, pz) in [
      (cx - hw + pW, cz - hd + pD),
      (cx + hw - pW, cz - hd + pD),
      (cx - hw + pW, cz + hd - pD),
      (cx + hw - pW, cz + hd - pD),
    ]) {
      _boxLoja(faces,
        x0: px - pW, x1: px + pW,
        y0: 0,        y1: h,
        z0: pz - pD,  z1: pz + pD,
        color: corPost);
    }

    // 5 horizontal shelves
    for (var i = 0; i < _estanteNiveis; i++) {
      final y = _nivelY(i);
      _boxLoja(faces,
        x0: cx - hw + pW * 2, x1: cx + hw - pW * 2,
        y0: y,                 y1: y + sT,
        z0: cz - hd + pD,     z1: cz + hd - pD,
        color: cor);
    }
  }

  // Renderiza a Estante Parede (seções 13–18): peça única comprida e baixa —
  // 6 prateleiras "flutuantes" e ferros verticais no lado da parede (x menor),
  // sem montantes na frente.
  static void _estanteParede(List<Face> faces, ItemLoja item, Color cor) {
    final cx = item.x, cz = item.z;
    final hw = item.w / 2, hd = item.d / 2;
    const h       = 0.55;
    const nNiveis = 6;
    const nSecoes = 6;
    const sT      = _shelfT;

    final corFerro = Color.lerp(cor, const Color(0xFF000000), 0.45)!;

    // Ferros verticais traseiros nas bordas das 6 seções (7 ferros).
    for (var i = 0; i <= nSecoes; i++) {
      final z = cz - hd + item.d * i / nSecoes;
      _boxLoja(faces,
        x0: cx - hw,      x1: cx - hw + 0.06,
        y0: 0,            y1: h + 0.04,
        z0: z - 0.02,     z1: z + 0.02,
        color: corFerro);
    }

    // 6 prateleiras horizontais full-length.
    for (var i = 0; i < nNiveis; i++) {
      final y = i * (h - sT) / (nNiveis - 1);
      _boxLoja(faces,
        x0: cx - hw + 0.04, x1: cx + hw,
        y0: y,               y1: y + sT,
        z0: cz - hd,         z1: cz + hd,
        color: cor);
    }
  }

  // Renderiza a Estante 6 como 3 EDR-300 encostadas, repartindo o retângulo
  // dela no mapa ao longo do lado maior (1 módulo do mapa = 1 coluna da cena
  // de detalhe, contado do canto de menor coordenada).
  static void _estanteEdr300Tripla(List<Face> faces, ItemLoja item, Color cor) {
    const n = colunasEdr300Tripla;
    for (var k = 0; k < n; k++) {
      final aoLongoDeZ = item.d >= item.w;
      final modulo = aoLongoDeZ
          ? ItemLoja(
              tipo: item.tipo, numero: item.numero,
              x: item.x, z: item.z - item.d / 2 + item.d * (k + 0.5) / n,
              w: item.w, d: item.d / n)
          : ItemLoja(
              tipo: item.tipo, numero: item.numero,
              x: item.x - item.w / 2 + item.w * (k + 0.5) / n, z: item.z,
              w: item.w / n, d: item.d);
      _estanteEdr300(faces, modulo, cor);
    }
  }

  // Renderiza uma EDR-300 (estante 8 ou um módulo da 6): 4 montantes +
  // 6 prateleiras horizontais
  static void _estanteEdr300(List<Face> faces, ItemLoja item, Color cor) {
    final cx = item.x, cz = item.z;
    final hw = item.w / 2, hd = item.d / 2;
    const h       = _estanteH;
    const pW      = 0.040; // meia-largura do montante em X
    const pD      = 0.028; // meia-profundidade do montante em Z
    const sT      = 0.013; // espessura da prateleira
    const nShelves = 6;

    final corPost = Color.lerp(cor, const Color(0xFF000000), 0.45)!;

    // 4 montantes nos cantos
    for (final (px, pz) in [
      (cx - hw + pW, cz - hd + pD),
      (cx + hw - pW, cz - hd + pD),
      (cx - hw + pW, cz + hd - pD),
      (cx + hw - pW, cz + hd - pD),
    ]) {
      _boxLoja(faces,
        x0: px - pW, x1: px + pW,
        y0: 0,        y1: h,
        z0: pz - pD,  z1: pz + pD,
        color: corPost);
    }

    // 6 prateleiras horizontais
    for (var i = 0; i < nShelves; i++) {
      final y = i * (h - sT) / (nShelves - 1);
      _boxLoja(faces,
        x0: cx - hw + pW * 2, x1: cx + hw - pW * 2,
        y0: y,                 y1: y + sT,
        z0: cz - hd + pD,     z1: cz + hd - pD,
        color: cor);
    }
  }

  static void _boxLoja(List<Face> faces, {
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

// ── LojaPainter ───────────────────────────────────────────────────────────────

class LojaPainter extends CustomPainter {
  final Camera camera;
  final int?   selecionadoIdx;
  final double pulseT;
  // Modo Conferência (Fase 3): quando ativo, idxContagem traz o índice de
  // cada estrutura com pendentes (em itensLoja) e a contagem de produtos
  // pendentes nela, pra desenhar o badge "G9 · 3" sem nenhuma query no paint.
  final bool          modoConferencia;
  final Map<int, int> contagemConferencia;

  static final Vec3 _lightDir = Vec3(5, 10, 7).normalized;

  LojaPainter(
    this.camera, {
    this.selecionadoIdx,
    this.pulseT = 0,
    this.modoConferencia = false,
    this.contagemConferencia = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _corBg);
    final faces = LojaGeometry.buildFaces(
      selecionadoIdx,
      pulseT,
      modoConferencia: modoConferencia,
      idxConferencia: contagemConferencia.keys.toSet(),
    );
    _project(faces, size);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces);
    _drawLabels(canvas, size);
  }

  // Sutherland-Hodgman near-plane clipping fixes the disappearing-face bug
  // that occurred when any vertex crossed behind the camera near plane.
  void _project(List<Face> faces, Size size) {
    final eye    = camera.position;
    final fwd    = (camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 45.0 * math.pi / 180.0;
    const near   = 0.1;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;
    final w = size.width, h = size.height;

    Offset toScreen(Vec3 v) {
      final d  = v - eye;
      final cz = d.dot(fwd);
      final cx = d.dot(right) / (cz * tanH * aspect);
      final cy = d.dot(up)    / (cz * tanH);
      return Offset((cx + 1) / 2 * w, (1 - cy) / 2 * h);
    }

    List<Vec3> clipNear(List<Vec3> verts) {
      final out = <Vec3>[];
      final len = verts.length;
      for (var i = 0; i < len; i++) {
        final a = verts[i];
        final b = verts[(i + 1) % len];
        final da = (a - eye).dot(fwd);
        final db = (b - eye).dot(fwd);
        if (da >= near) out.add(a);
        if ((da >= near) != (db >= near)) {
          final t = (near - da) / (db - da);
          out.add(Vec3(
            a.x + (b.x - a.x) * t,
            a.y + (b.y - a.y) * t,
            a.z + (b.z - a.z) * t,
          ));
        }
      }
      return out;
    }

    for (final f in faces) {
      final clipped = clipNear(f.verts);
      if (clipped.length < 3) {
        f.proj  = const [];
        f.depth = -1e9;
        continue;
      }
      f.proj  = clipped.map(toScreen).toList();
      f.depth = clipped.fold(0.0, (s, v) => s + (v - eye).dot(fwd)) / clipped.length;
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
      ..color       = const Color(0x44000000)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 0.6;

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
    final eye    = camera.position;
    final fwd    = (camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 45.0 * math.pi / 180.0;
    const near   = 0.1;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;
    final w = size.width, h = size.height;

    (Offset, double)? project(Vec3 v) {
      final d  = v - eye;
      final cz = d.dot(fwd);
      if (cz <= near) return null;
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

    // Rótulos de referência escritos no chão (discretos, sem fundo)
    for (final ref in referenciasLoja) {
      final hit = project(Vec3(ref.x, 0.02, ref.z));
      if (hit == null) continue;
      final (screen, cz) = hit;
      final fontSize = 11.0 * (9.0 / cz).clamp(0.6, 1.5);
      final tp = TextPainter(
        text: TextSpan(
          text: ref.nome,
          style: TextStyle(
            color:         const Color(0x59FFFFFF), // branco 35%
            fontSize:      fontSize,
            fontWeight:    FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }

    // Números de face 1-6 ao redor da gôndola selecionada (mesma convenção
    // e culling da cena de detalhe, em discos menores)
    final selIdx = selecionadoIdx;
    if (selIdx != null &&
        selIdx < itensLoja.length &&
        itensLoja[selIdx].tipo == 'gondola') {
      final item = itensLoja[selIdx];
      const scale     = LojaGeometry.gondolaR / 3.4;
      const labelDist = (3.4 + 0.13 + 0.55) * scale;
      const labelY    = (0.675 + 0.15) * scale;

      for (var k = 1; k <= 6; k++) {
        final a      = faceAngle(k);
        final pos    = Vec3(item.x + labelDist * math.cos(a), labelY,
                            item.z + labelDist * math.sin(a));
        final normal = Vec3(math.cos(a), 0, math.sin(a));
        final dot    = normal.dot((eye - pos).normalized);
        if (dot <= 0.05) continue;
        final alpha = (dot * 2.2).clamp(0.0, 1.0);

        final hit = project(pos);
        if (hit == null) continue;
        final (screen, cz) = hit;

        final fontSize = 12.0 * (6.0 / cz).clamp(0.55, 1.4);
        final radius   = fontSize * 0.72;

        canvas.drawCircle(screen, radius,
            Paint()..color = const Color(0xFF12161c).withValues(alpha: 0.92 * alpha));
        canvas.drawCircle(screen, radius,
            Paint()
              ..color       = camda.withValues(alpha: alpha)
              ..style       = PaintingStyle.stroke
              ..strokeWidth = 1.5);

        final tp = TextPainter(
          text: TextSpan(
            text: '$k',
            style: TextStyle(
              color:      camda.withValues(alpha: alpha),
              fontSize:   fontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
      }
    }

    for (final item in itensLoja) {
      // Sem badges A–E nas EDR-300 (a 8 e a tripla da 6), nos expositores
      // (MagnoJet/Nellore/Monitor) nem na Estante Parede (os rótulos deles
      // são próprios e só fazem sentido na cena de detalhe).
      if (item.tipo != 'estante' ||
          ehEstanteEdr300(item.numero) ||
          item.numero == expositorMagnojetNum ||
          item.numero == expositorNelloreNum ||
          item.numero == expositorMonitorNum ||
          ehEstanteParede(item.numero)) {
        continue;
      }
      for (var i = 0; i < LojaGeometry._estanteNiveis; i++) {
        final y   = LojaGeometry._nivelY(i) + LojaGeometry._shelfT + 0.02;
        final hit = project(Vec3(item.x, y, item.z));
        if (hit == null) continue;

        final (screen, cz) = hit;
        final fontSize = 26.0 * (2.5 / cz).clamp(0.5, 1.4);
        final radius   = fontSize * 0.72;

        canvas.drawCircle(screen, radius, bgPaint);
        canvas.drawCircle(screen, radius, rimPaint);

        final letter = String.fromCharCode(65 + (LojaGeometry._estanteNiveis - 1 - i));
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

    // Badges do Modo Conferência (Fase 3): contador de pendentes por
    // estrutura, sempre visível (sem culling de ângulo), acima do topo dela.
    if (modoConferencia) {
      for (final entry in contagemConferencia.entries) {
        final idx = entry.key;
        if (idx < 0 || idx >= itensLoja.length) continue;
        final item = itensLoja[idx];
        final hit  = project(Vec3(item.x, 1.35, item.z));
        if (hit == null) continue;
        final (screen, cz) = hit;

        final prefixo = item.tipo == 'gondola' ? 'G' : 'E';
        final texto   = '$prefixo${item.numero} · ${entry.value}';
        final fontSize = 13.0 * (9.0 / cz).clamp(0.6, 1.4);

        final tp = TextPainter(
          text: TextSpan(
            text: texto,
            style: TextStyle(
              color:      const Color(0xFF04232a),
              fontSize:   fontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final padH  = fontSize * 0.5;
        final padV  = fontSize * 0.28;
        final rect  = Rect.fromCenter(
          center: screen,
          width:  tp.width + padH * 2,
          height: tp.height + padV * 2,
        );
        final rrect = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));

        canvas.drawRRect(rrect, Paint()..color = corConferenciaCiano.withValues(alpha: 0.94));
        canvas.drawRRect(rrect, Paint()
          ..color       = const Color(0xFF0b3a42)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 1.2);
        tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(LojaPainter old) =>
      old.camera.rotY         != camera.rotY         ||
      old.camera.rotX         != camera.rotX         ||
      old.camera.dist         != camera.dist         ||
      old.camera.target.x     != camera.target.x     ||
      old.camera.target.z     != camera.target.z     ||
      old.selecionadoIdx      != selecionadoIdx       ||
      old.modoConferencia     != modoConferencia      ||
      !mapEquals(old.contagemConferencia, contagemConferencia) ||
      (old.pulseT - pulseT).abs() > 0.001;
}

// ── LojaScene ─────────────────────────────────────────────────────────────────

class LojaScene extends StatefulWidget {
  final int?                       selecionadoIdx;
  final void Function(int? idx)    onSelecionado;
  final void Function(int idx)?    onVerDetalhes;
  final Vec3?                      focarEm;
  // Modo Conferência (Fase 3): quando ativo, um toque numa estrutura com
  // pendentes abre a cena dela direto (sem passar pela seleção normal de
  // duas etapas); contagemConferencia mapeia índice em itensLoja → nº de
  // produtos pendentes ali, usado tanto pro destaque quanto pro badge.
  final bool          modoConferencia;
  final Map<int, int> contagemConferencia;

  const LojaScene({
    super.key,
    this.selecionadoIdx,
    required this.onSelecionado,
    this.onVerDetalhes,
    this.focarEm,
    this.modoConferencia = false,
    this.contagemConferencia = const {},
  });

  @override
  State<LojaScene> createState() => _LojaSceneState();
}

class _LojaSceneState extends State<LojaScene>
    with TickerProviderStateMixin, SceneGestureGuard<LojaScene> {
  Camera _camera = Camera(
    rotY:   0.4,
    rotX:   0.85,
    dist:   17.0,
    target: Vec3(lojaW / 2, 0.2, lojaH / 2),
  );

  final _key = GlobalKey();
  Camera? _cam0;

  late final Ticker _ticker;
  double _pulseT = 0;

  Vec3?  _animFrom, _animTo, _lastFocarEm;
  double _animP = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    if (widget.focarEm != null) {
      _lastFocarEm = widget.focarEm;
      _animFrom    = _camera.target;
      _animTo      = widget.focarEm!;
      _animP       = 0;
    }
  }

  @override
  void didUpdateWidget(LojaScene old) {
    super.didUpdateWidget(old);
    final f = widget.focarEm;
    if (f != null) {
      final prev = _lastFocarEm;
      if (prev == null || prev.x != f.x || prev.y != f.y || prev.z != f.z) {
        _lastFocarEm = f;
        _animFrom    = _camera.target;
        _animTo      = f;
        _animP       = 0;
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    if (!mounted) return;
    bool dirty = false;

    if (widget.selecionadoIdx != null || widget.modoConferencia) {
      _pulseT += 0.04;
      dirty = true;
    }

    if (_animTo != null) {
      _animP = (_animP + 0.04).clamp(0.0, 1.0);
      final e   = 1 - math.pow(1 - _animP, 3).toDouble(); // ease-out cubic
      final frm = _animFrom!, to = _animTo!;
      _camera = Camera(
        rotY:   _camera.rotY,
        rotX:   _camera.rotX,
        dist:   _camera.dist,
        target: Vec3(
          frm.x + (to.x - frm.x) * e,
          frm.y + (to.y - frm.y) * e,
          frm.z + (to.z - frm.z) * e,
        ),
      );
      if (_animP >= 1.0) _animTo = null;
      dirty = true;
    }

    if (dirty) setState(() {});
  }

  // ── Gestures ──────────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    beginGesture(d);
    _cam0   = _camera;
    _animTo = null; // usuário assume o controle da câmera
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final origin = gestureOrigin;
    if (origin == null || _cam0 == null) return;

    if (reanchorIfPointersChanged(d)) {
      _cam0 = _camera;
      return;
    }
    markDragIfMoved(d);

    final delta = d.focalPoint - origin;

    if (d.pointerCount >= 2) {
      // Dois dedos: orbita (arrastar) + zoom (pinça)
      setState(() {
        _camera = Camera(
          rotY:   _cam0!.rotY - delta.dx * 0.006,
          rotX:   (_cam0!.rotX + delta.dy * 0.006).clamp(0.25, 1.45),
          dist:   (_cam0!.dist / d.scale).clamp(2.5, 28.0),
          target: _camera.target,
        );
      });
    } else {
      // Um dedo: pan — o ponto do chão acompanha o dedo
      final rb  = _key.currentContext?.findRenderObject() as RenderBox?;
      final hPx = rb?.size.height ?? 600.0;
      final worldPerPx = 2 * _cam0!.dist * math.tan(22.5 * math.pi / 180) / hPx;
      final tilt = math.max(math.sin(_cam0!.rotX), 0.35);

      final rotY = _cam0!.rotY;
      final dxW  = delta.dx * worldPerPx;
      final dyW  = delta.dy * worldPerPx / tilt;

      setState(() {
        _camera = Camera(
          rotY: _cam0!.rotY,
          rotX: _cam0!.rotX,
          dist: _cam0!.dist,
          target: Vec3(
            (_cam0!.target.x - math.cos(rotY) * dxW - math.sin(rotY) * dyW)
                .clamp(0.0, lojaW),
            _cam0!.target.y,
            (_cam0!.target.z + math.sin(rotY) * dxW - math.cos(rotY) * dyW)
                .clamp(0.0, lojaH),
          ),
        );
      });
    }
  }

  void _tryHitTest(Offset globalTap) {
    final rb = _key.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final idx = _hitTest(rb.globalToLocal(globalTap), rb.size);

    if (widget.modoConferencia) {
      // No Modo Conferência, um único toque numa estrutura com pendentes já
      // abre a cena dela — não há necessidade do fluxo normal de duas etapas.
      if (idx != null && widget.contagemConferencia.containsKey(idx)) {
        widget.onVerDetalhes?.call(idx);
      } else {
        widget.onSelecionado(idx);
      }
      return;
    }

    if (idx != null && idx == widget.selecionadoIdx) {
      widget.onVerDetalhes?.call(idx);
    } else {
      widget.onSelecionado(idx);
    }
  }

  int? _hitTest(Offset tap, Size size) {
    final eye    = _camera.position;
    final fwd    = (_camera.target - eye).normalized;
    final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up     = right.cross(fwd).normalized;
    const fovY   = 45.0 * math.pi / 180.0;
    final tanH   = math.tan(fovY / 2);
    final aspect = size.width / size.height;

    final ndcX = 2 * tap.dx / size.width  - 1;
    final ndcY = 1 - 2 * tap.dy / size.height;
    final dir  = (right * (ndcX * tanH * aspect) + up * (ndcY * tanH) + fwd).normalized;

    // Testa o raio contra a caixa 3D de cada item e devolve o mais próximo,
    // com uma folga para facilitar o toque em estantes finas.
    const margem        = 0.08;
    const gondolaAltura = 0.66;

    double bestT = double.infinity;
    int?   best;

    for (var i = 0; i < itensLoja.length; i++) {
      final item = itensLoja[i];
      final double hw, hd, h;
      if (item.tipo == 'gondola') {
        hw = LojaGeometry.gondolaR + margem;
        hd = LojaGeometry.gondolaR + margem;
        h  = gondolaAltura;
      } else {
        hw = item.w / 2 + margem;
        hd = item.d / 2 + margem;
        h  = LojaGeometry._estanteH;
      }
      final t = _rayBox(eye, dir,
          item.x - hw, item.x + hw, 0, h, item.z - hd, item.z + hd);
      if (t != null && t < bestT) {
        bestT = t;
        best  = i;
      }
    }
    return best;
  }

  // Interseção raio–AABB (método dos slabs); retorna a distância t ou null.
  double? _rayBox(Vec3 o, Vec3 d,
      double x0, double x1, double y0, double y1, double z0, double z1) {
    var tMin = 0.0, tMax = double.infinity;
    final oc = [o.x, o.y, o.z];
    final dc = [d.x, d.y, d.z];
    final lo = [x0, y0, z0];
    final hi = [x1, y1, z1];

    for (var i = 0; i < 3; i++) {
      if (dc[i].abs() < 1e-9) {
        if (oc[i] < lo[i] || oc[i] > hi[i]) return null;
      } else {
        var t1 = (lo[i] - oc[i]) / dc[i];
        var t2 = (hi[i] - oc[i]) / dc[i];
        if (t1 > t2) (t1, t2) = (t2, t1);
        if (t1 > tMin) tMin = t1;
        if (t2 < tMax) tMax = t2;
        if (tMin > tMax) return null;
      }
    }
    return tMin;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown:   aoEncostarDedo,
      onPointerUp:     (e) { if (aoSoltarDedo(e)) _tryHitTest(pontoDoToque!); },
      onPointerCancel: aoSoltarDedo,
      child: GestureDetector(
        onScaleStart:  _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        child: CustomPaint(
          key:     _key,
          painter: LojaPainter(
            _camera,
            selecionadoIdx:       widget.selecionadoIdx,
            pulseT:               _pulseT,
            modoConferencia:      widget.modoConferencia,
            contagemConferencia:  widget.contagemConferencia,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
