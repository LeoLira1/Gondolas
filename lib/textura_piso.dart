import 'dart:typed_data' show Float64List;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'gondola_scene.dart' show ProjecaoCamera;

// ─────────────────────────────────────────────────────────────────────────────
// Textura de concreto do piso das cenas 3D
// ─────────────────────────────────────────────────────────────────────────────
//
// O piso das cenas é um PLANO (y = 0), e um plano projetado por uma câmera em
// perspectiva se transforma na tela por uma HOMOGRAFIA — uma matriz 3×3, exata,
// sem aproximação. Isto é o que este arquivo faz: monta essa matriz a partir da
// mesma [ProjecaoCamera] que desenha todo o resto e a instala no canvas, para
// então desenhar a textura em COORDENADAS DE MUNDO.
//
// A consequência é a que interessa: a textura pertence ao chão. Ela acompanha
// zoom, pan e rotação sozinha, porque quem a deforma é a câmera da cena, e não
// um ajuste paralelo que possa divergir dela. Não é um fundo 2D atrás do
// CustomPaint — girar a câmera com um fundo 2D deixaria o concreto parado
// enquanto o galpão gira.
//
// Custo por frame: uma matriz (16 doubles), o recorte do retângulo do piso
// contra o near plane (no máximo 5 vértices) e UM drawPath. A imagem é
// decodificada uma vez em [TexturaPiso.carregar] e o `ImageShader` que a
// ladrilha é memoizado — nada disso reentra no paint.

/// A textura de concreto, decodificada uma única vez para o app inteiro.
///
/// Nasce nula e vira uma [ui.Image] quando o asset termina de carregar; quem
/// desenha usa a cor de piso de sempre enquanto isso (ver [pintarPisoTexturado]).
/// É um [ValueListenable] para a cena repintar sozinha na chegada da imagem,
/// sem `setState` espalhado por página.
abstract final class TexturaPiso {
  static const String asset = 'assets/textures/galpao_concreto.png';

  static final ValueNotifier<ui.Image?> imagem = ValueNotifier<ui.Image?>(null);

  static Future<void>? _emAndamento;

  /// Carrega e decodifica a textura. Idempotente: chamadas seguintes (de outra
  /// cena, de outro `initState`) devolvem o mesmo Future e NÃO redecodificam.
  static Future<void> carregar() =>
      _emAndamento ??= _carregar().catchError((Object _) {
        // Asset ausente ou bundle sem ele (é o caso de alguns testes): a cena
        // continua com a cor chapada de piso. Zerar o guarda deixa uma próxima
        // tentativa possível, mas nada aqui é fatal para o mapa.
        _emAndamento = null;
      });

  static Future<void> _carregar() async {
    final dados = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(dados.buffer.asUint8List());
    final quadro = await codec.getNextFrame();
    imagem.value = quadro.image;
  }

  /// Shader ladrilhado memoizado por (imagem, lado do ladrilho).
  ///
  /// Um `ImageShader` novo por frame não redecodifica nada, mas aloca um objeto
  /// nativo a cada paint — e o shader aqui não depende da câmera (quem depende
  /// dela é a matriz do canvas), então ele é sempre o mesmo objeto.
  static ui.Image? _shaderImagem;
  static double? _shaderLado;
  static ui.ImageShader? _shader;

  /// Quantos `ImageShader` já foram construídos. Existe para o teste provar que
  /// pintar a cena N vezes não constrói N shaders — é a diferença entre um
  /// custo de abertura de tela e um custo por frame de arrasto.
  @visibleForTesting
  static int shadersCriados = 0;

  static ui.ImageShader _shaderDe(ui.Image img, double ladoMundo) {
    if (identical(_shaderImagem, img) && _shaderLado == ladoMundo) {
      return _shader!;
    }
    // A matriz do shader leva PIXEL DA IMAGEM → UNIDADE DE MUNDO: a imagem
    // inteira passa a medir [ladoMundo] no chão. Com TileMode.repeated isso
    // vira a laje de concreto do galpão, repetida em X e Z.
    final escala = ladoMundo / img.width;
    final m = Float64List.fromList([
      escala, 0, 0, 0,
      0, escala, 0, 0,
      0, 0, 1, 0,
      0, 0, 0, 1,
    ]);
    final s = ui.ImageShader(
      img, TileMode.repeated, TileMode.repeated, m,
      // Medium = bilinear COM mipmap. É o que impede o concreto de cintilar no
      // fundo do galpão, onde um ladrilho de metros cabe em poucos pixels.
      filterQuality: FilterQuality.medium,
    );
    _shaderImagem = img;
    _shaderLado   = ladoMundo;
    _shader       = s;
    shadersCriados++;
    return s;
  }
}

/// Matriz 4×4 (coluna-maior, como [Canvas.transform] espera) que leva um ponto
/// do plano do chão — `(x, z)` do mundo, entrando como `(x, y)` do canvas —
/// direto para o pixel de tela da [proj].
///
/// A dedução, para quem for conferir: para um ponto do piso `v = (x, 0, z)`,
/// `d = v - eye`, e as três projeções de `d` na base da câmera são AFINS em
/// `(x, z)` — a coordenada y é a constante `-eye.y`:
///
///   A = d·right = right.x·x + right.z·z − right·eye
///   B = d·up    = up.x·x    + up.z·z    − up·eye
///   C = d·fwd   = fwd.x·x   + fwd.z·z   − fwd·eye
///
/// E [ProjecaoCamera.paraTela] é, com `kx = 1/(tanH·aspect)` e `ky = 1/tanH`:
///
///   px = (larguraPx/2)·(A·kx + C) / C
///   py = (alturaPx/2) ·(C − B·ky) / C
///
/// Numerador e denominador afins em `(x, z)`: exatamente uma homografia, com
/// `C` no papel do `w`. Nenhuma aproximação — a mesma conta da projeção da
/// cena, só rearranjada para o canvas fazer a divisão por `w`.
Float64List matrizDoPlanoDoPiso(ProjecaoCamera proj) {
  final r = proj.right, u = proj.up, f = proj.fwd, e = proj.eye;
  final kx = 1.0 / (proj.tanH * proj.aspect);
  final ky = 1.0 / proj.tanH;
  final sw = proj.larguraPx / 2, sh = proj.alturaPx / 2;

  final a1 = r.x, a2 = r.z, a3 = -(r.x * e.x + r.y * e.y + r.z * e.z);
  final b1 = u.x, b2 = u.z, b3 = -(u.x * e.x + u.y * e.y + u.z * e.z);
  final c1 = f.x, c2 = f.z, c3 = -(f.x * e.x + f.y * e.y + f.z * e.z);

  final h00 = sw * (a1 * kx + c1);
  final h01 = sw * (a2 * kx + c2);
  final h02 = sw * (a3 * kx + c3);
  final h10 = sh * (c1 - b1 * ky);
  final h11 = sh * (c2 - b2 * ky);
  final h12 = sh * (c3 - b3 * ky);

  // Coluna-maior. As linhas usadas pelo canvas em 2D são a 0 (x), a 1 (y) e a
  // 3 (w) — daí os índices 0/4/12, 1/5/13 e 3/7/15.
  return Float64List.fromList([
    h00, h10, 0, c1, //
    h01, h11, 0, c2, //
    0, 0, 1, 0, //
    h02, h12, 0, c3, //
  ]);
}

/// O retângulo do piso recortado no near plane, em coordenadas de mundo
/// `(x, z)`.
///
/// Sem isto o pedaço de chão ATRÁS da câmera atravessaria a divisão por `w` com
/// sinal trocado e reapareceria espelhado no alto da tela. É o mesmo recorte
/// que [ProjecaoCamera] faz nas faces, escrito no plano: `C(x, z) ≥ near` é um
/// semiplano, e cortar um retângulo por um semiplano dá no máximo 5 vértices.
List<Offset> recortarPisoNoNear(
  ProjecaoCamera proj, {
  required double x0,
  required double x1,
  required double z0,
  required double z1,
}) {
  final f = proj.fwd, e = proj.eye;
  final c1 = f.x, c2 = f.z;
  final c3 = -(f.x * e.x + f.y * e.y + f.z * e.z);
  double dentro(Offset p) => c1 * p.dx + c2 * p.dy + c3 - ProjecaoCamera.near;

  final entrada = <Offset>[
    Offset(x0, z0),
    Offset(x1, z0),
    Offset(x1, z1),
    Offset(x0, z1),
  ];
  final saida = <Offset>[];
  for (var i = 0; i < entrada.length; i++) {
    final a = entrada[i], b = entrada[(i + 1) % entrada.length];
    final da = dentro(a), db = dentro(b);
    if (da >= 0) saida.add(a);
    if ((da >= 0) != (db >= 0)) {
      final t = da / (da - db);
      saida.add(Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t));
    }
  }
  return saida;
}

/// Pinta o piso `[x0, x1] × [z0, z1]` do plano y = 0 com a textura de concreto,
/// ou com [corFallback] enquanto ela não chegou.
///
/// O canvas é salvo e restaurado aqui dentro: quem chama continua desenhando em
/// coordenadas de tela como antes.
void pintarPisoTexturado(
  Canvas canvas,
  ProjecaoCamera proj, {
  required double x0,
  required double x1,
  required double z0,
  required double z1,
  required ui.Image? textura,
  required double ladoTextura,
  required Color corFallback,
}) {
  final poligono = recortarPisoNoNear(proj, x0: x0, x1: x1, z0: z0, z1: z1);
  if (poligono.length < 3) return; // piso inteiro atrás da câmera

  final chao = Path()..moveTo(poligono[0].dx, poligono[0].dy);
  for (var i = 1; i < poligono.length; i++) {
    chao.lineTo(poligono[i].dx, poligono[i].dy);
  }
  chao.close();

  final tinta = Paint();
  if (textura != null) {
    tinta.shader = TexturaPiso._shaderDe(textura, ladoTextura);
  } else {
    tinta.color = corFallback;
  }

  canvas.save();
  // Recorte em espaço de TELA antes da perspectiva: perto do near plane o
  // polígono do chão projeta em coordenadas enormes, e limitá-lo ao viewport
  // evita que o rasterizador trabalhe num triângulo de milhões de pixels.
  canvas.clipRect(Rect.fromLTWH(0, 0, proj.larguraPx, proj.alturaPx));
  canvas.transform(matrizDoPlanoDoPiso(proj));
  canvas.drawPath(chao, tinta);
  canvas.restore();
}

/// Projeção de um ponto do chão pela homografia de [matrizDoPlanoDoPiso],
/// para os testes conferirem que ela reproduz [ProjecaoCamera.paraTela].
@visibleForTesting
Offset aplicarMatrizDoPiso(Float64List m, double x, double z) {
  final w = m[3] * x + m[7] * z + m[15];
  return Offset(
    (m[0] * x + m[4] * z + m[12]) / w,
    (m[1] * x + m[5] * z + m[13]) / w,
  );
}
