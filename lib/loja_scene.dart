import 'dart:math' as math;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:shared_preferences/shared_preferences.dart';
import 'balcao_scene.dart'
    show balcaoLoja, corBalcaoCorpo, corBalcaoTampo;
import 'boneco_loja.dart'
    show BonecoLoja, BonecoRenderer, PaletaBoneco, RotaBoneco;
import 'expositor_magnojet_scene.dart' show expositorMagnojetLoja;
import 'expositor_monitor_scene.dart' show expositorMonitorLoja;
import 'expositor_nellore_scene.dart' show expositorNelloreLoja;
import 'gondola_scene.dart'
    show Vec3, Camera, Face, ProjecaoCamera, faceAngle;
import 'models.dart'
    show balcaoNum, colunasEdr300Tripla, corConferenciaCiano, ehEstanteEdr300,
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

// Pontos de referência fixos da loja. Os do interior são escritos no piso
// claro (texto escuro); os das entradas ficam sobre o topo da parede escura —
// que é onde elas realmente estão — e por isso usam texto claro.
const List<({String nome, double x, double z, bool naParede})>
    referenciasLoja = [
  (nome: 'CAIXA',       x: 5.0, z:  0.80, naParede: false),
  (nome: 'BALCÃO LOJA', x: 0.9, z:  8.00, naParede: false),
  (nome: 'COZINHA',     x: 9.2, z:  8.00, naParede: false),
  (nome: 'ENTRADA',     x: 7.5, z: 13.91, naParede: true),
  (nome: 'ENTRADA 2',   x: 2.5, z: 13.91, naParede: true),
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
  // Balcão de Atendimento: peça comprida no corredor da parede esquerda, entre
  // a Estante Parede e a coluna de gôndolas 8–12. ENCOSTA na parede da entrada
  // (z = lojaH) e corre os 7,95 m dali para dentro — vai de z 5,87 a 13,82. O z
  // é derivado da parede em vez de escrito à mão para não reabrir fresta ali se
  // a espessura da parede mudar.
  ItemLoja(tipo: 'estante', numero: balcaoNum,
      x: 1.45, z: lojaH - LojaGeometry._paredeEsp - 7.95 / 2,
      w: 0.60, d: 7.95),
];

// ── Bonecos do mapa: altura e rotas ──────────────────────────────────────────

/// Altura do boneco = altura da gôndola, ajustável num lugar só: mudar
/// [LojaGeometry.gondolaR] reescala a gôndola e o boneco juntos.
const double alturaBoneco = LojaGeometry.alturaGondola;

/// Rotas de caminhada — dado, não código espalhado. Todas passam só pelos
/// corredores: os verticais x = 4, x = 6, x = 2.05 e x = 8.4 e os horizontais
/// z = 2.8 (antes da primeira fileira, em z = 4), z = 5 (entre as fileiras
/// z = 4 e z = 6) e z ≈ 13 (entre a última fileira, em z = 12, e a parede da
/// entrada).
///
/// As colunas de gôndolas ficam em x = 3, 5 e 7, com raio 0.62; as estantes de
/// parede em x ≤ 1.35 e x ≥ 9.1. O corredor da esquerda é o mais apertado dos
/// quatro: o Balcão de Atendimento ocupa x 1.15–1.75 ao longo de quase toda a
/// parede esquerda, então a perna de volta corre em x = 2.05 — o meio da folga
/// entre a borda do balcão (x 1.75) e a das gôndolas 8–12 (x 2.38).
final List<RotaBoneco> rotasLoja = [
  // Funcionário: sobe e desce o corredor central da loja, atravessando pela
  // faixa livre entre as fileiras z = 4 e z = 6.
  RotaBoneco(const [
    (x: 4.0, z: 5.00),
    (x: 4.0, z: 12.85),
    (x: 6.0, z: 12.85),
    (x: 6.0, z: 5.00),
  ]),
  // Cliente: volta grande pelas laterais, por fora das gôndolas.
  RotaBoneco(const [
    (x: 8.4,  z: 2.80),
    (x: 8.4,  z: 13.30),
    (x: 2.05, z: 13.30),
    (x: 2.05, z: 2.80),
  ]),
];

/// Preferência do mapa: quantos bonecos caminham pela cena. Guardada no mesmo
/// SharedPreferences das outras preferências do app.
///
/// [bonecos] espelha o valor salvo para que o mapa reaja na hora: quem escolhe
/// a quantidade é a tela de Configuração, que pode estar duas telas acima do
/// mapa na pilha de navegação — sem o notifier o mapa só veria a mudança ao ser
/// reconstruído do zero.
class PreferenciasMapa {
  static const String keyBonecos = 'mapa_bonecos';
  static const int    maxBonecos = 2;
  static const int    padraoBonecos = 1;

  /// Começa em 0 para o mapa abrir sem bonecos e só criá-los depois que a
  /// preferência salva chegar — evita o flash de um boneco surgindo e sumindo
  /// para quem os desligou.
  static final ValueNotifier<int> bonecos = ValueNotifier<int>(0);

  static Future<int> lerBonecos() async {
    final prefs = await SharedPreferences.getInstance();
    final n = (prefs.getInt(keyBonecos) ?? padraoBonecos).clamp(0, maxBonecos);
    bonecos.value = n;
    return n;
  }

  static Future<void> salvarBonecos(int quantidade) async {
    final n = quantidade.clamp(0, maxBonecos);
    bonecos.value = n;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyBonecos, n);
  }
}

/// Cria os bonecos do mapa: 1 = só o funcionário, 2 = funcionário + cliente.
List<BonecoLoja> criarBonecosLoja(int quantidade) => [
      for (var i = 0; i < quantidade.clamp(0, rotasLoja.length); i++)
        BonecoLoja(
          altura: alturaBoneco,
          rota:   rotasLoja[i],
          paleta: i == 0 ? PaletaBoneco.funcionario : PaletaBoneco.cliente,
          // O cliente anda um pouco mais devagar que o funcionário; o começo
          // deslocado evita os dois saírem do mesmo canto no mesmo passo.
          velocidade: alturaBoneco * (i == 0 ? 1.0 : 0.85),
          inicio:     rotasLoja[i].perimetro * (i * 0.37),
        ),
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
// Piso da loja: ladrilhos claros com rejunte discreto.
const Color _corPiso       = Color(0xFFedeff0);
const Color _corPisoRejunte = Color(0x14000000);

// ── LojaGeometry ──────────────────────────────────────────────────────────────

class LojaGeometry {
  static const double gondolaR      = 0.62;

  /// Silhueta da gôndola no mapa: (raio, y do centro, altura) de cada
  /// prateleira, na escala da cena de detalhe.
  static const List<(double, double, double)> gondolaPrateleiras = [
    (3.4, 0.675, 0.35),
    (2.4, 2.15,  0.30),
    (1.5, 3.43,  0.26),
  ];

  /// Fator que leva a gôndola da cena de detalhe para o tamanho do mapa.
  static const double gondolaEscala = gondolaR / 3.4;

  /// Altura total da gôndola no mapa: topo da prateleira mais alta de
  /// [gondolaPrateleiras] (indexar lista não é expressão constante em Dart,
  /// então os números aparecem aqui de novo — um teste garante que os dois
  /// continuem batendo). É daqui que sai a altura do boneco, então mudar
  /// [gondolaR] reescala a gôndola e o boneco juntos.
  static const double alturaGondola = (3.43 + 0.26 / 2) * gondolaEscala;

  static const double _estanteH     = 0.85;
  static const double _paredeH      = 0.90;
  static const double _paredeEsp    = 0.18;
  static const int    _estanteNiveis = 5;
  static const double _shelfT       = 0.013;

  /// Lado nominal do ladrilho do piso, em metros; o tamanho real é ajustado
  /// pra caber um número inteiro de ladrilhos entre as paredes.
  static const double _pisoLado = 1.0;

  static double _nivelY(int i) =>
      i * (_estanteH - _shelfT) / (_estanteNiveis - 1);

  /// Ladrilhos do piso (plano y = 0, dentro das paredes). Ficam numa lista à
  /// parte da das estruturas: a câmera está sempre acima do chão, então o piso
  /// é sempre a superfície mais ao fundo e pode ser desenhado antes de tudo,
  /// sem entrar no depth-sort — o que também evita z-fighting com as bases das
  /// gôndolas e estantes, que apoiam exatamente em y = 0.
  ///
  /// A geometria é fixa, então a lista é construída uma vez e reprojetada a
  /// cada paint.
  static final List<Face> piso = _buildPiso();

  static List<Face> _buildPiso() {
    const x0 = _paredeEsp, x1 = lojaW - _paredeEsp;
    const z0 = _paredeEsp, z1 = lojaH - _paredeEsp;
    final nx = math.max(1, ((x1 - x0) / _pisoLado).round());
    final nz = math.max(1, ((z1 - z0) / _pisoLado).round());
    final dx = (x1 - x0) / nx, dz = (z1 - z0) / nz;

    final faces = <Face>[];
    for (var i = 0; i < nx; i++) {
      final xa = x0 + i * dx, xb = xa + dx;
      for (var j = 0; j < nz; j++) {
        final za = z0 + j * dz, zb = za + dz;
        faces.add(Face([
          Vec3(xa, 0, za), Vec3(xa, 0, zb), Vec3(xb, 0, zb), Vec3(xb, 0, za),
        ], _corPiso));
      }
    }
    return faces;
  }

  static List<Face>? _cacheFaces;
  static (int?, double, bool, Map<int, int>)? _cacheChave;

  /// As faces do cenário são geometria fixa: só mudam quando muda a seleção, o
  /// pulso do destaque ou o Modo Conferência. Com os bonecos animando, o mapa
  /// repinta 60×/s — remontar a lista inteira a cada frame seria lixo puro
  /// para o GC, então o resultado fica memoizado. O painter só sobrescreve
  /// `proj`/`depth`/`light` de cada face, que são recalculados todo paint.
  static List<Face> buildFaces(
    int? selecionadoIdx,
    double pulseT, {
    bool modoConferencia = false,
    Map<int, int> contagemConferencia = const {},
  }) {
    final chave = (selecionadoIdx, pulseT, modoConferencia, contagemConferencia);
    final cache = _cacheFaces;
    if (cache != null && _cacheChave == chave) return cache;

    final idxConferencia = contagemConferencia.keys.toSet();
    final faces = <Face>[];
    // O pulso do destaque é o mesmo para todas as estruturas neste frame.
    final pulse = (0.35 + 0.25 * math.sin(pulseT * 2.2)).clamp(0.0, 1.0);

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

      // Destaque, apagado e Modo Conferência são a MESMA transformação para
      // qualquer cor base da estrutura. Escrita como função da base porque o
      // balcão tem duas (corpo verde e tampo de mármore) e as duas precisam
      // apagar e pulsar juntas — o resto das estruturas chama uma vez só.
      Color aplicar(Color base) {
        // Modo Conferência (Fase 3) substitui o esquema de seleção normal:
        // ciano pulsante nas estruturas com pendentes, apagado nas demais.
        if (modoConferencia) {
          if (!idxConferencia.contains(i)) return _corApagado;
          return Color.lerp(corConferenciaCiano, Colors.white, pulse * 0.3)!;
        }
        if (!hasSel) return base;
        if (!isSel)  return _corApagado;
        return Color.lerp(base, Colors.white, pulse * 0.35)!;
      }

      final cor = aplicar(item.tipo == 'gondola'
          ? corGondolaLoja
          : item.numero == balcaoNum
              ? corBalcaoCorpo
              : corEstanteLoja);

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
      } else if (item.numero == balcaoNum) {
        balcaoLoja(faces, item.x, item.z, item.w, item.d, cor,
            corTampo: aplicar(corBalcaoTampo));
      } else if (ehEstanteParede(item.numero)) {
        _estanteParede(faces, item, cor);
      } else {
        _estante(faces, item, cor);
      }
    }

    _cacheChave = chave;
    _cacheFaces = faces;
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
    const scale = gondolaEscala;
    for (final (r, yc, h) in gondolaPrateleiras) {
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
  // Bonecos caminhando pelo piso. O estado deles muda fora do painter (no
  // ticker da cena); é o `repaint:` do construtor que dispara o redesenho,
  // sem reconstruir a árvore de widgets.
  final List<BonecoLoja> bonecos;
  final BonecoRenderer?  bonecoRenderer;

  LojaPainter(
    this.camera, {
    this.selecionadoIdx,
    this.pulseT = 0,
    this.modoConferencia = false,
    this.contagemConferencia = const {},
    this.bonecos = const [],
    this.bonecoRenderer,
    Listenable? repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final proj = ProjecaoCamera(camera, size);

    canvas.drawRect(Offset.zero & size, Paint()..color = _corBg);
    final piso = LojaGeometry.piso;
    proj.projetarFaces(piso);
    _drawPiso(canvas, piso);

    // Sombras logo depois do piso e antes de qualquer objeto.
    final render = bonecoRenderer;
    if (render != null) {
      for (final b in bonecos) {
        render.desenharSombra(canvas, b, proj);
      }
    }

    final faces = LojaGeometry.buildFaces(
      selecionadoIdx,
      pulseT,
      modoConferencia: modoConferencia,
      contagemConferencia: contagemConferencia,
    );
    proj.projetarFaces(faces);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _draw(canvas, faces, proj);
    _drawLabels(canvas, proj);
  }

  // Piso: preenchimento chapado (sem sombreamento, pra manter o claro do
  // ladrilho) e o contorno de cada ladrilho, que é o próprio rejunte da grade.
  // Todos os ladrilhos entram num único Path — são dois draw calls no total,
  // e não uma centena.
  void _drawPiso(Canvas canvas, List<Face> piso) {
    final path = Path();
    for (final f in piso) {
      if (f.proj.length < 3) continue;
      path.moveTo(f.proj[0].dx, f.proj[0].dy);
      for (var i = 1; i < f.proj.length; i++) {
        path.lineTo(f.proj[i].dx, f.proj[i].dy);
      }
      path.close();
    }
    canvas.drawPath(path, Paint()..color = _corPiso);
    canvas.drawPath(path, Paint()
      ..color       = _corPisoRejunte
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 0.8);
  }

  // Fila de profundidade: as faces do cenário já vêm ordenadas do mais longe
  // para o mais perto, e cada boneco entra nessa fila como UM objeto só, pelo
  // centroide na cintura. Ordenar as peças dele soltas o faria atravessar
  // gôndola; as faces internas do boneco são ordenadas entre si lá dentro.
  void _draw(Canvas canvas, List<Face> faces, ProjecaoCamera proj) {
    final fill   = Paint();
    final stroke = Paint()
      ..color       = const Color(0x44000000)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    final render = bonecoRenderer;
    // Profundidade de cada boneco: calculada uma vez por paint, do mais longe
    // para o mais perto (mesma ordem das faces).
    final pendente = render == null
        ? const <BonecoLoja>[]
        : (bonecos.toList()..sort((a, b) =>
            render.profundidade(b, proj).compareTo(render.profundidade(a, proj))));
    final profBoneco = [
      for (final b in pendente) render!.profundidade(b, proj),
    ];
    var proximo = 0;

    for (final f in faces) {
      if (f.proj.isEmpty) continue;
      while (proximo < pendente.length && profBoneco[proximo] > f.depth) {
        render!.desenhar(canvas, pendente[proximo], proj);
        proximo++;
      }
      final path = Path()..moveTo(f.proj[0].dx, f.proj[0].dy);
      for (var i = 1; i < f.proj.length; i++) {
        path.lineTo(f.proj[i].dx, f.proj[i].dy);
      }
      path.close();
      fill.color = Color.lerp(Colors.black, f.color, f.light)!;
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }

    while (proximo < pendente.length) {
      render!.desenhar(canvas, pendente[proximo], proj);
      proximo++;
    }
  }

  void _drawLabels(Canvas canvas, ProjecaoCamera proj) {
    final eye = proj.eye;
    (Offset, double)? project(Vec3 v) => proj.projetar(v);

    const camda   = Color(0xFFe87722);
    const bgColor = Color(0xC70b0c0e);

    final bgPaint  = Paint()..color = bgColor;
    final rimPaint = Paint()
      ..color       = camda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Rótulos de referência (discretos, sem fundo): escuros sobre o piso
    // claro, claros sobre o topo escuro da parede das entradas.
    for (final ref in referenciasLoja) {
      final y   = ref.naParede ? LojaGeometry._paredeH + 0.02 : 0.02;
      final hit = project(Vec3(ref.x, y, ref.z));
      if (hit == null) continue;
      final (screen, cz) = hit;
      final fontSize = 11.0 * (9.0 / cz).clamp(0.6, 1.5);
      final tp = TextPainter(
        text: TextSpan(
          text: ref.nome,
          style: TextStyle(
            color: ref.naParede
                ? const Color(0x59FFFFFF)  // branco 35% sobre a parede
                : const Color(0x8C15181c), // grafite 55% sobre o piso
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
      // são próprios e só fazem sentido na cena de detalhe). O balcão fica
      // fora por outro motivo: ele não tem nível nenhum.
      if (item.tipo != 'estante' ||
          ehEstanteEdr300(item.numero) ||
          item.numero == expositorMagnojetNum ||
          item.numero == expositorNelloreNum ||
          item.numero == expositorMonitorNum ||
          item.numero == balcaoNum ||
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
      old.bonecos.length      != bonecos.length      ||
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
  /// Quantos bonecos caminham pelo mapa: 0 (desligado), 1 ou 2.
  final int           bonecos;

  const LojaScene({
    super.key,
    this.selecionadoIdx,
    required this.onSelecionado,
    this.onVerDetalhes,
    this.focarEm,
    this.modoConferencia = false,
    this.contagemConferencia = const {},
    this.bonecos = 0,
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

  // Bonecos: o estado deles muda a cada frame e o painter escuta _repaint —
  // assim só a pintura acontece, sem reconstruir a árvore de widgets.
  final ValueNotifier<double> _repaint = ValueNotifier<double>(0);
  final BonecoRenderer        _bonecoRenderer = BonecoRenderer();
  List<BonecoLoja>            _bonecos = const [];
  Duration                    _ultimoTick = Duration.zero;

  // O mapa era estático e só redesenhava no toque; com os bonecos ele repinta
  // pra sempre, então o ticker precisa parar quando ninguém está vendo.
  // Background: AppLifecycleListener. Tela do mapa fora de foco (outra rota
  // por cima): o TickerMode do próprio TickerProviderStateMixin já silencia.
  late final AppLifecycleListener _lifecycle;
  bool _emPrimeiroPlano = true;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _sincronizarBonecos();
    if (widget.focarEm != null) {
      _lastFocarEm = widget.focarEm;
      _animFrom    = _camera.target;
      _animTo      = widget.focarEm!;
      _animP       = 0;
    }
    _avaliarTicker();
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
    if (old.bonecos != widget.bonecos) _sincronizarBonecos();
    _avaliarTicker();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _sincronizarBonecos() {
    _bonecos = criarBonecosLoja(widget.bonecos);
  }

  void _onLifecycle(AppLifecycleState estado) {
    _emPrimeiroPlano = estado == AppLifecycleState.resumed;
    _avaliarTicker();
  }

  /// O ticker só roda quando há algo se movendo E o app está em primeiro
  /// plano.
  void _avaliarTicker() {
    final precisa = _emPrimeiroPlano &&
        (_bonecos.isNotEmpty ||
         _animTo != null ||
         widget.selecionadoIdx != null ||
         widget.modoConferencia);
    if (precisa && !_ticker.isActive) {
      _ultimoTick = Duration.zero; // start() zera o elapsed
      _ticker.start();
    } else if (!precisa && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    bool dirty = false;

    // dt real, limitado: depois de uma pausa longa o boneco continua de onde
    // parou em vez de teleportar.
    final dt = ((elapsed - _ultimoTick).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _ultimoTick = elapsed;

    if (_bonecos.isNotEmpty) {
      for (final b in _bonecos) {
        b.avancar(dt);
      }
      // Repinta sem setState: a árvore de widgets fica parada.
      _repaint.value = elapsed.inMicroseconds / 1e6;
    }

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

    if (dirty) {
      setState(() {});
    } else if (_bonecos.isEmpty) {
      // Nada mais se mexendo (a animação de foco acabou ou o gesto assumiu a
      // câmera): o mapa volta a ser estático e o ticker para.
      _avaliarTicker();
    }
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
      // O balcão é a única estrutura do mapa sem cena de detalhe: ele não tem
      // níveis nem endereços, e um toque duplo nele cairia no `else` de
      // _abrirEstrutura, abrindo uma EstantePage para a "estante 21" — uma
      // cena genérica vazia, com o carrossel parado num número que não existe
      // em ordemNavegacaoEstantes. Enquanto não houver cena própria, ele entra
      // no mapa como peça puramente visual e não é selecionável; o raio passa
      // reto e acerta o que estiver atrás.
      if (item.numero == balcaoNum) continue;
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
            bonecos:              _bonecos,
            bonecoRenderer:       _bonecoRenderer,
            repaint:              _repaint,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
