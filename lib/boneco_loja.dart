import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show VertexMode, Vertices;

import 'package:flutter/material.dart';

import 'gondola_scene.dart' show ProjecaoCamera, sombrearNormal;

// ──────────────────────────────────────────────────────────────────────────────
// Boneco low-poly que caminha pelo piso da loja
// ──────────────────────────────────────────────────────────────────────────────
//
// O boneco é só um monte de caixas alinhadas montadas num espaço local com a
// origem nos pés, +Y para cima e o boneco olhando para +Z. Todas as medidas das
// peças são FRAÇÕES da altura total, para a proporção sobreviver a qualquer
// mudança de escala da loja: quem cria o boneco passa só a altura em unidades
// de mundo (ver `alturaBoneco` em loja_scene.dart, derivada da altura da
// gôndola).
//
// A renderização não usa a fila de faces do cenário: cada boneco vira uma
// única chamada de drawVertices com cor por vértice, escrita em buffers
// pré-alocados (ver [BonecoRenderer]).

/// Cores de um boneco. As duas variantes fixas são o funcionário (colete
/// laranja da marca) e o cliente (camisa azul).
class PaletaBoneco {
  final int camisa, calca, pele, sapato, bone; // ARGB

  const PaletaBoneco({
    required this.camisa,
    required this.calca,
    required this.pele,
    required this.sapato,
    required this.bone,
  });

  static const funcionario = PaletaBoneco(
    camisa: 0xFFe87722,
    calca:  0xFF2f3846,
    pele:   0xFFc98d63,
    sapato: 0xFF1a1d21,
    bone:   0xFF20242b,
  );

  static const cliente = PaletaBoneco(
    camisa: 0xFF4a76b8,
    calca:  0xFF2f3846,
    pele:   0xFFa9714b,
    sapato: 0xFF1a1d21,
    bone:   0xFF37424f,
  );

  int cor(int slot) => switch (slot) {
        _corCamisa => camisa,
        _corCalca  => calca,
        _corPele   => pele,
        _corSapato => sapato,
        _          => bone,
      };
}

const int _corCamisa = 0;
const int _corCalca  = 1;
const int _corPele   = 2;
const int _corSapato = 3;
const int _corBone   = 4;

/// Uma caixa do boneco no espaço local, em frações da altura total.
///
/// Braços e pernas giram em X em torno do pivô no TOPO da peça (quadril /
/// ombro); o giro acontece antes do deslocamento lateral e do yaw do boneco.
class _Peca {
  /// Meia-largura (X) e meia-profundidade (Z).
  final double hw, hd;

  /// Base e topo da caixa, antes do giro.
  final double y0, y1;

  /// Deslocamento lateral (X, aplicado depois do giro) e frente/trás (Z,
  /// aplicado junto com a caixa, antes do giro).
  final double dx, dz;

  /// Y do pivô do giro. Só importa quando [giro] != 0.
  final double pivoY;

  /// Multiplicador do passo: ±1 nas pernas/pés, ∓0.8 nos braços, 0 no resto.
  final double giro;

  final int cor;

  const _Peca({
    required this.hw,
    required this.hd,
    required this.y0,
    required this.y1,
    required this.cor,
    this.dx = 0,
    this.dz = 0,
    this.pivoY = 0,
    this.giro = 0,
  });
}

/// Topo do boneco em frações: o boné vai até 0.983, então a escala interna é
/// `altura / _fracTopo` — assim o ponto mais alto do boneco fica EXATAMENTE na
/// altura pedida (a da gôndola), sem mudar nenhuma proporção da tabela.
const double _fracTopo = 0.983;

/// Afastamento lateral do centro das pernas e dos braços, em frações.
const double _dxPerna = 0.055;
const double _dxBraco = 0.145;

const List<_Peca> _pecas = [
  // Pernas (pivô no quadril) e pés, que continuam a perna e avançam à frente.
  _Peca(hw: 0.0495, hd: 0.0550, y0: 0.035, y1: 0.465,
        dx:  _dxPerna, pivoY: 0.465, giro:  1, cor: _corCalca),
  _Peca(hw: 0.0495, hd: 0.0550, y0: 0.035, y1: 0.465,
        dx: -_dxPerna, pivoY: 0.465, giro: -1, cor: _corCalca),
  _Peca(hw: 0.0550, hd: 0.0755, y0: 0.000, y1: 0.035, dz: 0.035,
        dx:  _dxPerna, pivoY: 0.465, giro:  1, cor: _corSapato),
  _Peca(hw: 0.0550, hd: 0.0755, y0: 0.000, y1: 0.035, dz: 0.035,
        dx: -_dxPerna, pivoY: 0.465, giro: -1, cor: _corSapato),
  // Braços (pivô no ombro): o antebraço continua o braço no mesmo giro, então
  // o conjunto se comporta como um braço rígido balançando no ombro.
  _Peca(hw: 0.0350, hd: 0.0380, y0: 0.430, y1: 0.767,
        dx:  _dxBraco, pivoY: 0.767, giro: -0.8, cor: _corCamisa),
  _Peca(hw: 0.0350, hd: 0.0380, y0: 0.430, y1: 0.767,
        dx: -_dxBraco, pivoY: 0.767, giro:  0.8, cor: _corCamisa),
  _Peca(hw: 0.0380, hd: 0.0405, y0: 0.349, y1: 0.430,
        dx:  _dxBraco, pivoY: 0.767, giro: -0.8, cor: _corPele),
  _Peca(hw: 0.0380, hd: 0.0405, y0: 0.349, y1: 0.430,
        dx: -_dxBraco, pivoY: 0.767, giro:  0.8, cor: _corPele),
  // Tronco, pescoço, cabeça e boné.
  _Peca(hw: 0.1165, hd: 0.0700, y0: 0.465, y1: 0.791, cor: _corCamisa),
  _Peca(hw: 0.0435, hd: 0.0495, y0: 0.791, y1: 0.814, cor: _corPele),
  _Peca(hw: 0.0700, hd: 0.0670, y0: 0.814, y1: 0.953, cor: _corPele),
  _Peca(hw: 0.0785, hd: 0.0755, y0: 0.942, y1: _fracTopo, cor: _corBone),
];

/// Extremos verticais do boneco em unidades de mundo, na pose parada.
///
/// A invariante que interessa: `topo == altura`. É ela que amarra o boneco à
/// altura da gôndola — o balanço do corpo só desce (ver [BonecoLoja.elevacao]),
/// então o topo do boné é sempre o ponto mais alto.
({double base, double topo}) extremosBoneco(double altura) {
  var y0 = double.infinity, y1 = -double.infinity;
  for (final p in _pecas) {
    if (p.y0 < y0) y0 = p.y0;
    if (p.y1 > y1) y1 = p.y1;
  }
  final esc = altura / _fracTopo;
  return (base: y0 * esc, topo: y1 * esc);
}

/// Meia-largura do boneco em unidades de mundo (a peça mais afastada do eixo),
/// usada para conferir a folga das rotas nos corredores.
double meiaLarguraBoneco(double altura) {
  var m = 0.0;
  for (final p in _pecas) {
    final lx = p.dx.abs() + p.hw;
    final lz = p.dz.abs() + p.hd;
    if (lx > m) m = lx;
    if (lz > m) m = lz;
  }
  return m * (altura / _fracTopo);
}

/// Vértices de cada face da caixa, no índice de bits (ix<<2)|(iy<<1)|iz.
/// A ordem segue a mesma convenção do resto do renderer: o produto vetorial
/// (v1-v0)×(v2-v0) aponta para FORA da caixa.
const List<int> _facesCaixa = [
  2, 3, 7, 6, // topo    (+Y)
  0, 4, 5, 1, // base    (−Y)
  1, 5, 7, 3, // frente  (+Z)
  4, 0, 2, 6, // fundo   (−Z)
  5, 4, 6, 7, // direita (+X)
  0, 1, 3, 2, // esquerda(−X)
];

// ── Rota ──────────────────────────────────────────────────────────────────────

/// Rota fechada de caminhada: uma lista de waypoints no piso com o
/// comprimento de cada segmento pré-calculado. A posição e a direção do
/// boneco saem de um único `double s` (distância percorrida).
class RotaBoneco {
  final List<double> xs;
  final List<double> zs;
  final List<double> comprimentos;
  final double perimetro;

  RotaBoneco._(this.xs, this.zs, this.comprimentos, this.perimetro);

  factory RotaBoneco(List<({double x, double z})> pontos) {
    assert(pontos.length >= 2, 'uma rota precisa de pelo menos 2 waypoints');
    final xs = <double>[for (final p in pontos) p.x];
    final zs = <double>[for (final p in pontos) p.z];
    final comprimentos = <double>[];
    var total = 0.0;
    for (var i = 0; i < pontos.length; i++) {
      final j  = (i + 1) % pontos.length;
      final dx = xs[j] - xs[i], dz = zs[j] - zs[i];
      final c  = math.sqrt(dx * dx + dz * dz);
      comprimentos.add(c);
      total += c;
    }
    return RotaBoneco._(xs, zs, comprimentos, total);
  }

  int get n => xs.length;

  /// Ponto e direção (unitária) na distância [s] ao longo da rota.
  ({double x, double z, double dx, double dz}) em(double s) {
    var resto = s % perimetro;
    for (var i = 0; i < n; i++) {
      final c = comprimentos[i];
      if (resto <= c || i == n - 1) {
        final j = (i + 1) % n;
        final t = c < 1e-9 ? 0.0 : resto / c;
        final dx = (xs[j] - xs[i]) / (c < 1e-9 ? 1.0 : c);
        final dz = (zs[j] - zs[i]) / (c < 1e-9 ? 1.0 : c);
        return (
          x:  xs[i] + (xs[j] - xs[i]) * t,
          z:  zs[i] + (zs[j] - zs[i]) * t,
          dx: dx,
          dz: dz,
        );
      }
      resto -= c;
    }
    return (x: xs[0], z: zs[0], dx: 0, dz: 1);
  }
}

// ── Estado do boneco ─────────────────────────────────────────────────────────

/// Um boneco caminhando: todo o estado é a distância percorrida `s` (mais o
/// yaw, que persegue a direção da rota para a curva no waypoint não sair um
/// giro brusco).
class BonecoLoja {
  /// Altura total, do pé ao topo do boné, em unidades de mundo.
  final double altura;
  final RotaBoneco rota;
  final PaletaBoneco paleta;

  /// Unidades de mundo por segundo.
  final double velocidade;

  double s;
  double x = 0, z = 0, yaw = 0;

  /// Fase da passada por unidade de DISTÂNCIA (não de tempo): mudar a
  /// velocidade acelera a passada junto, em vez de fazer o boneco patinar.
  /// Um ciclo (2π) = dois passos ≈ 0.9 × altura de deslocamento.
  late final double _kFase = 2 * math.pi / (0.9 * altura);

  BonecoLoja({
    required this.altura,
    required this.rota,
    required this.paleta,
    double? velocidade,
    double inicio = 0,
  })  : velocidade = velocidade ?? altura,
        s = inicio {
    final p = rota.em(s);
    x   = p.x;
    z   = p.z;
    yaw = math.atan2(p.dx, p.dz);
  }

  double get fase  => s * _kFase;
  double get passo => math.sin(fase) * 0.58;

  /// Sobe/desce do corpo: o quadril está no ponto mais alto quando as pernas
  /// se cruzam (passo = 0) e desce quando elas abrem — por isso o offset é
  /// negativo, o que também mantém o topo do boné exatamente na altura pedida.
  double get elevacao => -math.sin(fase).abs() * 0.02 * altura;

  void avancar(double dt) {
    s = (s + velocidade * dt) % rota.perimetro;
    final p = rota.em(s);
    x = p.x;
    z = p.z;

    // Yaw perseguindo a direção do segmento, com wrap em ±π para a curva no
    // waypoint não dar um giro brusco pelo lado longo. O % do Dart com módulo
    // positivo já devolve [0, 2π), então basta dobrar a metade de cima.
    final alvo = math.atan2(p.dx, p.dz);
    var delta  = (alvo - yaw) % (2 * math.pi);
    if (delta > math.pi) delta -= 2 * math.pi;
    yaw += delta * (1 - math.exp(-dt * 6));
  }
}

// ── Renderer ─────────────────────────────────────────────────────────────────

/// Desenha os bonecos com buffers pré-alocados: cada boneco sai numa única
/// chamada de `drawVertices`, com cor por vértice (o que também elimina a
/// costura branca do antialias entre faces vizinhas).
///
/// Criado uma vez (no `initState` da cena) e reaproveitado por todos os
/// bonecos e todos os frames — nada é alocado por vértice dentro do loop, que
/// é o que engasgaria o 60fps.
class BonecoRenderer {
  static const int _nPecas   = 12;
  static const int _nVerts   = _nPecas * 8;
  static const int _maxFaces = _nPecas * 6;
  static const int _maxVerts = _maxFaces * 6; // 2 triângulos (6 vértices) por face

  // Vértices no mundo + o resultado da projeção deles.
  final Float64List _wx   = Float64List(_nVerts);
  final Float64List _wy   = Float64List(_nVerts);
  final Float64List _wz   = Float64List(_nVerts);
  final Float32List _tela = Float32List(_nVerts * 2);
  final Float64List _prof = Float64List(_nVerts);

  // Faces visíveis, ordenadas entre si por profundidade.
  final Int32List   _face     = Int32List(_maxFaces);
  final Float64List _faceProf = Float64List(_maxFaces);
  final Int32List   _faceCor  = Int32List(_maxFaces);

  // Malha final entregue ao canvas.
  final Float32List _pos   = Float32List(_maxVerts * 2);
  final Int32List   _cores = Int32List(_maxVerts);

  // Sombra: polígono achatado de 12 lados, reaproveitado a cada frame.
  static const int _ladosSombra = 12;
  final Float32List _telaSombra = Float32List(_ladosSombra * 2);
  final Path  _pathSombra  = Path();
  final Paint _paintSombra = Paint()..color = const Color(0x33141a14);

  final Paint _paint = Paint();

  BonecoRenderer() {
    assert(_pecas.length == _nPecas);
  }

  /// Profundidade do boneco na fila do painter: um centroide único na cintura,
  /// para o boneco entrar na ordenação como UM objeto só. Ordenar cada peça
  /// solta faria ele atravessar gôndola.
  double profundidade(BonecoLoja b, ProjecaoCamera p) {
    final dx = b.x - p.eye.x;
    final dy = b.altura * 0.5 + b.elevacao - p.eye.y;
    final dz = b.z - p.eye.z;
    return dx * p.fwd.x + dy * p.fwd.y + dz * p.fwd.z;
  }

  /// Sombra no chão — desenhada logo depois do piso e antes de qualquer
  /// objeto. É o que vende a impressão de "pisando no chão". O tamanho é dado
  /// em unidades de MUNDO (0.34 × 0.26), não em frações da altura.
  void desenharSombra(Canvas canvas, BonecoLoja b, ProjecaoCamera proj) {
    const rx = 0.34 / 2;
    const rz = 0.26 / 2;
    final cy = math.cos(b.yaw), sy = math.sin(b.yaw);

    for (var i = 0; i < _ladosSombra; i++) {
      final a  = i * 2 * math.pi / _ladosSombra;
      final lx = rx * math.cos(a);
      final lz = rz * math.sin(a);
      final wx = b.x + lx * cy + lz * sy;
      final wz = b.z - lx * sy + lz * cy;
      if (proj.projetarEm(wx, 0.01, wz, _telaSombra, i) <= ProjecaoCamera.near) {
        return;
      }
    }

    _pathSombra.reset();
    _pathSombra.moveTo(_telaSombra[0], _telaSombra[1]);
    for (var i = 1; i < _ladosSombra; i++) {
      _pathSombra.lineTo(_telaSombra[i * 2], _telaSombra[i * 2 + 1]);
    }
    _pathSombra.close();
    canvas.drawPath(_pathSombra, _paintSombra);
  }

  void desenhar(Canvas canvas, BonecoLoja b, ProjecaoCamera proj) {
    final nFaces = _montar(b, proj);
    if (nFaces == 0) return;

    final nVerts = nFaces * 6;
    final vertices = Vertices.raw(
      VertexMode.triangles,
      Float32List.view(_pos.buffer, 0, nVerts * 2),
      colors: Int32List.view(_cores.buffer, 0, nVerts),
    );
    // BlendMode.dst ignora a cor do Paint e usa só as cores dos vértices.
    canvas.drawVertices(vertices, BlendMode.dst, _paint);
    // Libera a memória nativa na hora, em vez de esperar o GC — é o que
    // mantém o heap estável com a cena repintando para sempre.
    vertices.dispose();
  }

  /// Monta a malha do boneco nos buffers e devolve o número de faces visíveis.
  int _montar(BonecoLoja b, ProjecaoCamera proj) {
    final esc   = b.altura / _fracTopo;
    final passo = b.passo;
    final baseY = b.elevacao;
    final cy    = math.cos(b.yaw), sy = math.sin(b.yaw);

    for (var p = 0; p < _nPecas; p++) {
      final peca = _pecas[p];
      final ang  = peca.giro * passo;
      final ca   = math.cos(ang), sa = math.sin(ang);
      final pivo = peca.pivoY * esc;
      final offX = peca.dx * esc;
      final offZ = peca.dz * esc;

      for (var k = 0; k < 8; k++) {
        final lx = ((k & 4) != 0 ? peca.hw : -peca.hw) * esc;
        final ly = ((k & 2) != 0 ? peca.y1 : peca.y0) * esc - pivo;
        final lz = ((k & 1) != 0 ? peca.hd : -peca.hd) * esc + offZ;

        // Giro em X em torno do pivô no topo da peça…
        final ry = ang == 0 ? ly : ly * ca - lz * sa;
        final rz = ang == 0 ? lz : ly * sa + lz * ca;
        // …depois o offset lateral e o yaw do boneco.
        final ox = lx + offX;
        final oy = ry + pivo;

        final i = p * 8 + k;
        _wx[i] = b.x + ox * cy + rz * sy;
        _wy[i] = baseY + oy;
        _wz[i] = b.z - ox * sy + rz * cy;
        _prof[i] = proj.projetarEm(_wx[i], _wy[i], _wz[i], _tela, i);
        // Boneco cruzando o near plane: some inteiro em vez de explodir na
        // tela. Na prática a câmera do mapa nunca chega tão perto.
        if (_prof[i] <= ProjecaoCamera.near) return 0;
      }
    }

    var nf = 0;
    for (var p = 0; p < _nPecas; p++) {
      final cor  = b.paleta.cor(_pecas[p].cor);
      final base = p * 8;
      for (var f = 0; f < 6; f++) {
        final i0 = base + _facesCaixa[f * 4];
        final i1 = base + _facesCaixa[f * 4 + 1];
        final i2 = base + _facesCaixa[f * 4 + 2];
        final i3 = base + _facesCaixa[f * 4 + 3];

        final ax = _wx[i1] - _wx[i0], ay = _wy[i1] - _wy[i0], az = _wz[i1] - _wz[i0];
        final bx = _wx[i2] - _wx[i0], by = _wy[i2] - _wy[i0], bz = _wz[i2] - _wz[i0];
        final nx = ay * bz - az * by;
        final ny = az * bx - ax * bz;
        final nz = ax * by - ay * bx;

        // Cada peça é uma caixa convexa e opaca: descartar as faces de trás é
        // exato e corta metade dos triângulos.
        final vista = nx * (proj.eye.x - _wx[i0]) +
                      ny * (proj.eye.y - _wy[i0]) +
                      nz * (proj.eye.z - _wz[i0]);
        if (vista <= 0) continue;

        _face[nf]     = p * 6 + f;
        _faceProf[nf] = (_prof[i0] + _prof[i1] + _prof[i2] + _prof[i3]) / 4;
        _faceCor[nf]  = _tingir(cor, sombrearNormal(nx, ny, nz));
        nf++;
      }
    }

    _ordenarFaces(nf);

    var v = 0;
    for (var i = 0; i < nf; i++) {
      final cor  = _faceCor[i];
      final f    = _face[i];
      final base = (f ~/ 6) * 8;
      final lado = (f % 6) * 4;
      final i0 = base + _facesCaixa[lado];
      final i1 = base + _facesCaixa[lado + 1];
      final i2 = base + _facesCaixa[lado + 2];
      final i3 = base + _facesCaixa[lado + 3];
      v = _emitir(v, i0, i1, i2, cor);
      v = _emitir(v, i0, i2, i3, cor);
    }
    return nf;
  }

  /// Ordem do pintor entre as faces do próprio boneco: mais longe primeiro.
  /// Insertion sort direto nos arrays paralelos — sem alocar comparador nem
  /// lista temporária, e com poucas dezenas de faces é o mais rápido.
  void _ordenarFaces(int n) {
    for (var i = 1; i < n; i++) {
      final f = _face[i], c = _faceCor[i];
      final d = _faceProf[i];
      var j = i - 1;
      while (j >= 0 && _faceProf[j] < d) {
        _face[j + 1]     = _face[j];
        _faceProf[j + 1] = _faceProf[j];
        _faceCor[j + 1]  = _faceCor[j];
        j--;
      }
      _face[j + 1]     = f;
      _faceProf[j + 1] = d;
      _faceCor[j + 1]  = c;
    }
  }

  int _emitir(int v, int a, int b, int c, int cor) {
    _pos[v * 2]     = _tela[a * 2];
    _pos[v * 2 + 1] = _tela[a * 2 + 1];
    _cores[v]       = cor;
    v++;
    _pos[v * 2]     = _tela[b * 2];
    _pos[v * 2 + 1] = _tela[b * 2 + 1];
    _cores[v]       = cor;
    v++;
    _pos[v * 2]     = _tela[c * 2];
    _pos[v * 2 + 1] = _tela[c * 2 + 1];
    _cores[v]       = cor;
    return v + 1;
  }

  static int _tingir(int cor, double luz) {
    final r = (((cor >> 16) & 0xFF) * luz).round();
    final g = (((cor >> 8) & 0xFF) * luz).round();
    final b = ((cor & 0xFF) * luz).round();
    return 0xFF000000 | (r << 16) | (g << 8) | b;
  }
}
