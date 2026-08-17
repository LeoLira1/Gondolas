import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'galpao_config.dart';
import 'gondola_scene.dart' show Vec3, Camera, ProjecaoCamera, luzCena;
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Cena 3D do galpão de racks
// ─────────────────────────────────────────────────────────────────────────────
//
// Reaproveita o renderizador em software das outras cenas (Vec3, Camera,
// ProjecaoCamera de gondola_scene.dart), mas com UMA diferença deliberada:
// aqui NÃO há sort por profundidade.
//
// Nas outras cenas a geometria é irregular e o painter's algorithm ordena as
// faces a cada frame (`faces.sort((a, b) => b.depth.compareTo(a.depth))`). O
// galpão é uma grade fixa e regular: rua → posição → nível. Numa grade assim a
// ordem correta de desenho sai do PERCURSO dos índices, de trás para frente,
// sem comparar nada:
//
//   * as 7 ruas são ordenadas entre si (7 elementos, custo desprezível);
//   * dentro da rua, as posições são percorridas das pontas para o meio, na
//     direção do olho (duas agulhas, O(n) — ver [ordemDeDesenho]);
//   * dentro da posição, de baixo para cima: a câmera fica sempre acima da
//     pilha, então o rack mais alto é o mais próximo.
//
// Com até 312 racks na tela isso troca um sort de ~900 faces por frame por um
// percurso linear. É intencional, não descuido: se um dia a grade deixar de
// ser regular, este é o primeiro lugar a rever.

/// Um rack ocupado numa posição do galpão.
///
/// [ordem] é a posição do rack DENTRO da pilha (1 = o de baixo) e é o que a
/// tela mostra como nível. Não é identidade: esvaziar um rack faz os de cima
/// descerem, e a ordem de todos eles muda. Ver a discussão em
/// galpao_config.dart.
class RackGalpao {
  final int    posicao;        // 1–78
  final int    ordem;          // 1–GalpaoConfig.niveisMax
  final String produtoCodigo;
  final String produtoNome;
  final double quantidade;

  const RackGalpao({
    required this.posicao,
    required this.ordem,
    required this.produtoCodigo,
    this.produtoNome = '',
    this.quantidade  = 0,
  });
}

/// Resultado de um toque na cena: o endereço tocado, com o que havia nele.
///
/// [ordem] é a ordem na pilha (1 = chão) — nas pilhas cheias só há racks, e
/// numa posição com vaga o toque no contorno devolve a PRÓXIMA ordem livre,
/// que é onde uma carga nova entraria (produto novo sempre entra no topo).
class ToqueGalpao {
  final int  posicao;  // 1–78
  final int  ordem;    // 1–GalpaoConfig.niveisMax
  final bool ocupado;

  const ToqueGalpao({
    required this.posicao,
    required this.ordem,
    required this.ocupado,
  });

  @override
  bool operator ==(Object other) =>
      other is ToqueGalpao &&
      other.posicao == posicao &&
      other.ordem == ordem &&
      other.ocupado == ocupado;

  @override
  int get hashCode => Object.hash(posicao, ordem, ocupado);
}

// ── Cores ────────────────────────────────────────────────────────────────────

const Color corCamda        = Color(0xFFe87722);
const Color _corFundo       = Color(0xFF0b0c0e);
const Color _corPiso        = Color(0x0DFFFFFF);
const Color _corPisoBorda   = Color(0x1AFFFFFF);
const Color _corVazio       = Color(0x59FFFFFF);
const Color _corRack        = Color(0xFF888888);
const Color _corContorno    = Color(0x44000000);
const Color _corRotuloRua   = Color(0x4DFFFFFF);

/// Os 3 tons de um cubo: topo cheio, uma lateral média e a outra escura.
/// Sem textura e sem especular — o galpão quer leitura de posição, não
/// aparência de rack.
const double _tomTopo   = 1.00;
const double _tomMedio  = 0.68;
const double _tomEscuro = 0.46;

// ── Ordem de desenho ─────────────────────────────────────────────────────────

/// Posições de uma rua na ordem de desenho: da mais LONGE do olho para a mais
/// perto.
///
/// As posições de uma rua estão numa reta, então ordenar por distância 3D ao
/// olho é o mesmo que ordenar por distância ao longo do eixo da rua — o que
/// permite resolver com duas agulhas caminhando das pontas para o meio, sem
/// sort. Importa quando o olho fica NO MEIO da rua (câmera dentro do galpão):
/// aí as duas metades se afastam em sentidos opostos e um percurso monotônico
/// numa direção só pintaria na ordem errada.
List<PosicaoGalpao> ordemDeDesenho(RuaGalpao rua, double coordOlho) {
  final posicoes = GalpaoConfig.posicoesDaRua(rua.numero);
  final ordenado = <PosicaoGalpao>[];
  double coord(PosicaoGalpao p) => rua.eixo == EixoRua.z ? p.z : p.x;

  var i = 0, j = posicoes.length - 1;
  while (i <= j) {
    final di = (coord(posicoes[i]) - coordOlho).abs();
    final dj = (coord(posicoes[j]) - coordOlho).abs();
    if (di >= dj) {
      ordenado.add(posicoes[i++]);
    } else {
      ordenado.add(posicoes[j--]);
    }
  }
  return ordenado;
}

/// As ruas da mais longe para a mais perto do olho.
///
/// São 7: ordenar é mais barato e mais claro que qualquer esquema esperto, e
/// o resultado não depende de as ruas serem paralelas (a Rua 2 é perpendicular
/// às outras).
List<RuaGalpao> ruasPorProfundidade(Vec3 olho, {Set<int>? visiveis}) {
  double distancia(RuaGalpao r) {
    final cx = r.eixo == EixoRua.z ? r.coordFixa : r.centro;
    final cz = r.eixo == EixoRua.z ? r.centro : r.coordFixa;
    final dx = cx - olho.x, dz = cz - olho.z;
    return dx * dx + dz * dz;
  }

  final lista = [
    for (final r in GalpaoConfig.ruas)
      if (visiveis == null || visiveis.contains(r.numero)) r,
  ]..sort((a, b) => distancia(b).compareTo(distancia(a)));
  return lista;
}

// ── GalpaoPainter ────────────────────────────────────────────────────────────

class GalpaoPainter extends CustomPainter {
  final Camera camera;

  /// Pilhas por posição (1–78), cada uma ordenada por [RackGalpao.ordem].
  /// Posição ausente ou lista vazia = vaga livre no chão.
  final Map<int, List<RackGalpao>> pilhas;

  /// Cor de cada produto, na mesma convenção das outras cenas (categoria do
  /// estoque_mestre). Produto sem cor conhecida cai no cinza.
  final Map<String, Color> corPorProduto;

  final bool mostrarEtiquetas;

  /// Endereço selecionado (posição + ordem), ou null sem seleção.
  final ({int posicao, int ordem})? selecionado;

  GalpaoPainter(
    this.camera, {
    this.pilhas           = const {},
    this.corPorProduto    = const {},
    this.mostrarEtiquetas = true,
    this.selecionado,
  });

  // Buffers reusados entre cubos: um cubo tem 8 cantos, e alocar duas listas
  // por cubo daria ~600 alocações por frame só para jogar fora.
  final List<Offset> _cantos    = List<Offset>.filled(8, Offset.zero);
  final List<bool>   _cantoOk   = List<bool>.filled(8, false);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _corFundo);

    final proj = ProjecaoCamera(camera, size);
    _desenharPiso(canvas, proj);
    // Etiquetas ANTES dos cubos: elas são pintura no chão, então um rack mais
    // perto da câmera deve cobri-las — como as faixas pintadas de um
    // estacionamento. Com o galpão cheio, desenhá-las por cima virava uma
    // nuvem de números flutuando sobre os racks.
    if (mostrarEtiquetas) _desenharEtiquetas(canvas, proj);

    final preenchimento = Paint()..style = PaintingStyle.fill;
    final contorno = Paint()
      ..color       = _corContorno
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    final contornoSel = Paint()
      ..color       = corCamda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final vazio = Paint()
      ..color       = _corVazio
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final vazioSel = Paint()
      ..color       = corCamda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final sel = selecionado;

    for (final rua in ruasPorProfundidade(proj.eye)) {
      final coordOlho = rua.eixo == EixoRua.z ? proj.eye.z : proj.eye.x;
      for (final posicao in ordemDeDesenho(rua, coordOlho)) {
        final pilha = pilhas[posicao.numero] ?? const <RackGalpao>[];

        // De baixo para cima: a câmera fica acima da pilha, então o rack mais
        // alto é o mais próximo dela.
        for (var k = 0; k < pilha.length; k++) {
          final rack = pilha[k];
          final isSel = sel != null &&
              sel.posicao == posicao.numero &&
              sel.ordem == k + 1;
          final cor = corPorProduto[rack.produtoCodigo] ?? _corRack;
          _desenharCubo(
            canvas, proj, posicao, k + 1,
            // Seleção: clareia o cubo e troca o contorno pelo laranja CAMDA —
            // a cor do produto continua legível por baixo do destaque.
            cor: isSel ? Color.lerp(cor, Colors.white, 0.30)! : cor,
            preenchimento: preenchimento,
            contorno: isSel ? contornoSel : contorno,
            // Rack com outro em cima tem o topo escondido — não desenhar
            // também evita disputa de pintura entre as duas faces coladas.
            desenharTopo: k == pilha.length - 1,
          );
        }

        // A vaga livre é informação, não ausência dela: o contorno mostra onde
        // cabe carga nova, e em que nível ela entraria (sempre no topo da
        // pilha — rack flutuando com vazio embaixo não existe no galpão).
        if (pilha.length < GalpaoConfig.niveisMax) {
          final proxima = pilha.length + 1;
          final isSel = sel != null &&
              sel.posicao == posicao.numero &&
              sel.ordem == proxima;
          _desenharVazio(canvas, proj, posicao, proxima,
              isSel ? vazioSel : vazio);
        }
      }
    }
  }

  // ── Piso ───────────────────────────────────────────────────────────────────

  /// Grade discreta no chão, do tamanho do galpão. Não entra na ordem de
  /// desenho: a câmera está sempre acima do piso, então ele é sempre a
  /// superfície mais ao fundo.
  void _desenharPiso(Canvas canvas, ProjecaoCamera proj) {
    const passo = 2.0;
    final lim = GalpaoConfig.limites;
    final x0 = lim.minX - 1.0, x1 = lim.maxX + 1.0;
    final z0 = lim.minZ - 1.0, z1 = lim.maxZ + 1.0;

    final grade = Path();
    void linha(double ax, double az, double bx, double bz) {
      final a = proj.projetar(Vec3(ax, 0, az));
      final b = proj.projetar(Vec3(bx, 0, bz));
      if (a == null || b == null) return;
      grade.moveTo(a.$1.dx, a.$1.dy);
      grade.lineTo(b.$1.dx, b.$1.dy);
    }

    for (var x = x0; x <= x1 + 1e-9; x += passo) {
      linha(x, z0, x, z1);
    }
    for (var z = z0; z <= z1 + 1e-9; z += passo) {
      linha(x0, z, x1, z);
    }
    canvas.drawPath(
        grade,
        Paint()
          ..color       = _corPiso
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 0.8);

    final borda = Path();
    final cantos = [
      proj.projetar(Vec3(x0, 0, z0)),
      proj.projetar(Vec3(x1, 0, z0)),
      proj.projetar(Vec3(x1, 0, z1)),
      proj.projetar(Vec3(x0, 0, z1)),
    ];
    if (cantos.every((c) => c != null)) {
      borda.moveTo(cantos[0]!.$1.dx, cantos[0]!.$1.dy);
      for (var i = 1; i < cantos.length; i++) {
        borda.lineTo(cantos[i]!.$1.dx, cantos[i]!.$1.dy);
      }
      borda.close();
      canvas.drawPath(
          borda,
          Paint()
            ..color       = _corPisoBorda
            ..style       = PaintingStyle.stroke
            ..strokeWidth = 1.0);
    }
  }

  // ── Cubos ──────────────────────────────────────────────────────────────────

  /// Projeta os 8 cantos do rack de ordem [ordem] na posição [p].
  /// Devolve false se algum canto está atrás da câmera — o cubo inteiro é
  /// descartado nesse caso (acontece só com a câmera dentro da pilha; o
  /// recorte no near plane fica com quem ordena faces, que aqui não existe).
  bool _projetarCantos(
      ProjecaoCamera proj, PosicaoGalpao p, int ordem) {
    final hx = p.tamanhoX / 2, hz = p.tamanhoZ / 2;
    final y0 = GalpaoConfig.yBase(ordem), y1 = GalpaoConfig.yTopo(ordem);
    var ok = true;
    for (var i = 0; i < 8; i++) {
      final v = Vec3(
        p.x + ((i & 1) == 0 ? -hx : hx),
        (i & 2) == 0 ? y0 : y1,
        p.z + ((i & 4) == 0 ? -hz : hz),
      );
      final hit = proj.projetar(v);
      _cantoOk[i] = hit != null;
      if (hit == null) {
        ok = false;
      } else {
        _cantos[i] = hit.$1;
      }
    }
    return ok;
  }

  // Índices dos cantos de cada face, no esquema de bits de _projetarCantos
  // (bit 0 = x, bit 1 = y, bit 2 = z).
  static const List<int> _faceTopo   = [2, 3, 7, 6];
  static const List<int> _faceXMais  = [1, 3, 7, 5];
  static const List<int> _faceXMenos = [0, 2, 6, 4];
  static const List<int> _faceZMais  = [4, 5, 7, 6];
  static const List<int> _faceZMenos = [0, 1, 3, 2];

  /// As duas laterais visíveis de um cubo, ou uma só / nenhuma quando o olho
  /// está alinhado com ele. Nunca mais de 3 faces por cubo (topo + 2): as
  /// outras 3 não são desenhadas.
  (List<int>?, List<int>?) _lateraisVisiveis(
      ProjecaoCamera proj, PosicaoGalpao p) {
    final hx = p.tamanhoX / 2, hz = p.tamanhoZ / 2;
    final faceX = proj.eye.x > p.x + hx
        ? _faceXMais
        : proj.eye.x < p.x - hx
            ? _faceXMenos
            : null;
    final faceZ = proj.eye.z > p.z + hz
        ? _faceZMais
        : proj.eye.z < p.z - hz
            ? _faceZMenos
            : null;
    return (faceX, faceZ);
  }

  /// Sombreamento chapado: entre as duas laterais visíveis, a mais voltada
  /// para a luz da cena fica no tom médio e a outra no escuro. Usa a mesma
  /// [luzCena] das outras cenas, para o galpão não parecer iluminado de outro
  /// lugar que a loja.
  double _tomLateral(List<int> face, List<int>? outra) {
    if (outra == null) return _tomMedio;
    double dot(List<int> f) {
      if (identical(f, _faceXMais))  return luzCena.x;
      if (identical(f, _faceXMenos)) return -luzCena.x;
      if (identical(f, _faceZMais))  return luzCena.z;
      return -luzCena.z;
    }
    return dot(face) >= dot(outra) ? _tomMedio : _tomEscuro;
  }

  void _desenharCubo(
    Canvas canvas,
    ProjecaoCamera proj,
    PosicaoGalpao p,
    int ordem, {
    required Color cor,
    required Paint preenchimento,
    required Paint contorno,
    required bool desenharTopo,
  }) {
    if (!_projetarCantos(proj, p, ordem)) return;
    final (faceX, faceZ) = _lateraisVisiveis(proj, p);

    void pintar(List<int> face, double tom) {
      final path = Path()
        ..moveTo(_cantos[face[0]].dx, _cantos[face[0]].dy);
      for (var i = 1; i < face.length; i++) {
        path.lineTo(_cantos[face[i]].dx, _cantos[face[i]].dy);
      }
      path.close();
      preenchimento.color = Color.lerp(Colors.black, cor, tom)!;
      canvas.drawPath(path, preenchimento);
      canvas.drawPath(path, contorno);
    }

    // Laterais antes do topo: as três se encontram na aresta de cima, e o topo
    // por último deixa o encontro limpo.
    if (faceX != null) pintar(faceX, _tomLateral(faceX, faceZ));
    if (faceZ != null) pintar(faceZ, _tomLateral(faceZ, faceX));
    if (desenharTopo) pintar(_faceTopo, _tomTopo);
  }

  void _desenharVazio(Canvas canvas, ProjecaoCamera proj, PosicaoGalpao p,
      int ordem, Paint traco) {
    if (!_projetarCantos(proj, p, ordem)) return;
    final (faceX, faceZ) = _lateraisVisiveis(proj, p);

    final path = Path();
    void contornar(List<int> face) {
      path.moveTo(_cantos[face[0]].dx, _cantos[face[0]].dy);
      for (var i = 1; i < face.length; i++) {
        path.lineTo(_cantos[face[i]].dx, _cantos[face[i]].dy);
      }
      path.close();
    }

    if (faceX != null) contornar(faceX);
    if (faceZ != null) contornar(faceZ);
    contornar(_faceTopo);
    canvas.drawPath(path, traco);
  }

  // ── Etiquetas ──────────────────────────────────────────────────────────────

  /// Menor tamanho de fonte que ainda é número, e não sujeira no chão.
  static const double _fonteMinima = 7.0;

  /// Tamanho do texto de uma etiqueta a [cz] metros da câmera.
  ///
  /// A referência é a distância ATUAL da câmera, não uma constante: assim a
  /// etiqueta nasce com o tamanho de projeto no enquadramento inicial (que
  /// depende do tamanho da tela, e por isso não pode ser fixado num número), e
  /// cresce quando o usuário aproxima. Uma primeira versão usava uma constante
  /// de 16 m e, na distância real de enquadramento (~45 m), caía abaixo do
  /// mínimo — o galpão abria sem um único número no chão.
  double _tamanhoTexto(double base, double cz) =>
      base * (camera.dist / cz).clamp(0.5, 2.2);

  void _desenharEtiquetas(Canvas canvas, ProjecaoCamera proj) {
    final margem = Rect.fromLTWH(
        -40, -40, proj.larguraPx + 80, proj.alturaPx + 80);

    for (final p in GalpaoConfig.posicoes) {
      final (ex, ez) = p.pontoEtiqueta;
      final hit = proj.projetar(Vec3(ex, 0.02, ez));
      if (hit == null) continue;
      final (tela, cz) = hit;
      if (!margem.contains(tela)) continue;

      final fontSize = _tamanhoTexto(11.0, cz);
      // Abaixo disso o número vira sujeira no chão em vez de informação.
      if (fontSize < _fonteMinima) continue;

      final tp = TextPainter(
        text: TextSpan(
          text: '${p.numero}',
          style: TextStyle(
            color:      corCamda,
            fontSize:   fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, tela - Offset(tp.width / 2, tp.height / 2));
    }

    // Nome da rua na ponta de menor coordenada, para orientar quem está
    // procurando um endereço.
    for (final rua in GalpaoConfig.ruas) {
      final posicoes = GalpaoConfig.posicoesDaRua(rua.numero);
      if (posicoes.isEmpty) continue;
      final ponta = posicoes.first;
      // Além de recuar da ponta, o rótulo sai para o lado do corredor: nos
      // pares costas com costas (4/5 e 6/7) os eixos ficam a 1,05 m um do
      // outro, e dois "RUA n" nessa distância se sobrepõem na tela. Como o
      // lado do corredor é oposto em cada rua do par, o desvio os separa.
      const recuo = GalpaoConfig.passoPosicao;
      const desvio = 0.9;
      final alvo = rua.eixo == EixoRua.z
          ? Vec3(ponta.x + rua.ladoCorredor * desvio, 0.02, ponta.z - recuo)
          : Vec3(ponta.x - recuo, 0.02, ponta.z + rua.ladoCorredor * desvio);
      final hit = proj.projetar(alvo);
      if (hit == null) continue;
      final (tela, cz) = hit;
      if (!margem.contains(tela)) continue;

      final fontSize = _tamanhoTexto(13.0, cz);
      if (fontSize < _fonteMinima) continue;

      final tp = TextPainter(
        text: TextSpan(
          text: 'RUA ${rua.numero}',
          style: TextStyle(
            color:         _corRotuloRua,
            fontSize:      fontSize,
            fontWeight:    FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, tela - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(GalpaoPainter old) =>
      old.camera.rotY         != camera.rotY     ||
      old.camera.rotX         != camera.rotX     ||
      old.camera.dist         != camera.dist     ||
      old.camera.target.x     != camera.target.x ||
      old.camera.target.z     != camera.target.z ||
      old.mostrarEtiquetas    != mostrarEtiquetas ||
      old.selecionado         != selecionado      ||
      !identical(old.pilhas, pilhas)             ||
      !identical(old.corPorProduto, corPorProduto);
}

// ── GalpaoScene ──────────────────────────────────────────────────────────────

class GalpaoScene extends StatefulWidget {
  final Map<int, List<RackGalpao>> pilhas;
  final Map<String, Color>         corPorProduto;
  final bool                       mostrarEtiquetas;

  /// Endereço selecionado, destacado em laranja na cena.
  final ({int posicao, int ordem})? selecionado;

  /// Toque num endereço (cubo sólido ou contorno de vaga), ou null quando o
  /// toque caiu fora de qualquer alvo — é o gesto de desfazer a seleção.
  final ValueChanged<ToqueGalpao?>? onTapEndereco;

  const GalpaoScene({
    super.key,
    this.pilhas           = const {},
    this.corPorProduto    = const {},
    this.mostrarEtiquetas = true,
    this.selecionado,
    this.onTapEndereco,
  });

  /// Câmera isométrica que enquadra o galpão inteiro numa tela de [size].
  ///
  /// O enquadramento é calculado, não chutado. Para um ponto p, com
  /// a = p − alvo e o olho em alvo + dir·dist, vale que `dot(a, right)` e
  /// `dot(a, up)` NÃO dependem de dist (right e up são perpendiculares a dir),
  /// e `dot(a, fwd)` vale `dot(a, fwd)|dist=0 + dist`. A condição de caber na
  /// tela, |dot(a,up)| ≤ tan(fov/2)·profundidade, vira então
  ///
  ///   dist ≥ |dot(a, up)| ÷ tan(fov/2) − dot(a, fwd)
  ///
  /// (e o análogo em right, com o aspecto). É exata em perspectiva — o termo
  /// −dot(a, fwd) é o que faz os cantos MAIS PRÓXIMOS da câmera, que a
  /// perspectiva joga para fora da tela, pedirem mais distância que os do
  /// fundo. Uma primeira versão ortográfica ignorava esse termo e compensava
  /// com uma folga arbitrária; o canto de baixo escapava da tela no formato
  /// deitado.
  static Camera enquadrar(Size size) {
    // Azimute pequeno de propósito: o galpão é um retângulo de ~16 × 20 m e a
    // tela do celular também é um retângulo em pé. Girar muito faz o galpão
    // atravessar a tela na diagonal, e a caixa que o contém na tela cresce
    // sem que o galpão apareça maior — sobra tarja preta em cima e embaixo.
    // 0,20 rad dá volume aos cubos sem jogar a planta na diagonal.
    const rotY = 0.20, rotX = 0.95;
    final lim  = GalpaoConfig.limites;
    final alvo = Vec3(
      (lim.minX + lim.maxX) / 2,
      GalpaoConfig.yTopo(GalpaoConfig.niveisMax) / 2,
      (lim.minZ + lim.maxZ) / 2,
    );

    // Base da câmera: depende só dos ângulos, não da distância.
    final cosX = math.cos(rotX);
    final dir  = Vec3(math.sin(rotY) * cosX, math.sin(rotX),
        math.cos(rotY) * cosX); // olho = alvo + dir · dist
    final fwd   = (dir * -1).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    final tanH   = math.tan(ProjecaoCamera.fovY / 2);
    final aspect = size.height <= 0 ? 1.0 : size.width / size.height;

    var dist = 8.0;
    for (final cx in [lim.minX, lim.maxX]) {
      for (final cz in [lim.minZ, lim.maxZ]) {
        for (final cy in [0.0, GalpaoConfig.yTopo(GalpaoConfig.niveisMax)]) {
          final a = Vec3(cx, cy, cz) - alvo;
          final aoFundo  = a.dot(fwd);
          final precisaH = a.dot(right).abs() / (tanH * aspect) - aoFundo;
          final precisaV = a.dot(up).abs() / tanH - aoFundo;
          dist = math.max(dist, math.max(precisaH, precisaV));
        }
      }
    }
    // Folga pequena: a conta acima já é exata para os cantos do envelope, e
    // esta margem é só para as etiquetas do chão, que ficam do lado de fora
    // das posições da ponta.
    return Camera(rotY: rotY, rotX: rotX, dist: dist * 1.06, target: alvo);
  }

  @override
  State<GalpaoScene> createState() => _GalpaoSceneState();
}

class _GalpaoSceneState extends State<GalpaoScene>
    with SceneGestureGuard<GalpaoScene> {
  // Só é conhecida quando a tela tem tamanho (o enquadramento depende da
  // proporção), então nasce nula e é resolvida no primeiro build.
  Camera? _camera;
  Camera? _cameraAoIniciarGesto;

  final _painterKey = GlobalKey();

  // Toque vs. arrasto, mais apertado que o padrão das outras cenas: os alvos
  // aqui são cubos de mais de 1 m — não precisam de tolerância de mira — e o
  // gesto dominante da tela é girar a câmera, então o custo de um arrasto
  // curto virar seleção é maior que o de exigir o dedo firme. Segurar mais de
  // 600 ms também deixa de ser toque: é alguém pensando com o dedo na tela.
  @override
  double get limiarDeArrasto => 9.0;

  @override
  Duration? get duracaoMaximaDoToque => const Duration(milliseconds: 600);

  /// Limites de zoom e de deslocamento, em metros. O pan é preso ao envelope
  /// do galpão com uma folga: sem isso um arrasto longo joga o galpão para
  /// fora da tela e não há como voltar.
  static const double _distMin = 6.0;
  static const double _distMax = 90.0;
  static const double _folgaPan = 6.0;

  void _onScaleStart(ScaleStartDetails d) {
    beginGesture(d);
    _cameraAoIniciarGesto = _camera;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final origem = gestureOrigin;
    final c0     = _cameraAoIniciarGesto;
    if (origem == null || c0 == null) return;

    if (reanchorIfPointersChanged(d)) {
      _cameraAoIniciarGesto = _camera;
      return;
    }
    markDragIfMoved(d);

    final delta = d.focalPoint - origem;

    if (d.pointerCount >= 2) {
      // Dois dedos: orbita + zoom, como no mapa da loja.
      setState(() {
        _camera = Camera(
          rotY:   c0.rotY - delta.dx * 0.006,
          // O galpão é largo e baixo: descer demais a câmera esconde as ruas
          // do fundo atrás das da frente.
          rotX:   (c0.rotX + delta.dy * 0.006).clamp(0.30, 1.45),
          dist:   (c0.dist / d.scale).clamp(_distMin, _distMax),
          target: c0.target,
        );
      });
    } else {
      // Um dedo: pan — o ponto do chão acompanha o dedo.
      final rb  = _painterKey.currentContext?.findRenderObject() as RenderBox?;
      final hPx = rb?.size.height ?? 600.0;
      final metrosPorPx =
          2 * c0.dist * math.tan(ProjecaoCamera.fovY / 2) / hPx;
      final inclinacao = math.max(math.sin(c0.rotX), 0.35);

      final dx = delta.dx * metrosPorPx;
      final dz = delta.dy * metrosPorPx / inclinacao;
      final lim = GalpaoConfig.limites;

      setState(() {
        _camera = Camera(
          rotY: c0.rotY,
          rotX: c0.rotX,
          dist: c0.dist,
          target: Vec3(
            (c0.target.x - math.cos(c0.rotY) * dx - math.sin(c0.rotY) * dz)
                .clamp(lim.minX - _folgaPan, lim.maxX + _folgaPan),
            c0.target.y,
            (c0.target.z + math.sin(c0.rotY) * dx - math.cos(c0.rotY) * dz)
                .clamp(lim.minZ - _folgaPan, lim.maxZ + _folgaPan),
          ),
        );
      });
    }
  }

  // ── Hit-test ──────────────────────────────────────────────────────────────

  void _tryHitTest(Offset toqueGlobal) {
    final rb = _painterKey.currentContext?.findRenderObject() as RenderBox?;
    final camera = _camera;
    if (rb == null || camera == null) return;
    widget.onTapEndereco?.call(_hitTest(
        camera, rb.globalToLocal(toqueGlobal), rb.size));
  }

  /// Endereço sob o toque, ou null se o raio não acerta cubo nem contorno.
  ///
  /// Os alvos são os racks ocupados E o contorno da próxima vaga de cada
  /// pilha incompleta — o vazio é desenhado, então é tocável (é assim que se
  /// vai lançar carga na etapa 4). Ganha o alvo de menor t, o mais próximo da
  /// câmera; como o contorno da vaga fica sempre ACIMA dos racks da própria
  /// pilha, ele nunca rouba o toque de um cubo da mesma posição.
  ///
  /// ⚠️ Etapa 5 (filtro por rua): este é o lugar onde a lista de candidatos
  /// tem de ser reconstruída — o que estiver escondido sai DAQUI, não só do
  /// desenho, senão um cubo invisível continua roubando o toque.
  ToqueGalpao? _hitTest(Camera camera, Offset toque, Size size) {
    final eye   = camera.position;
    final fwd   = (camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;
    final tanH   = math.tan(ProjecaoCamera.fovY / 2);
    final aspect = size.width / size.height;

    final ndcX = 2 * toque.dx / size.width - 1;
    final ndcY = 1 - 2 * toque.dy / size.height;
    final dir  = (right * (ndcX * tanH * aspect) + up * (ndcY * tanH) + fwd)
        .normalized;

    ToqueGalpao? melhor;
    var melhorT = double.infinity;

    void considerar(PosicaoGalpao p, int ordem, bool ocupado) {
      final hx = p.tamanhoX / 2, hz = p.tamanhoZ / 2;
      final t = _rayAabb(eye, dir,
          x0: p.x - hx, x1: p.x + hx,
          y0: GalpaoConfig.yBase(ordem), y1: GalpaoConfig.yTopo(ordem),
          z0: p.z - hz, z1: p.z + hz);
      if (t != null && t < melhorT) {
        melhorT = t;
        melhor  = ToqueGalpao(
            posicao: p.numero, ordem: ordem, ocupado: ocupado);
      }
    }

    for (final p in GalpaoConfig.posicoes) {
      final pilha = widget.pilhas[p.numero] ?? const <RackGalpao>[];
      for (var k = 0; k < pilha.length; k++) {
        considerar(p, k + 1, true);
      }
      if (pilha.length < GalpaoConfig.niveisMax) {
        considerar(p, pilha.length + 1, false);
      }
    }
    return melhor;
  }

  /// Distância até a entrada do raio na caixa alinhada aos eixos, ou null se
  /// não acerta (método dos slabs — mesmo helper das outras cenas).
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
      if (tA > tB) (tA, tB) = (tB, tA);
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // Enquadra na primeira medida útil da tela. Atribuir aqui (e não num
        // post-frame com setState) evita um frame com a câmera no lugar
        // errado; é idempotente e não muda nada visível depois disso.
        final camera = _camera ??= GalpaoScene.enquadrar(constraints.biggest);

        return Listener(
          onPointerDown:   aoEncostarDedo,
          onPointerUp:     (e) { if (aoSoltarDedo(e)) _tryHitTest(pontoDoToque!); },
          onPointerCancel: aoSoltarDedo,
          child: GestureDetector(
            onScaleStart:  _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            child: CustomPaint(
              key: _painterKey,
              painter: GalpaoPainter(
                camera,
                pilhas:           widget.pilhas,
                corPorProduto:    widget.corPorProduto,
                mostrarEtiquetas: widget.mostrarEtiquetas,
                selecionado:      widget.selecionado,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}
