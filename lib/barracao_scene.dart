import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'barracao_config.dart';
import 'barracao_service.dart' show EnderecoBarracao;
import 'gondola_scene.dart'
    show Vec3, Camera, Face, ProjecaoCamera;
import 'scene_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Cena 3D do BARRACÃO da CAMDA
// ─────────────────────────────────────────────────────────────────────────────
//
// Mesmo renderizador por software das outras cenas (Vec3/Camera/
// ProjecaoCamera de gondola_scene.dart) e mesma leitura: tema escuro, acento
// laranja CAMDA, câmera em órbita com um dedo para arrastar e dois para girar
// e dar zoom.
//
// A ordenação é a do MAPA DA LOJA — painter's algorithm, faces ordenadas por
// profundidade a cada paint —, e não o percurso de índices do galpão. O galpão
// pode dispensar o sort porque é uma grade e só uma grade; aqui há quatro
// paredes altas, três aberturas e a grade de paletes no meio delas, e nenhum
// percurso de índices ordena uma parede contra um palete. As paredes longas
// são fatiadas em trechos de ~500 cm ([_passoFatia]) justamente para o sort
// por centroide não ter de decidir entre um pano de 35 m e o palete que ele
// esconde pela metade.
//
// A geometria é fixa e a lista de faces é memoizada (mesmo motivo do mapa da
// loja): ela só é remontada quando muda o cadastro, a seleção ou o destaque.
//
// ATENÇÃO À UNIDADE: o mundo desta cena é em CENTÍMETROS, como toda a planta
// do barracão (ver barracao_config.dart). A loja e o galpão são em metros. O
// renderizador é adimensional, então isso não colide — mas as constantes de
// câmera, zoom e pan daqui estão todas em centímetros.

// ── Cores ────────────────────────────────────────────────────────────────────

const Color corCamdaBarracao = Color(0xFFe87722);

const Color _corFundo       = Color(0xFF0b0c0e);
const Color _corPiso        = Color(0xFF16181c);
const Color _corPisoGrade   = Color(0x14FFFFFF);
const Color _corParede      = Color(0xFF2a2b2f);
const Color _corParedeTopo  = Color(0xFF3a3c42);
const Color _corVerga       = Color(0xFF232428);
const Color _corMadeira     = Color(0xFF8a6a42);
const Color _corBagPadrao   = Color(0xFF888888);
const Color _corContorno    = Color(0x44000000);
const Color _corVazio       = Color(0x4DFFFFFF);
const Color _corRotulo      = Color(0x66FFFFFF);

/// Contorno do palete aceso pela busca — o mesmo âmbar claro do galpão, para
/// separar dois paletes vizinhos do mesmo produto sem inventar outra cor.
const Color _corDestaqueBorda = Color(0xFFffc98a);

/// Cor do bag de um endereço, na ordem de precedência do barracão:
/// destaque da busca > cor do produto > cinza de produto desconhecido.
///
/// É pura de propósito, como [corRackGalpao] do galpão: a precedência entre as
/// leituras é a regra que mais confunde quem mexe na cena depois, e assim ela
/// pode ser conferida sem pintar nada. [destacadoCodigo] vazio não destaca
/// ninguém — um endereço gravado sem código casaria com ele e acenderia o
/// barracão inteiro.
Color corBagBarracao({
  required String produtoCodigo,
  Map<String, Color> corPorProduto = const {},
  String? destacadoCodigo,
}) {
  if (destacadoCodigo != null &&
      destacadoCodigo.isNotEmpty &&
      produtoCodigo == destacadoCodigo) {
    return corCamdaBarracao;
  }
  return corPorProduto[produtoCodigo] ?? _corBagPadrao;
}

// ── Geometria ────────────────────────────────────────────────────────────────

/// As faces do barracão: paredes (com as aberturas), paletes e bags.
///
/// Tudo em centímetros, no sistema da planta: X ao longo dos 35 m, Z da parede
/// das aberturas (Z = 0) para o fundo, Y para cima.
class BarracaoGeometry {
  /// Comprimento máximo de um trecho de parede. Uma parede de 35 m desenhada
  /// como uma face só é um problema para o sort por centroide: ela vale por um
  /// ponto no meio do barracão, e a metade dela que fica à frente de um palete
  /// pode acabar pintada antes dele. Fatiada, cada pedaço compete pela
  /// profundidade do lugar em que ele realmente está.
  static const double _passoFatia = 500;

  /// Lado do ladrilho do piso, em centímetros — a grade que dá escala ao
  /// salão. É desenhada como linha, não como face preenchida.
  static const double _ladoGrade = 100;

  static List<Face>? _cacheFaces;
  static Object? _cacheChave;

  /// Faces do barracão para este quadro de dados.
  ///
  /// Memoizada como as do mapa da loja: a lista tem mais de mil faces e nada
  /// nela muda entre dois arrastos de câmera — só `proj`/`depth`/`light`, que
  /// o painter reescreve a cada paint.
  static List<Face> buildFaces(
    List<EnderecoBarracao> enderecos, {
    Map<String, Color> corPorProduto = const {},
    int? selecionadoId,
    String? destacadoCodigo,
  }) {
    // As duas coleções entram na chave por IDENTIDADE: List e Map não
    // sobrescrevem `==`, então o registro compara referência — que é
    // exatamente o contrato de "a página trocou os dados", e não uma varredura
    // de 100 endereços a cada frame.
    final chave = (enderecos, corPorProduto, selecionadoId, destacadoCodigo);
    final cache = _cacheFaces;
    if (cache != null && _cacheChave == chave) return cache;

    final faces = <Face>[];
    _paredes(faces);
    for (final e in enderecos) {
      _palete(faces, e,
          corPorProduto:   corPorProduto,
          selecionado:     e.id == selecionadoId,
          destacadoCodigo: destacadoCodigo);
    }

    _cacheChave = chave;
    _cacheFaces = faces;
    return faces;
  }

  /// Invalida a memoização. Só os testes precisam disso — a chave já cobre
  /// tudo que muda em produção.
  @visibleForTesting
  static void limparCache() {
    _cacheFaces = null;
    _cacheChave = null;
  }

  // ── Paredes ────────────────────────────────────────────────────────────────

  static void _paredes(List<Face> faces) {
    const esp = BarracaoConfig.espessuraParede;
    const h   = BarracaoConfig.peDireito;
    const z1  = BarracaoConfig.profundidade;
    const x1  = BarracaoConfig.largura;

    // Parede da frente (Z = 0), a das aberturas: os panos cheios saem de
    // BarracaoConfig (derivados das aberturas, nunca escritos à mão) e cada
    // abertura leva a sua verga por cima.
    for (final pano in BarracaoConfig.panosDaFrente) {
      _fatiarEmX(faces, pano, 0, esp, _corParede);
    }
    for (final verga in BarracaoConfig.vergas) {
      _fatiarEmX(faces, verga, 0, esp, _corVerga);
    }

    // Parede do fundo (Z = profundidade), cheia.
    _fatiarEmX(
      faces,
      const TrechoParede(x0: 0, x1: x1, y0: 0, y1: h),
      z1 - esp, z1,
      _corParede,
    );

    // Laterais de 10 m, cheias. Correm só o miolo em Z para não se sobrepor
    // à frente nem ao fundo — faces coplanares coladas brigam pelo mesmo
    // pixel e piscam quando a câmera gira.
    _fatiarEmZ(faces, 0, esp, esp, z1 - esp, h);
    _fatiarEmZ(faces, x1 - esp, x1, esp, z1 - esp, h);
  }

  /// Um trecho de parede paralelo a X, fatiado em pedaços de no máximo
  /// [_passoFatia] (ver a nota lá).
  static void _fatiarEmX(List<Face> faces, TrechoParede t, double z0,
      double z1, Color cor) {
    final n = math.max(1, (t.largura / _passoFatia).ceil());
    for (var i = 0; i < n; i++) {
      final xa = t.x0 + t.largura * i / n;
      final xb = t.x0 + t.largura * (i + 1) / n;
      _caixa(faces,
          x0: xa, x1: xb, y0: t.y0, y1: t.y1, z0: z0, z1: z1,
          cor: cor, corTopo: t.y1 >= BarracaoConfig.peDireito
              ? _corParedeTopo
              : cor);
    }
  }

  /// Uma parede lateral (paralela a Z), fatiada pelo mesmo motivo.
  static void _fatiarEmZ(List<Face> faces, double x0, double x1, double z0,
      double z1, double altura) {
    final comprimento = z1 - z0;
    final n = math.max(1, (comprimento / _passoFatia).ceil());
    for (var i = 0; i < n; i++) {
      final za = z0 + comprimento * i / n;
      final zb = z0 + comprimento * (i + 1) / n;
      _caixa(faces,
          x0: x0, x1: x1, y0: 0, y1: altura, z0: za, z1: zb,
          cor: _corParede, corTopo: _corParedeTopo);
    }
  }

  // ── Palete + bag ───────────────────────────────────────────────────────────

  static void _palete(
    List<Face> faces,
    EnderecoBarracao e, {
    required Map<String, Color> corPorProduto,
    required bool selecionado,
    String? destacadoCodigo,
  }) {
    const px = BarracaoConfig.paleteX / 2;
    const pz = BarracaoConfig.paleteZ / 2;

    // O estrado de madeira é desenhado SEMPRE, com produto ou sem: o palete é
    // o endereço, e um endereço livre continua sendo um lugar do barracão —
    // é informação, não ausência dela (mesma leitura da vaga do galpão).
    _caixa(faces,
        x0: e.x - px, x1: e.x + px,
        y0: 0,        y1: BarracaoConfig.paleteAltura,
        z0: e.z - pz, z1: e.z + pz,
        cor: selecionado
            ? Color.lerp(_corMadeira, Colors.white, 0.30)!
            : _corMadeira);

    if (!e.ocupado) return;

    const bx = BarracaoConfig.bagX / 2;
    const bz = BarracaoConfig.bagZ / 2;
    final cor = corBagBarracao(
      produtoCodigo:   e.produtoCodigo,
      corPorProduto:   corPorProduto,
      destacadoCodigo: destacadoCodigo,
    );
    _caixa(faces,
        x0: e.x - bx, x1: e.x + bx,
        y0: BarracaoConfig.paleteAltura,
        y1: BarracaoConfig.paleteAltura + BarracaoConfig.bagAltura,
        z0: e.z - bz, z1: e.z + bz,
        // Seleção clareia o bag e mantém a cor do produto legível por baixo —
        // a mesma escolha do cubo selecionado no galpão.
        cor: selecionado ? Color.lerp(cor, Colors.white, 0.30)! : cor);
  }

  /// Caixa alinhada aos eixos: 5 faces (topo + 4 laterais). O fundo não é
  /// desenhado — a câmera está sempre acima do piso.
  static void _caixa(
    List<Face> faces, {
    required double x0, required double x1,
    required double y0, required double y1,
    required double z0, required double z1,
    required Color cor,
    Color? corTopo,
  }) {
    faces.add(Face([
      Vec3(x0, y1, z0), Vec3(x0, y1, z1), Vec3(x1, y1, z1), Vec3(x1, y1, z0),
    ], corTopo ?? cor));
    faces.add(Face([
      Vec3(x0, y0, z1), Vec3(x1, y0, z1), Vec3(x1, y1, z1), Vec3(x0, y1, z1),
    ], cor));
    faces.add(Face([
      Vec3(x1, y0, z0), Vec3(x0, y0, z0), Vec3(x0, y1, z0), Vec3(x1, y1, z0),
    ], cor));
    faces.add(Face([
      Vec3(x1, y0, z1), Vec3(x1, y0, z0), Vec3(x1, y1, z0), Vec3(x1, y1, z1),
    ], cor));
    faces.add(Face([
      Vec3(x0, y0, z0), Vec3(x0, y0, z1), Vec3(x0, y1, z1), Vec3(x0, y1, z0),
    ], cor));
  }

  /// Grade do piso, no plano y = 0 e dentro das paredes. Fica fora da lista de
  /// faces de propósito: a câmera está sempre acima do chão, então o piso é
  /// sempre a superfície mais ao fundo e pode ser desenhado antes de tudo, sem
  /// entrar no sort — o que também evita z-fighting com os estrados dos
  /// paletes, que apoiam exatamente em y = 0.
  static List<(Vec3, Vec3)> get linhasDoPiso {
    final linhas = <(Vec3, Vec3)>[];
    const x0 = BarracaoConfig.interiorX0, x1 = BarracaoConfig.interiorX1;
    const z0 = BarracaoConfig.interiorZ0, z1 = BarracaoConfig.interiorZ1;
    for (var x = x0; x <= x1 + 1e-6; x += _ladoGrade) {
      linhas.add((Vec3(x, 0, z0), Vec3(x, 0, z1)));
    }
    for (var z = z0; z <= z1 + 1e-6; z += _ladoGrade) {
      linhas.add((Vec3(x0, 0, z), Vec3(x1, 0, z)));
    }
    return linhas;
  }

  /// Os quatro cantos do piso, para o preenchimento chapado por baixo da
  /// grade.
  static const List<Vec3> cantosDoPiso = [
    Vec3(BarracaoConfig.interiorX0, 0, BarracaoConfig.interiorZ0),
    Vec3(BarracaoConfig.interiorX1, 0, BarracaoConfig.interiorZ0),
    Vec3(BarracaoConfig.interiorX1, 0, BarracaoConfig.interiorZ1),
    Vec3(BarracaoConfig.interiorX0, 0, BarracaoConfig.interiorZ1),
  ];
}

// ── BarracaoPainter ──────────────────────────────────────────────────────────

class BarracaoPainter extends CustomPainter {
  final Camera camera;

  /// Os endereços cadastrados, como vieram do banco. É a lista que decide
  /// quantos paletes existem — a cena não sabe contar paletes sozinha.
  final List<EnderecoBarracao> enderecos;

  /// Cor de cada produto (categoria do estoque_mestre), na convenção das
  /// outras cenas. Produto sem cor conhecida cai no cinza.
  final Map<String, Color> corPorProduto;

  /// Endereço selecionado (id da linha), ou null sem seleção.
  final int? selecionadoId;

  /// Produto destacado pela busca: TODOS os paletes com este código acendem em
  /// laranja CAMDA. É o código que manda, não o endereço — a pergunta que a
  /// busca responde é "onde está este produto", que raramente tem uma resposta
  /// só.
  final String? destacadoCodigo;

  /// Rótulo de cada palete pintado no chão ao lado dele.
  final bool mostrarEtiquetas;

  BarracaoPainter(
    this.camera, {
    this.enderecos        = const [],
    this.corPorProduto    = const {},
    this.selecionadoId,
    this.destacadoCodigo,
    this.mostrarEtiquetas = true,
  });

  /// Menor tamanho de fonte que ainda é rótulo, e não sujeira no chão.
  static const double _fonteMinima = 7.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _corFundo);

    final proj = ProjecaoCamera(camera, size);
    _desenharPiso(canvas, proj);
    // Etiquetas ANTES dos volumes: elas são pintura no chão, então um palete
    // mais perto da câmera deve cobri-las — como as faixas pintadas de um
    // estacionamento. Mesma escolha do galpão.
    if (mostrarEtiquetas) _desenharEtiquetas(canvas, proj);

    final codigoAceso =
        (destacadoCodigo?.isEmpty ?? true) ? null : destacadoCodigo;
    final faces = BarracaoGeometry.buildFaces(
      enderecos,
      corPorProduto:   corPorProduto,
      selecionadoId:   selecionadoId,
      destacadoCodigo: codigoAceso,
    );
    proj.projetarFaces(faces);
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    _desenharFacesEContornos(canvas, faces, proj, codigoAceso);
  }

  void _desenharPiso(Canvas canvas, ProjecaoCamera proj) {
    final chao = Path();
    var primeiro = true;
    for (final canto in BarracaoGeometry.cantosDoPiso) {
      final hit = proj.projetar(canto);
      if (hit == null) return; // canto atrás da câmera: piso inteiro pulado
      if (primeiro) {
        chao.moveTo(hit.$1.dx, hit.$1.dy);
        primeiro = false;
      } else {
        chao.lineTo(hit.$1.dx, hit.$1.dy);
      }
    }
    chao.close();
    canvas.drawPath(chao, Paint()..color = _corPiso);

    // Todas as linhas num Path só: é um draw call, não uma centena.
    final grade = Path();
    for (final (a, b) in BarracaoGeometry.linhasDoPiso) {
      final pa = proj.projetar(a);
      final pb = proj.projetar(b);
      if (pa == null || pb == null) continue;
      grade.moveTo(pa.$1.dx, pa.$1.dy);
      grade.lineTo(pb.$1.dx, pb.$1.dy);
    }
    canvas.drawPath(
        grade,
        Paint()
          ..color       = _corPisoGrade
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 0.8);
  }

  /// Faces e contornos numa fila só, do mais longe para o mais perto.
  ///
  /// Os contornos NÃO podem ser um passe depois das faces: eles marcam paletes
  /// espalhados pelas quatro fileiras, e desenhados por cima o do fundo
  /// riscava o bag da frente — o barracão virava uma teia de arame flutuando
  /// sobre a carga. Entram então na mesma fila de profundidade das faces, pelo
  /// mesmo mecanismo com que o mapa da loja intercala os bonecos: cada
  /// contorno espera até que todas as faces mais distantes que ele tenham sido
  /// pintadas.
  ///
  /// Em que ponto da fila cada contorno entra está em [_contornos] — depende
  /// de ele ser uma marca (que tem de ser vista) ou o arame ambiente de um
  /// palete livre.
  void _desenharFacesEContornos(Canvas canvas, List<Face> faces,
      ProjecaoCamera proj, String? codigoAceso) {
    final preenchimento = Paint();
    final contorno = Paint()
      ..color       = _corContorno
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    final pendentes = _contornos(proj, codigoAceso)
      ..sort((a, b) => b.depth.compareTo(a.depth));
    var proximo = 0;

    void pintarContornosAte(double depth) {
      while (proximo < pendentes.length && pendentes[proximo].depth > depth) {
        canvas.drawPath(pendentes[proximo].path, pendentes[proximo].traco);
        proximo++;
      }
    }

    for (final f in faces) {
      if (f.proj.length < 3) continue;
      pintarContornosAte(f.depth);
      final path = Path()..moveTo(f.proj[0].dx, f.proj[0].dy);
      for (var i = 1; i < f.proj.length; i++) {
        path.lineTo(f.proj[i].dx, f.proj[i].dy);
      }
      path.close();
      preenchimento.color = Color.lerp(Colors.black, f.color, f.light)!;
      canvas.drawPath(path, preenchimento);
      canvas.drawPath(path, contorno);
    }
    pintarContornosAte(double.negativeInfinity);
  }

  /// Contorno do volume da carga: laranja CAMDA no endereço selecionado,
  /// âmbar claro nos acesos pela busca e um traço fraco no palete livre — que
  /// é onde uma carga nova entraria. Palete ocupado e sem nenhuma das duas
  /// marcas não ganha contorno: o bag já é o volume, e mais um traço em cada
  /// um dos 100 endereços seria ruído.
  List<({double depth, Path path, Paint traco})> _contornos(
      ProjecaoCamera proj, String? codigoAceso) {
    final selecionado = Paint()
      ..color       = corCamdaBarracao
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final aceso = Paint()
      ..color       = _corDestaqueBorda
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final livre = Paint()
      ..color       = _corVazio
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final lista = <({double depth, Path path, Paint traco})>[];
    for (final e in enderecos) {
      final sel = e.id == selecionadoId;
      final destacado =
          codigoAceso != null && e.produtoCodigo == codigoAceso;
      if (!sel && !destacado && e.ocupado) continue;

      final contorno = _contornoDaCarga(proj, e);
      if (contorno == null) continue;
      lista.add((
        // Onde o contorno entra na fila depende do que ele é.
        //
        // MARCA (selecionado, ou aceso pela busca): tem de ser vista, então
        // entra pelo canto mais PRÓXIMO — depois das faces do próprio bag,
        // que senão comeriam o traço. Uma marca dessas é uma resposta a algo
        // que a pessoa acabou de pedir; cobri-la é pior que o risco de ela
        // passar por cima de um vizinho.
        //
        // ARAME do palete livre: é ambiente, e entra pelo canto mais
        // DISTANTE. Foi o que tirou da tela o arame de um palete do fundo
        // riscando a carga da fileira da frente — os dois se sobrepõem na
        // projeção, e o livre não tem bag nenhum de si para vencer.
        depth: (sel || destacado) ? contorno.perto : contorno.longe,
        path:  contorno.path,
        traco: sel ? selecionado : (destacado ? aceso : livre),
      ));
    }
    return lista;
  }

  /// Contorno das arestas verticais e do topo do volume da carga (o bag, ou o
  /// espaço dele num palete livre), projetado, com a profundidade do canto
  /// mais próximo e a do mais distante — quem chama escolhe (ver [_contornos]).
  ({double perto, double longe, Path path})? _contornoDaCarga(
      ProjecaoCamera proj, EnderecoBarracao e) {
    const bx = BarracaoConfig.bagX / 2;
    const bz = BarracaoConfig.bagZ / 2;
    const y0 = BarracaoConfig.paleteAltura;
    const y1 = BarracaoConfig.paleteAltura + BarracaoConfig.bagAltura;

    final cantos = <(double, double)>[
      (e.x - bx, e.z - bz),
      (e.x + bx, e.z - bz),
      (e.x + bx, e.z + bz),
      (e.x - bx, e.z + bz),
    ];

    final topo = <Offset>[];
    final base = <Offset>[];
    var perto = double.infinity;
    var longe = double.negativeInfinity;
    for (final (x, z) in cantos) {
      final a = proj.projetar(Vec3(x, y1, z));
      final b = proj.projetar(Vec3(x, y0, z));
      if (a == null || b == null) return null;
      topo.add(a.$1);
      base.add(b.$1);
      perto = math.min(perto, math.min(a.$2, b.$2));
      longe = math.max(longe, math.max(a.$2, b.$2));
    }

    final path = Path()..moveTo(topo[0].dx, topo[0].dy);
    for (var i = 1; i < topo.length; i++) {
      path.lineTo(topo[i].dx, topo[i].dy);
    }
    path.close();
    for (var i = 0; i < topo.length; i++) {
      path.moveTo(topo[i].dx, topo[i].dy);
      path.lineTo(base[i].dx, base[i].dy);
    }
    return (perto: perto, longe: longe, path: path);
  }

  /// Tamanho do texto de uma etiqueta a [cz] centímetros da câmera.
  ///
  /// A referência é a distância ATUAL da câmera, não uma constante — mesma
  /// conta do galpão, e pelo mesmo motivo: assim a etiqueta nasce com o
  /// tamanho de projeto no enquadramento inicial (que depende do tamanho da
  /// tela) e cresce quando o usuário aproxima.
  double _tamanhoTexto(double base, double cz) =>
      base * (camera.dist / cz).clamp(0.5, 2.2);

  /// Largura em PIXELS que um palete ocupa na tela, medida no ponto do
  /// rótulo. Null quando alguma das pontas está atrás da câmera.
  double? _larguraProjetada(ProjecaoCamera proj, double x, double z) {
    const meio = BarracaoConfig.paleteX / 2;
    final a = proj.projetar(Vec3(x - meio, 1, z));
    final b = proj.projetar(Vec3(x + meio, 1, z));
    if (a == null || b == null) return null;
    return (b.$1 - a.$1).distance;
  }

  void _desenharEtiquetas(Canvas canvas, ProjecaoCamera proj) {
    final margem =
        Rect.fromLTWH(-40, -40, proj.larguraPx + 80, proj.alturaPx + 80);

    for (final e in enderecos) {
      // Do lado do corredor (Z menor): é de lá que a empilhadeira chega, e
      // quem anda no corredor precisa ler o rótulo de onde está.
      final zRotulo = e.z - BarracaoConfig.paleteZ / 2 - 12;
      final hit = proj.projetar(Vec3(e.x, 1, zRotulo));
      if (hit == null) continue;
      final (tela, cz) = hit;
      if (!margem.contains(tela)) continue;

      final fontSize = _tamanhoTexto(9.0, cz);
      if (fontSize < _fonteMinima) continue;

      final tp = TextPainter(
        text: TextSpan(
          text: e.rotulo,
          style: TextStyle(
            color: e.id == selecionadoId ? corCamdaBarracao : _corRotulo,
            fontSize:   fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      // No barracão inteiro na tela, 25 paletes por fileira dividem a largura
      // do celular em fatias de uns 15 px — e 'BAR-100' em 9 px não cabe em
      // 15. Sem esta guarda os rótulos viravam uma tarja ilegível de letras
      // sobrepostas, que é pior que rótulo nenhum. O galpão não precisa dela
      // porque tem o filtro de rua; aqui quem separa os rótulos é o zoom, e
      // eles aparecem sozinhos quando há espaço para lê-los. O selecionado é
      // exceção: ele é a resposta a um toque que a pessoa acabou de dar.
      final largura = _larguraProjetada(proj, e.x, zRotulo);
      if (e.id != selecionadoId &&
          (largura == null || tp.width > largura)) {
        continue;
      }
      tp.paint(canvas, tela - Offset(tp.width / 2, tp.height / 2));
    }

    // Rótulo de cada abertura, escrito no chão logo dentro do vão: é a
    // referência que orienta quem procura um endereço ("o portão fica no meio,
    // a porta menor à esquerda").
    for (final abertura in BarracaoConfig.aberturas) {
      final hit = proj.projetar(Vec3(
        abertura.centroX,
        1,
        BarracaoConfig.espessuraParede + 55,
      ));
      if (hit == null) continue;
      final (tela, cz) = hit;
      if (!margem.contains(tela)) continue;

      final fontSize = _tamanhoTexto(11.0, cz);
      if (fontSize < _fonteMinima) continue;

      final tp = TextPainter(
        text: TextSpan(
          text: abertura.rotulo,
          style: TextStyle(
            color:         _corRotulo,
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
  bool shouldRepaint(BarracaoPainter old) =>
      old.camera.rotY      != camera.rotY      ||
      old.camera.rotX      != camera.rotX      ||
      old.camera.dist      != camera.dist      ||
      old.camera.target.x  != camera.target.x  ||
      old.camera.target.y  != camera.target.y  ||
      old.camera.target.z  != camera.target.z  ||
      old.selecionadoId    != selecionadoId    ||
      old.destacadoCodigo  != destacadoCodigo  ||
      old.mostrarEtiquetas != mostrarEtiquetas ||
      !identical(old.enderecos, enderecos)     ||
      !identical(old.corPorProduto, corPorProduto);
}

// ── BarracaoScene ────────────────────────────────────────────────────────────

class BarracaoScene extends StatefulWidget {
  final List<EnderecoBarracao> enderecos;
  final Map<String, Color>     corPorProduto;
  final int?                   selecionadoId;
  final String?                destacadoCodigo;
  final bool                   mostrarEtiquetas;

  /// Toque num palete, ou null quando o toque caiu fora de qualquer alvo — é
  /// o gesto de desfazer a seleção.
  final ValueChanged<EnderecoBarracao?>? onTapEndereco;

  const BarracaoScene({
    super.key,
    this.enderecos        = const [],
    this.corPorProduto    = const {},
    this.selecionadoId,
    this.destacadoCodigo,
    this.mostrarEtiquetas = true,
    this.onTapEndereco,
  });

  /// Câmera isométrica olhando DE FRENTE para a parede das aberturas, com os
  /// 35 m enquadrados numa tela de [size].
  ///
  /// O enquadramento é calculado, não chutado — é a mesma derivação do galpão
  /// (ver GalpaoScene.enquadrar). Para um ponto p, com a = p − alvo e o olho
  /// em alvo + dir·dist, `dot(a, right)` e `dot(a, up)` NÃO dependem de dist
  /// (right e up são perpendiculares a dir) e `dot(a, fwd)` vale
  /// `dot(a, fwd)|dist=0 + dist`. A condição de caber na tela,
  /// |dot(a,up)| ≤ tan(fov/2)·profundidade, vira então
  ///
  ///   dist ≥ |dot(a, up)| ÷ tan(fov/2) − dot(a, fwd)
  ///
  /// (e o análogo em right, com o aspecto). É exata em perspectiva: o termo
  /// −dot(a, fwd) é o que faz os cantos MAIS PRÓXIMOS da câmera, que a
  /// perspectiva joga para fora da tela, pedirem mais distância que os do
  /// fundo.
  ///
  /// O azimute e a elevação vêm de [BarracaoConfig] — é lá que está escrito
  /// por que o olho cai do lado de fora da parede da frente.
  static Camera enquadrar(Size size) {
    const rotY = BarracaoConfig.rotYPadrao;
    const rotX = BarracaoConfig.rotXPadrao;
    final env  = BarracaoConfig.envelope;
    final a    = BarracaoConfig.alvoCamera;
    final alvo = Vec3(a.x, a.y, a.z);

    final cosX = math.cos(rotX);
    final dir  = Vec3(math.sin(rotY) * cosX, math.sin(rotX),
        math.cos(rotY) * cosX); // olho = alvo + dir · dist
    final fwd   = (dir * -1).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;

    final tanH   = math.tan(ProjecaoCamera.fovY / 2);
    final aspect = size.height <= 0 ? 1.0 : size.width / size.height;

    var dist = _distMin;
    for (final cx in [env.minX, env.maxX]) {
      for (final cy in [env.minY, env.maxY]) {
        for (final cz in [env.minZ, env.maxZ]) {
          final d = Vec3(cx, cy, cz) - alvo;
          final aoFundo  = d.dot(fwd);
          final precisaH = d.dot(right).abs() / (tanH * aspect) - aoFundo;
          final precisaV = d.dot(up).abs() / tanH - aoFundo;
          dist = math.max(dist, math.max(precisaH, precisaV));
        }
      }
    }
    // Folga pequena: a conta acima já é exata para os cantos do envelope, e
    // esta margem é só para as etiquetas do chão, que ficam do lado de fora
    // dos paletes da ponta.
    return Camera(
        rotY: rotY, rotX: rotX, dist: dist * 1.06, target: alvo);
  }

  /// Limites de zoom e de deslocamento, em CENTÍMETROS (ver a nota de unidade
  /// no topo do arquivo). O pan é preso ao envelope com uma folga: sem isso um
  /// arrasto longo joga o barracão para fora da tela e não há como voltar.
  static const double _distMin  = 300;
  static const double _distMax  = 9000;
  static const double _folgaPan = 600;

  @override
  State<BarracaoScene> createState() => _BarracaoSceneState();
}

class _BarracaoSceneState extends State<BarracaoScene>
    with SceneGestureGuard<BarracaoScene> {
  // Só é conhecida quando a tela tem tamanho (o enquadramento depende da
  // proporção), então nasce nula e é resolvida no primeiro build.
  Camera? _camera;
  Camera? _cameraAoIniciarGesto;

  final _painterKey = GlobalKey();

  // Mesmo ajuste do galpão: os alvos aqui são volumes de mais de 1 m e o
  // gesto dominante da tela é girar a câmera, então exige-se o dedo firme.
  @override
  double get limiarDeArrasto => 9.0;

  @override
  Duration? get duracaoMaximaDoToque => const Duration(milliseconds: 600);

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
      // Dois dedos: orbita + zoom, como nas outras cenas.
      setState(() {
        _camera = Camera(
          rotY: c0.rotY - delta.dx * 0.006,
          // O piso do giro é mais alto que o das outras cenas de propósito. A
          // parede das aberturas tem 6 m e o salão só 10 m de profundidade:
          // abaixo de ~0,55 rad ela cobre o barracão inteiro, e a pessoa fica
          // olhando para um paredão sem entender que basta subir a câmera.
          rotX: (c0.rotX + delta.dy * 0.006).clamp(0.55, 1.45),
          dist: (c0.dist / d.scale)
              .clamp(BarracaoScene._distMin, BarracaoScene._distMax),
          target: c0.target,
        );
      });
    } else {
      // Um dedo: pan — o ponto do chão acompanha o dedo.
      final rb = _painterKey.currentContext?.findRenderObject() as RenderBox?;
      final hPx = rb?.size.height ?? 600.0;
      final porPx = 2 * c0.dist * math.tan(ProjecaoCamera.fovY / 2) / hPx;
      final inclinacao = math.max(math.sin(c0.rotX), 0.35);

      final dx = delta.dx * porPx;
      final dz = delta.dy * porPx / inclinacao;
      final env = BarracaoConfig.envelope;

      setState(() {
        _camera = Camera(
          rotY: c0.rotY,
          rotX: c0.rotX,
          dist: c0.dist,
          target: Vec3(
            (c0.target.x - math.cos(c0.rotY) * dx - math.sin(c0.rotY) * dz)
                .clamp(env.minX - BarracaoScene._folgaPan,
                    env.maxX + BarracaoScene._folgaPan),
            c0.target.y,
            (c0.target.z + math.sin(c0.rotY) * dx - math.cos(c0.rotY) * dz)
                .clamp(env.minZ - BarracaoScene._folgaPan,
                    env.maxZ + BarracaoScene._folgaPan),
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
    widget.onTapEndereco
        ?.call(_hitTest(camera, rb.globalToLocal(toqueGlobal), rb.size));
  }

  /// O palete sob o toque, ou null se o raio não acerta nenhum.
  ///
  /// O alvo é o volume INTEIRO da carga — estrado mais a altura do bag —
  /// mesmo no palete livre: é por ele que se lança carga, exatamente como o
  /// contorno da vaga do galpão, e mirar num estrado de 15 cm num barracão de
  /// 35 m seria mira de precisão, não toque.
  EnderecoBarracao? _hitTest(Camera camera, Offset toque, Size size) {
    final eye   = camera.position;
    final fwd   = (camera.target - eye).normalized;
    final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
    final up    = right.cross(fwd).normalized;
    final tanH   = math.tan(ProjecaoCamera.fovY / 2);
    final aspect = size.width / size.height;

    final ndcX = 2 * toque.dx / size.width - 1;
    final ndcY = 1 - 2 * toque.dy / size.height;
    final dir =
        (right * (ndcX * tanH * aspect) + up * (ndcY * tanH) + fwd).normalized;

    const hx = BarracaoConfig.paleteX / 2;
    const hz = BarracaoConfig.paleteZ / 2;

    EnderecoBarracao? melhor;
    var melhorT = double.infinity;

    for (final e in widget.enderecos) {
      final t = _rayAabb(eye, dir,
          x0: e.x - hx, x1: e.x + hx,
          y0: 0,        y1: BarracaoConfig.alturaCarga,
          z0: e.z - hz, z1: e.z + hz);
      if (t != null && t < melhorT) {
        melhorT = t;
        melhor  = e;
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
        final camera = _camera ??= BarracaoScene.enquadrar(constraints.biggest);

        return Listener(
          onPointerDown: aoEncostarDedo,
          onPointerUp: (e) {
            if (aoSoltarDedo(e)) _tryHitTest(pontoDoToque!);
          },
          onPointerCancel: aoSoltarDedo,
          child: GestureDetector(
            onScaleStart:  _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            child: CustomPaint(
              key: _painterKey,
              painter: BarracaoPainter(
                camera,
                enderecos:        widget.enderecos,
                corPorProduto:    widget.corPorProduto,
                selecionadoId:    widget.selecionadoId,
                destacadoCodigo:  widget.destacadoCodigo,
                mostrarEtiquetas: widget.mostrarEtiquetas,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}
