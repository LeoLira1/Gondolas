import 'dart:math' as math;
import 'dart:ui' as ui show Image;
import 'package:flutter/foundation.dart' show mapEquals, setEquals;
import 'package:flutter/material.dart';

import 'galpao_config.dart';
import 'galpao_saldo.dart';
import 'gondola_scene.dart'
    show Vec3, Camera, ProjecaoCamera, luzCena, corEnderecoDivergente,
        corEnderecoDivergentePositiva;
import 'models.dart' show corConferenciaCiano;
import 'scene_gestures.dart';
import 'textura_piso.dart';

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
//   * as ruas da parte aberta são ordenadas entre si (no máximo 8 elementos,
//     custo desprezível);
//   * dentro da rua, as posições são percorridas das pontas para o meio, na
//     direção do olho (duas agulhas, O(n) — ver [ordemDeDesenho]);
//   * dentro da posição, de baixo para cima: a câmera fica sempre acima da
//     pilha, então o rack mais alto é o mais próximo.
//
// Com até 340 racks na tela (a parte 1 cheia) isso troca um sort de ~1.000
// faces por frame por
// um percurso linear. É intencional, não descuido: se um dia a grade deixar de
// ser regular, este é o primeiro lugar a rever.

/// Um rack ocupado numa posição do galpão.
///
/// [ordem] é a posição do rack DENTRO da pilha (1 = o de baixo) e é o que a
/// tela mostra como nível. Não é identidade: esvaziar um rack faz os de cima
/// descerem, e a ordem de todos eles muda. Ver a discussão em
/// galpao_config.dart.
class RackGalpao {
  final int    posicao;        // 1–129
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
  final int  posicao;  // 1–129
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

/// Pedido de animação da descida de uma pilha (esvaziar renumera as ordens e
/// os racks de cima descem um nível — uns 250 ms de ease-out é o que torna a
/// renumeração legível: sem isso o rack "teleporta" e o usuário não entende
/// por que o N2 virou N1).
///
/// A cena recebe as pilhas JÁ renumeradas e desenha os racks a partir de
/// [aPartirDaOrdem] deslocados um passo para cima, deslizando até o lugar.
/// [id] distingue duas descidas seguidas no mesmo endereço — é a mudança de
/// id que dispara a animação, não a igualdade dos outros campos.
class DescidaPilha {
  final int posicao;
  final int aPartirDaOrdem;
  final int id;

  const DescidaPilha({
    required this.posicao,
    required this.aPartirDaOrdem,
    required this.id,
  });
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

/// Lado, em METROS, da laje de concreto de assets/textures/galpao_concreto.png.
///
/// A imagem é uma textura contínua com UMA junta em cada eixo, então ladrilhada
/// ela vira uma laje de [_ladoLajeConcreto] m — não quatro de um quarto disso,
/// que é o que a moldura da imagem sugere à primeira vista. 6 m é o painel de
/// concreto industrial típico e deixa a repetição rara no envelope do galpão
/// (~18 × 20 m na parte 1), sem esticar o grão a ponto de borrar no zoom.
const double _ladoLajeConcreto = 6.0;

/// Contorno dos racks acesos pela busca — o mesmo laranja clareado, para
/// separar dois paletes vizinhos do mesmo produto sem inventar outra cor.
const Color _corDestaqueBorda = Color(0xFFffc98a);

// Modo Conferência: mesma dupla do mapa da loja — ciano nos racks pendentes,
// cinza morto nos demais —, para quem vem da loja reconhecer a leitura sem
// aprender outra convenção. O apagado é o _corApagado de loja_scene.dart, e o
// contorno da vaga livre fica bem mais fraco: no modo conferência a vaga não é
// destino de nada, só referência de onde a fileira está.
const Color _corApagado     = Color(0xFF2d2e31);
const Color _corVazioFraco  = Color(0x1FFFFFFF);

/// Cor de um rack na cena, na ordem de precedência que o galpão usa:
/// Modo Conferência > destaque da busca > saldo do produto > cor do produto.
///
/// É pura de propósito: a precedência entre as leituras é a regra que mais
/// confunde quem mexe na cena depois (a conferência apaga o galpão inteiro, e
/// um destaque de busca aceso por baixo dela seria mais uma cor sem
/// significado), e assim ela pode ser conferida sem pintar nada.
///
/// O saldo entra DEPOIS dos dois destaques e ANTES da cor de categoria: ele é
/// um estado permanente do produto (falta carga por endereçar, ou sobra
/// endereçada), enquanto conferência e busca são leituras momentâneas que a
/// pessoa acabou de pedir. As duas cores são as MESMAS das gôndolas e estantes
/// — vermelho para falta, azul escuro para sobra —, para não haver duas
/// convenções de divergência no mesmo app.
///
/// [destacadoCodigo] vazio não destaca ninguém: um rack gravado sem código
/// casaria com ele e acenderia o galpão todo.
Color corRackGalpao({
  required String produtoCodigo,
  Map<String, Color> corPorProduto  = const {},
  String? destacadoCodigo,
  bool modoConferencia              = false,
  Set<String> codigosConferencia    = const {},
  bool mostrarSaldo                 = false,
  Map<String, SaldoProduto> saldos  = const {},
}) {
  if (modoConferencia) {
    return codigosConferencia.contains(produtoCodigo)
        ? corConferenciaCiano
        : _corApagado;
  }
  if (destacadoCodigo != null &&
      destacadoCodigo.isNotEmpty &&
      produtoCodigo == destacadoCodigo) {
    return corCamda;
  }
  if (mostrarSaldo) {
    final saldo = saldos[produtoCodigo];
    // Produto sem saldo conhecido (fora do estoque_mestre, ou saldo ainda
    // carregando) segue na cor da categoria — pintar de vermelho o que não se
    // sabe seria inventar falta.
    if (saldo != null && saldo.falta) return corEnderecoDivergente;
    if (saldo != null && saldo.sobra) return corEnderecoDivergentePositiva;
  }
  return corPorProduto[produtoCodigo] ?? _corRack;
}

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

/// As ruas de uma PARTE, da mais longe para a mais perto do olho.
///
/// São 8 na parte 1 e 4 na parte 2: ordenar é mais barato e mais claro que
/// qualquer esquema esperto, e o resultado não depende de as ruas serem
/// paralelas (as Ruas 2 e 8 são perpendiculares às outras).
///
/// A parte filtra antes de [visiveis]: o mapa desenha um bloco de cada vez, e
/// uma rua da outra parte não entra na cena nem que o filtro a peça.
List<RuaGalpao> ruasPorProfundidade(Vec3 olho,
    {Set<int>? visiveis, int parte = 1}) {
  double distancia(RuaGalpao r) {
    final cx = r.eixo == EixoRua.z ? r.coordFixa : r.centro;
    final cz = r.eixo == EixoRua.z ? r.centro : r.coordFixa;
    final dx = cx - olho.x, dz = cz - olho.z;
    return dx * dx + dz * dz;
  }

  final lista = [
    for (final r in GalpaoConfig.ruasDaParte(parte))
      if (visiveis == null || visiveis.contains(r.numero)) r,
  ]..sort((a, b) => distancia(b).compareTo(distancia(a)));
  return lista;
}

// ── GalpaoPainter ────────────────────────────────────────────────────────────

class GalpaoPainter extends CustomPainter {
  final Camera camera;

  /// Pilhas por posição (1–129), cada uma ordenada por [RackGalpao.ordem].
  /// Posição ausente ou lista vazia = vaga livre no chão.
  final Map<int, List<RackGalpao>> pilhas;

  /// Cor de cada produto, na mesma convenção das outras cenas (categoria do
  /// estoque_mestre). Produto sem cor conhecida cai no cinza.
  final Map<String, Color> corPorProduto;

  final bool mostrarEtiquetas;

  /// Endereço selecionado (posição + ordem), ou null sem seleção.
  final ({int posicao, int ordem})? selecionado;

  /// Produto destacado pela busca: TODOS os racks com este código acendem em
  /// laranja CAMDA, no galpão inteiro.
  ///
  /// É o código que manda, não o endereço — pelo mesmo motivo do Modo
  /// Conferência (a pilha renumera ao esvaziar), e porque a pergunta que a
  /// busca responde é "onde está este produto", que quase nunca tem uma
  /// resposta só: o mesmo herbicida ocupa oito paletes espalhados por duas
  /// ruas, e destacar apenas o endereço escolhido na lista escondia os
  /// outros sete de quem estava olhando o mapa.
  final String? destacadoCodigo;

  /// Descida em andamento: racks (e o contorno de vaga) da posição, com ordem
  /// >= aPartirDe, desenhados [dy] metros acima do lugar final.
  final ({int posicao, int aPartirDe, double dy})? descida;

  /// Parte do galpão desenhada: 1 ou 2. O mapa mostra um bloco de cada vez —
  /// as ruas, posições e etiquetas da outra parte não são desenhadas, e o
  /// piso e o enquadramento seguem só o envelope desta.
  final int parte;

  /// Ruas visíveis (filtro R1–R8 na parte 1, R9–R12 na parte 2), ou null para
  /// todas as da parte. As ruas fora do conjunto somem por inteiro: cubos,
  /// contornos, números e rótulo.
  final Set<int>? ruasVisiveis;

  /// Modo Conferência: o galpão troca a cor de produto pela leitura de rota —
  /// ciano nos racks que guardam pendente de hoje, apagado em todo o resto.
  final bool modoConferencia;

  /// Códigos pendentes hoje. É o CÓDIGO que decide qual cubo acende, não o
  /// endereço: a pilha desce quando alguém esvazia um nível, e um destaque
  /// preso a (posição, ordem) acenderia o rack errado depois disso.
  final Set<String> codigosConferencia;

  /// Posição (1–129) → nº de produtos pendentes ali, para o badge contador.
  final Map<int, int> contagemConferencia;

  /// Leitura de saldo ligada: rack de produto com carga por endereçar fica
  /// vermelho, com carga endereçada a mais fica azul (ver [corRackGalpao]).
  final bool mostrarSaldo;

  /// Saldo por código de produto (ver galpao_saldo.dart). Só é consultado
  /// quando [mostrarSaldo] está ligado.
  final Map<String, SaldoProduto> saldos;

  /// Textura de concreto do chão, já decodificada (ver textura_piso.dart), ou
  /// null enquanto o asset carrega — nesse intervalo o piso é a cor chapada de
  /// sempre. O painter NÃO carrega nada: decodificar dentro do paint colocaria
  /// um decode de imagem em cada frame de arrasto da câmera.
  final ui.Image? texturaPiso;

  GalpaoPainter(
    this.camera, {
    this.pilhas             = const {},
    this.corPorProduto      = const {},
    this.mostrarEtiquetas   = true,
    this.selecionado,
    this.destacadoCodigo,
    this.descida,
    this.parte              = 1,
    this.ruasVisiveis,
    this.modoConferencia    = false,
    this.codigosConferencia = const {},
    this.contagemConferencia = const {},
    this.mostrarSaldo       = false,
    this.saldos             = const {},
    this.texturaPiso,
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
    final contornoDestaque = Paint()
      ..color       = _corDestaqueBorda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final vazio = Paint()
      ..color       = modoConferencia ? _corVazioFraco : _corVazio
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final vazioSel = Paint()
      ..color       = corCamda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final sel = selecionado;
    final desc = descida;
    // Código vazio não destaca nada: a busca pode devolver um endereço cujo
    // rack foi gravado sem código, e casar '' com '' acenderia o galpão todo.
    final codigoAceso =
        (destacadoCodigo?.isEmpty ?? true) ? null : destacadoCodigo;

    // Deslocamento vertical da descida em andamento, por rack.
    double dyDe(int numeroPosicao, int ordem) =>
        desc != null &&
                desc.posicao == numeroPosicao &&
                ordem >= desc.aPartirDe
            ? desc.dy
            : 0.0;

    for (final rua
        in ruasPorProfundidade(proj.eye, visiveis: ruasVisiveis, parte: parte)) {
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
          // Busca: o produto procurado acende no galpão inteiro. Vale para
          // TODOS os racks dele, não só o endereço que veio da lista de
          // resultados — é o que permite ler as oito posições do mesmo
          // herbicida de uma olhada no mapa. No Modo Conferência a leitura de
          // rota tem precedência, como nas estantes.
          final cor = corRackGalpao(
            produtoCodigo:      rack.produtoCodigo,
            corPorProduto:      corPorProduto,
            destacadoCodigo:    codigoAceso,
            modoConferencia:    modoConferencia,
            codigosConferencia: codigosConferencia,
            mostrarSaldo:       mostrarSaldo,
            saldos:             saldos,
          );
          final destacadoAceso = !modoConferencia &&
              codigoAceso != null &&
              rack.produtoCodigo == codigoAceso;
          _desenharCubo(
            canvas, proj, posicao, k + 1,
            // Seleção: clareia o cubo e troca o contorno pelo laranja CAMDA —
            // a cor do produto continua legível por baixo do destaque.
            cor: isSel ? Color.lerp(cor, Colors.white, 0.30)! : cor,
            preenchimento: preenchimento,
            // O rack aceso pela busca ganha um contorno âmbar claro: o cubo já
            // é laranja, e sem o traço as posições vizinhas do mesmo produto
            // viravam um bloco só no zoom de galpão inteiro.
            contorno: isSel
                ? contornoSel
                : destacadoAceso
                    ? contornoDestaque
                    : contorno,
            // Rack com outro em cima tem o topo escondido — não desenhar
            // também evita disputa de pintura entre as duas faces coladas.
            // Durante a descida o de cima está um pouco acima, mas continua
            // cobrindo o topo do de baixo na projeção — a regra se mantém.
            desenharTopo: k == pilha.length - 1,
            dy: dyDe(posicao.numero, k + 1),
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
              isSel ? vazioSel : vazio,
              dy: dyDe(posicao.numero, proxima));
        }
      }
    }

    // Badges depois de TODOS os cubos: eles flutuam acima da pilha e não
    // podem ser cobertos por um rack de uma rua mais próxima da câmera —
    // ao contrário dos números do chão, que são pintura no piso.
    if (modoConferencia) _desenharBadgesConferencia(canvas, proj);
  }

  // ── Piso ───────────────────────────────────────────────────────────────────

  /// Concreto + grade discreta no chão, do tamanho da parte aberta. Não entra
  /// na ordem de desenho: a câmera está sempre acima do piso, então ele é
  /// sempre a superfície mais ao fundo.
  ///
  /// O concreto é a textura do PLANO y = 0, instalada no canvas como uma
  /// homografia (ver textura_piso.dart) — não um fundo 2D. A grade e a borda
  /// continuam desenhadas em cima dele, em coordenadas de tela, exatamente como
  /// antes: o concreto entrou por baixo do mapa, não no lugar dele.
  void _desenharPiso(Canvas canvas, ProjecaoCamera proj) {
    const passo = 2.0;
    final lim = GalpaoConfig.limitesDaParte(parte);
    final x0 = lim.minX - 1.0, x1 = lim.maxX + 1.0;
    final z0 = lim.minZ - 1.0, z1 = lim.maxZ + 1.0;

    pintarPisoTexturado(
      canvas, proj,
      x0: x0, x1: x1, z0: z0, z1: z1,
      textura:     texturaPiso,
      ladoTextura: _ladoLajeConcreto,
      corFallback: _corPiso,
    );

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
      ProjecaoCamera proj, PosicaoGalpao p, int ordem, {double dy = 0}) {
    final hx = p.tamanhoX / 2, hz = p.tamanhoZ / 2;
    final y0 = GalpaoConfig.yBase(ordem) + dy;
    final y1 = GalpaoConfig.yTopo(ordem) + dy;
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
    double dy = 0,
  }) {
    if (!_projetarCantos(proj, p, ordem, dy: dy)) return;
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
      int ordem, Paint traco, {double dy = 0}) {
    if (!_projetarCantos(proj, p, ordem, dy: dy)) return;
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

    for (final p in GalpaoConfig.posicoesDaParte(parte)) {
      if (ruasVisiveis != null && !ruasVisiveis!.contains(p.rua.numero)) {
        continue;
      }
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
    for (final rua in GalpaoConfig.ruasDaParte(parte)) {
      if (ruasVisiveis != null && !ruasVisiveis!.contains(rua.numero)) {
        continue;
      }
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

  // ── Badges do Modo Conferência ─────────────────────────────────────────────

  /// Pílula ciana com `<posição> · <nº de pendentes>` acima de cada pilha que
  /// precisa de conferência — o mesmo contador que o mapa da loja põe sobre a
  /// gôndola, na mesma cor, para o galpão se ler como continuação da loja.
  ///
  /// Sem culling de ângulo (a pílula é informação, não geometria) e sempre
  /// desenhada acima do TOPO da pilha: assim ela não some atrás do próprio
  /// rack quando a câmera desce.
  void _desenharBadgesConferencia(Canvas canvas, ProjecaoCamera proj) {
    final margem = Rect.fromLTWH(
        -60, -60, proj.larguraPx + 120, proj.alturaPx + 120);

    // Coletadas primeiro e pintadas da mais longe para a mais perto: com duas
    // posições vizinhas acesas, é a badge da frente que fica legível por cima.
    final alvos = <({Offset tela, double cz, String texto})>[];
    for (final entry in contagemConferencia.entries) {
      final posicao = GalpaoConfig.porNumero(entry.key);
      if (posicao == null) continue;
      if (posicao.parte != parte) continue;
      if (ruasVisiveis != null &&
          !ruasVisiveis!.contains(posicao.rua.numero)) {
        continue;
      }
      final pilha = pilhas[entry.key] ?? const <RackGalpao>[];
      final altura = pilha.isEmpty ? 1 : pilha.length;
      final hit = proj.projetar(
          Vec3(posicao.x, GalpaoConfig.yTopo(altura) + 0.45, posicao.z));
      if (hit == null) continue;
      final (tela, cz) = hit;
      if (!margem.contains(tela)) continue;
      alvos.add((tela: tela, cz: cz, texto: '${entry.key} · ${entry.value}'));
    }
    alvos.sort((a, b) => b.cz.compareTo(a.cz));

    for (final alvo in alvos) {
      final fontSize = _tamanhoTexto(11.0, alvo.cz);
      if (fontSize < _fonteMinima) continue;

      final tp = TextPainter(
        text: TextSpan(
          text: alvo.texto,
          style: TextStyle(
            color:      const Color(0xFF04232a),
            fontSize:   fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final rect = Rect.fromCenter(
        center: alvo.tela,
        width:  tp.width  + fontSize,
        height: tp.height + fontSize * 0.56,
      );
      final rrect =
          RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
      canvas.drawRRect(
          rrect, Paint()..color = corConferenciaCiano.withValues(alpha: 0.94));
      canvas.drawRRect(
          rrect,
          Paint()
            ..color       = const Color(0xFF0b3a42)
            ..style       = PaintingStyle.stroke
            ..strokeWidth = 1.2);
      tp.paint(canvas, alvo.tela - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(GalpaoPainter old) =>
      old.modoConferencia     != modoConferencia ||
      !setEquals(old.codigosConferencia, codigosConferencia) ||
      !mapEquals(old.contagemConferencia, contagemConferencia) ||
      old.camera.rotY         != camera.rotY     ||
      old.camera.rotX         != camera.rotX     ||
      old.camera.dist         != camera.dist     ||
      old.camera.target.x     != camera.target.x ||
      old.camera.target.z     != camera.target.z ||
      old.mostrarEtiquetas    != mostrarEtiquetas ||
      old.selecionado         != selecionado      ||
      old.destacadoCodigo     != destacadoCodigo  ||
      old.descida             != descida          ||
      old.parte               != parte            ||
      !setEquals(old.ruasVisiveis, ruasVisiveis)  ||
      old.mostrarSaldo        != mostrarSaldo      ||
      !identical(old.saldos, saldos)              ||
      !identical(old.pilhas, pilhas)             ||
      !identical(old.corPorProduto, corPorProduto) ||
      !identical(old.texturaPiso, texturaPiso);
}

// ── GalpaoScene ──────────────────────────────────────────────────────────────

class GalpaoScene extends StatefulWidget {
  final Map<int, List<RackGalpao>> pilhas;
  final Map<String, Color>         corPorProduto;
  final bool                       mostrarEtiquetas;

  /// Endereço selecionado, destacado em laranja na cena.
  final ({int posicao, int ordem})? selecionado;

  /// Código do produto destacado pela busca: todos os racks dele acendem
  /// (ver [GalpaoPainter.destacadoCodigo]).
  final String? destacadoCodigo;

  /// Toque num endereço (cubo sólido ou contorno de vaga), ou null quando o
  /// toque caiu fora de qualquer alvo — é o gesto de desfazer a seleção.
  final ValueChanged<ToqueGalpao?>? onTapEndereco;

  /// Descida a animar (esvaziou e a pilha renumerou). A animação dispara na
  /// mudança do [DescidaPilha.id].
  final DescidaPilha? descida;

  /// Parte do galpão desenhada: 1 ou 2 (ver [GalpaoPainter.parte]). Trocar de
  /// parte reenquadra a câmera — os dois blocos ficam longe um do outro no
  /// plano, e manter a câmera onde estava abriria a parte nova fora da tela.
  final int parte;

  /// Ruas visíveis dentro da parte (filtro), ou null para todas.
  final Set<int>? ruasVisiveis;

  /// Modo Conferência ligado: racks com pendente de hoje em ciano, resto
  /// apagado, contador acima de cada pilha.
  final bool modoConferencia;

  /// Códigos pendentes hoje (ver [GalpaoPainter.codigosConferencia]).
  final Set<String> codigosConferencia;

  /// Posição → nº de produtos pendentes ali.
  final Map<int, int> contagemConferencia;

  /// Leitura de saldo ligada (ver [GalpaoPainter.mostrarSaldo]).
  final bool mostrarSaldo;

  /// Saldo por código de produto (ver [GalpaoPainter.saldos]).
  final Map<String, SaldoProduto> saldos;

  const GalpaoScene({
    super.key,
    this.pilhas             = const {},
    this.corPorProduto      = const {},
    this.mostrarEtiquetas   = true,
    this.selecionado,
    this.destacadoCodigo,
    this.onTapEndereco,
    this.descida,
    this.parte              = 1,
    this.ruasVisiveis,
    this.modoConferencia    = false,
    this.codigosConferencia = const {},
    this.contagemConferencia = const {},
    this.mostrarSaldo       = false,
    this.saldos             = const {},
  });

  /// Câmera isométrica que enquadra a [parte] pedida numa tela de [size].
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
  static Camera enquadrar(Size size, {int parte = 1}) {
    // Azimute pequeno de propósito: o galpão é um retângulo de ~16 × 20 m e a
    // tela do celular também é um retângulo em pé. Girar muito faz o galpão
    // atravessar a tela na diagonal, e a caixa que o contém na tela cresce
    // sem que o galpão apareça maior — sobra tarja preta em cima e embaixo.
    // 0,20 rad dá volume aos cubos sem jogar a planta na diagonal.
    const rotY = 0.20, rotX = 0.95;
    final lim  = GalpaoConfig.limitesDaParte(parte);
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
    with SingleTickerProviderStateMixin, SceneGestureGuard<GalpaoScene> {
  // Só é conhecida quando a tela tem tamanho (o enquadramento depende da
  // proporção), então nasce nula e é resolvida no primeiro build.
  Camera? _camera;
  Camera? _cameraAoIniciarGesto;

  final _painterKey = GlobalKey();

  /// Animação da descida da pilha: 250 ms, ease-out — rápido o bastante para
  /// não atrasar a próxima ação, lento o bastante para o olho acompanhar o
  /// rack assentando no nível novo. Criada no initState (não num late):
  /// numa cena que nunca animou, o primeiro toque no campo seria o dispose,
  /// que criaria o ticker com a árvore já desativada.
  late final AnimationController _descidaCtrl;

  /// Posições que podem receber toque AGORA — a lista de alvos do hit-test.
  ///
  /// ⚠️ Existe porque esconder no desenho não basta: se o hit-test varrer a
  /// grade inteira, os cubos das ruas filtradas — e os da outra parte, que
  /// nem estão na tela — continuam roubando o toque e o usuário seleciona uma
  /// posição que não está vendo. Por isso ela é RECONSTRUÍDA a cada mudança
  /// de parte ou de filtro (didUpdateWidget), e não recalculada por conta
  /// própria dentro do _hitTest.
  late List<PosicaoGalpao> _alvos;

  @override
  void initState() {
    super.initState();
    _descidaCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() => setState(() {}));
    _reconstruirAlvos();
    // Idempotente e compartilhada com as outras cenas: abrir o mapa dez vezes
    // decodifica o concreto UMA vez (ver TexturaPiso). Enquanto ela não chega,
    // o piso é a cor chapada de sempre e o mapa funciona igual.
    TexturaPiso.carregar();
  }

  void _reconstruirAlvos() {
    final visiveis = widget.ruasVisiveis;
    final daParte  = GalpaoConfig.posicoesDaParte(widget.parte);
    _alvos = visiveis == null
        ? daParte
        : [
            for (final p in daParte)
              if (visiveis.contains(p.rua.numero)) p,
          ];
  }

  @override
  void didUpdateWidget(GalpaoScene old) {
    super.didUpdateWidget(old);
    if (old.parte != widget.parte ||
        !setEquals(old.ruasVisiveis, widget.ruasVisiveis)) {
      _reconstruirAlvos();
    }
    // Parte nova, enquadramento novo: os dois blocos estão a dezenas de metros
    // um do outro, então a câmera da parte anterior aponta para chão vazio.
    // Zerar aqui faz o build seguinte reenquadrar com o tamanho real da tela,
    // que é a única coisa que o enquadramento precisa saber além da parte.
    if (old.parte != widget.parte) _camera = null;
    final d = widget.descida;
    if (d != null && d.id != old.descida?.id) {
      _descidaCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _descidaCtrl.dispose();
    super.dispose();
  }

  /// Descida corrente traduzida para o painter, ou null quando não há nada
  /// descendo (antes do primeiro esvaziar e depois que o rack assentou).
  ({int posicao, int aPartirDe, double dy})? get _descidaDoFrame {
    final d = widget.descida;
    if (d == null || !_descidaCtrl.isAnimating) return null;
    final dy = (1 - Curves.easeOutCubic.transform(_descidaCtrl.value)) *
        GalpaoConfig.passoNivel;
    return (posicao: d.posicao, aPartirDe: d.aPartirDaOrdem, dy: dy);
  }

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
      final lim = GalpaoConfig.limitesDaParte(widget.parte);

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
  /// pilha incompleta — o vazio é desenhado, então é tocável (é por ele que
  /// se lança carga).
  ///
  /// Regra de prioridade: quando o raio acerta a vaga E um rack DA MESMA
  /// posição, ganha o rack. Sem isso, tocar o topo da pilha nunca selecionava
  /// o rack de cima: o volume da vaga fica exatamente sobre ele, então
  /// qualquer toque na face superior atravessava a vaga primeiro — e esvaziar
  /// o topo, que é o movimento mais comum do galpão, exigia mirar na lateral.
  /// A vaga continua ganhando quando é o único alvo da posição no caminho do
  /// raio (posição vazia, ou toque no contorno em área que não cobre rack).
  ///
  /// Percorre [_alvos] — a lista reconstruída pela parte e pelo filtro de rua
  /// —, nunca a grade inteira: o que sumiu da tela não pode continuar
  /// recebendo toque.
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

    double? tDe(PosicaoGalpao p, int ordem) {
      final hx = p.tamanhoX / 2, hz = p.tamanhoZ / 2;
      return _rayAabb(eye, dir,
          x0: p.x - hx, x1: p.x + hx,
          y0: GalpaoConfig.yBase(ordem), y1: GalpaoConfig.yTopo(ordem),
          z0: p.z - hz, z1: p.z + hz);
    }

    ToqueGalpao? melhor;
    var melhorT = double.infinity;

    for (final p in _alvos) {
      final pilha = widget.pilhas[p.numero] ?? const <RackGalpao>[];

      // Racks ocupados: menor t entre os da posição (o raio pode varar mais
      // de um cubo da mesma pilha; vale o primeiro que ele encontra).
      double? tRack;
      var ordemRack = 0;
      for (var k = 0; k < pilha.length; k++) {
        final t = tDe(p, k + 1);
        if (t != null && (tRack == null || t < tRack)) {
          tRack     = t;
          ordemRack = k + 1;
        }
      }

      // A vaga só compete quando o raio NÃO acerta rack nenhum desta posição
      // (ver a regra de prioridade na doc do método).
      double? tVaga;
      if (tRack == null && pilha.length < GalpaoConfig.niveisMax) {
        tVaga = tDe(p, pilha.length + 1);
      }

      final t = tRack ?? tVaga;
      if (t != null && t < melhorT) {
        melhorT = t;
        melhor = tRack != null
            ? ToqueGalpao(posicao: p.numero, ordem: ordemRack, ocupado: true)
            : ToqueGalpao(
                posicao: p.numero, ordem: pilha.length + 1, ocupado: false);
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
        final camera = _camera ??=
            GalpaoScene.enquadrar(constraints.biggest, parte: widget.parte);

        return Listener(
          onPointerDown:   aoEncostarDedo,
          onPointerUp:     (e) { if (aoSoltarDedo(e)) _tryHitTest(pontoDoToque!); },
          onPointerCancel: aoSoltarDedo,
          child: GestureDetector(
            onScaleStart:  _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            // O builder existe só para o frame em que a textura termina de
            // carregar: ele repinta a cena com o concreto no lugar da cor
            // chapada. Depois disso o valor não muda mais e ele sai do caminho.
            child: ValueListenableBuilder<ui.Image?>(
              valueListenable: TexturaPiso.imagem,
              builder: (context, textura, _) => CustomPaint(
                key: _painterKey,
                painter: GalpaoPainter(
                  camera,
                  pilhas:              widget.pilhas,
                  corPorProduto:       widget.corPorProduto,
                  mostrarEtiquetas:    widget.mostrarEtiquetas,
                  selecionado:         widget.selecionado,
                  destacadoCodigo:     widget.destacadoCodigo,
                  descida:             _descidaDoFrame,
                  parte:               widget.parte,
                  ruasVisiveis:        widget.ruasVisiveis,
                  modoConferencia:     widget.modoConferencia,
                  codigosConferencia:  widget.codigosConferencia,
                  contagemConferencia: widget.contagemConferencia,
                  mostrarSaldo:        widget.mostrarSaldo,
                  saldos:              widget.saldos,
                  texturaPiso:         textura,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
      },
    );
  }
}
