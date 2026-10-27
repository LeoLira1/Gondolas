import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'galpao_config.dart';
import 'galpao_saldo.dart';
import 'gondola_scene.dart'
    show
        Camera,
        Face,
        Vec3,
        addBadgeEnderecoDesatualizado,
        corEnderecoDivergente,
        corEnderecoDivergentePositiva;
import 'models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Caixa mista da estante: até 5 produtos na mesma caixa, como o rack do galpão
// ─────────────────────────────────────────────────────────────────────────────
//
// Uma caixa de estante é o endereço (coluna, nível, slot). Cada PRODUTO dela é
// uma linha de estante_layout nesse mesmo endereço — a primeira linha é a do
// produto principal, as seguintes são os outros, na ordem em que entraram.
// Assim a busca "onde está", o Modo Conferência e o "Limpar produto", que já
// leem estante_layout linha a linha, enxergam os produtos de uma caixa mista
// sem mudar nada; e um aparelho com o app antigo, que relê e regrava as
// linhas como vieram, não apaga os produtos extras ao salvar.
//
// Com um produto só a caixa é a de sempre (cor da categoria). Do 2º em diante
// ela é desenhada listrada: uma fatia horizontal por produto, de cima para
// baixo na ordem das linhas, pintada pelo saldo do produto — o mesmo
// vermelho/azul do galpão e do Gêmeo, e branco quando fecha com o sistema.

/// Máximo de produtos numa caixa — o MESMO do rack misto do galpão: cinco
/// cabem na lista do celular sem rolar e ainda dá para achar na mão.
const int produtosMaxPorCaixa = GalpaoConfig.produtosMaxPorRack;

/// Fatia de produto que bate com o sistema — o branco dos racks do Gêmeo.
const Color corFatiaOk = Color(0xFFf4f2ed);

/// Filete escuro entre duas fatias (a faixa do rack misto no Gêmeo).
const Color corFileteFatia = Color(0xFF2b2a27);

/// Selo "+N" em cima da caixa mista.
const Color corSeloCaixaMista = Color(0xFFe87722);

/// Estruturas em que uma caixa pode guardar mais de um produto: as que têm
/// vários slots por posição e desenham caixas (estantes de madeira, EDR-300 e
/// Estante Parede). Expositores, paletes, ilha e mostruário têm um produto
/// por endereço por desenho — lá cada produto já tem o seu lugar.
bool estanteAceitaCaixaMista(int estanteNum) =>
    estanteNum != expositorMagnojetNum &&
    estanteNum != expositorNelloreNum &&
    estanteNum != expositorMonitorNum &&
    estanteNum != expositorMadeiraNum &&
    !ehPalete(estanteNum) &&
    !ehIlhaPaletes(estanteNum) &&
    !ehMostruario(estanteNum);

/// Endereço (estante, nível) cuja caixa pode guardar mais de um produto: as
/// estantes de [estanteAceitaCaixaMista] e, nos expositores, os endereços que
/// são caixa — a base do MagnoJet (1–5), as prateleiras e os cestos do
/// Nellore e todos os níveis do Monitor. Ganchos seguem com um produto só
/// (a sacolinha pendurada é do produto), e o Expositor de Madeira também.
bool enderecoAceitaCaixaMista(int estanteNum, int nivel) {
  if (estanteNum == expositorMagnojetNum) return nivel == nivelBaseMagnojet;
  // Nellore: 1–2 = prateleiras, 3 = cestos; 4–5 = ganchos.
  if (estanteNum == expositorNelloreNum) return nivel >= 1 && nivel <= 3;
  if (estanteNum == expositorMonitorNum) return true;
  return estanteAceitaCaixaMista(estanteNum);
}

/// Quantidade gravada em estoque_localizado de [codigo] na posição (estante,
/// coluna, nível) — a chave não tem slot, então é a do produto na posição
/// inteira. Null quando nunca foi contado ali.
double? quantidadeNaPosicao(
  Iterable<Map<String, dynamic>> linhasEstoque, {
  required String codigo,
  required int estanteNum,
  required int coluna,
  required int nivel,
}) {
  double? soma;
  for (final r in linhasEstoque) {
    // A cópia passa por JSON: número pode voltar como double.
    int? n(String k) => (r[k] as num?)?.toInt();
    if (r['produto_codigo'] != codigo ||
        r['local_tipo'] != 'estante' ||
        n('local_num') != estanteNum ||
        n('face_ou_coluna') != coluna ||
        n('andar_ou_nivel') != nivel) {
      continue;
    }
    soma = (soma ?? 0) + ((r['quantidade'] as num?)?.toDouble() ?? 0);
  }
  return soma;
}

/// Uma caixa da estante com seus produtos, na ordem das linhas.
class CaixaEstante {
  final int coluna;
  final int nivel;
  final int slot;
  final List<CaixaColocadaEstante> linhas;

  const CaixaEstante({
    required this.coluna,
    required this.nivel,
    required this.slot,
    required this.linhas,
  });

  bool get mista => linhas.length > 1;
  bool get cheia => linhas.length >= produtosMaxPorCaixa;

  /// Produto principal — o da primeira linha.
  String get principal => linhas.first.produtoId;

  List<String> get codigos => [for (final l in linhas) l.produtoId];

  bool contem(String codigo) => linhas.any((l) => l.produtoId == codigo);

  /// Nome dado à caixa, ou null. Vale o da primeira linha que tiver um: as
  /// linhas da mesma caixa são gravadas com o mesmo nome, mas uma linha
  /// acrescentada por um app antigo chega sem ele.
  String? get nome {
    for (final l in linhas) {
      final n = l.nomeCaixa?.trim();
      if (n != null && n.isNotEmpty) return n;
    }
    return null;
  }

  bool mesmoEndereco(int coluna, int nivel, int slot) =>
      this.coluna == coluna && this.nivel == nivel && this.slot == slot;
}

bool _mesmaCaixa(CaixaColocadaEstante l, int coluna, int nivel, int slot) =>
    l.coluna == coluna && l.nivel == nivel && l.slot == slot;

/// Agrupa as linhas de uma estante em caixas, na ordem em que cada caixa
/// aparece pela primeira vez; dentro da caixa, a ordem das linhas.
List<CaixaEstante> agruparCaixas(Iterable<CaixaColocadaEstante> linhas) {
  final porEndereco = <(int, int, int), List<CaixaColocadaEstante>>{};
  for (final l in linhas) {
    porEndereco.putIfAbsent((l.coluna, l.nivel, l.slot), () => []).add(l);
  }
  return [
    for (final e in porEndereco.entries)
      CaixaEstante(
        coluna: e.key.$1,
        nivel: e.key.$2,
        slot: e.key.$3,
        linhas: List.unmodifiable(e.value),
      ),
  ];
}

/// A caixa no endereço, ou null se o slot está vazio.
CaixaEstante? caixaNoEndereco(
  Iterable<CaixaColocadaEstante> linhas,
  int coluna,
  int nivel,
  int slot,
) {
  final daCaixa = [
    for (final l in linhas)
      if (_mesmaCaixa(l, coluna, nivel, slot)) l,
  ];
  if (daCaixa.isEmpty) return null;
  return CaixaEstante(coluna: coluna, nivel: nivel, slot: slot, linhas: daCaixa);
}

/// Por que um produto não pode entrar numa caixa — ou null se pode. As
/// mesmas frases do rack misto do galpão.
String? motivoParaNaoAdicionar(CaixaEstante caixa, String codigo) {
  if (caixa.contem(codigo)) {
    return 'Esse produto já está nesta caixa — corrija a quantidade dele.';
  }
  if (caixa.cheia) return 'A caixa já tem $produtosMaxPorCaixa produtos.';
  return null;
}

/// As linhas com [codigo] acrescentado no fim da caixa do endereço (que tem
/// de existir), levando o nome da caixa. Não confere limite nem repetição —
/// isso é [motivoParaNaoAdicionar].
List<CaixaColocadaEstante> comProdutoNaCaixa(
  List<CaixaColocadaEstante> linhas,
  CaixaEstante caixa,
  String codigo,
) => [
  ...linhas,
  CaixaColocadaEstante(
    coluna: caixa.coluna,
    nivel: caixa.nivel,
    slot: caixa.slot,
    produtoId: codigo,
    nomeCaixa: caixa.nome,
  ),
];

/// As linhas sem o produto [codigo] da caixa do endereço. Tirar o último
/// produto tira a caixa; com um só que sobra, ela volta a ser caixa comum.
List<CaixaColocadaEstante> semProdutoNaCaixa(
  List<CaixaColocadaEstante> linhas,
  CaixaEstante caixa,
  String codigo,
) => [
  for (final l in linhas)
    if (!(_mesmaCaixa(l, caixa.coluna, caixa.nivel, caixa.slot) &&
        l.produtoId == codigo))
      l,
];

/// As linhas com o nome da caixa trocado em todas as linhas dela. Nome vazio
/// vira null (caixa sem nome).
List<CaixaColocadaEstante> comNomeDaCaixa(
  List<CaixaColocadaEstante> linhas,
  CaixaEstante caixa,
  String? nome,
) {
  final limpo = nome?.trim();
  final novo = (limpo == null || limpo.isEmpty) ? null : limpo;
  return [
    for (final l in linhas)
      _mesmaCaixa(l, caixa.coluna, caixa.nivel, caixa.slot)
          ? l.comNomeCaixa(novo)
          : l,
  ];
}

/// Cor da fatia de um produto da caixa mista pelo saldo dele: vermelho falta
/// endereçar, azul passou do sistema, branco fecha. Sem saldo conhecido
/// (produto fora do estoque_mestre, sem conexão) fica a [corSemSaldo] — a
/// cor da categoria, como o rack do galpão sem saldo.
Color corDaFatia(SaldoProduto? saldo, {required Color corSemSaldo}) {
  if (saldo == null) return corSemSaldo;
  if (saldo.falta) return corEnderecoDivergente;
  if (saldo.sobra) return corEnderecoDivergentePositiva;
  return corFatiaOk;
}

/// Faixas verticais de uma caixa listrada entre [y0] e [y1]: uma fatia por
/// cor, de cima para baixo, com um filete entre duas fatias.
List<({double y0, double y1, Color cor})> fatiasDaCaixa(
  double y0,
  double y1,
  List<Color> cores,
) {
  final n = cores.length;
  if (n == 0) return const [];
  final h = (y1 - y0) / n;
  final filete = math.min(0.004, h * 0.22);
  final faixas = <({double y0, double y1, Color cor})>[];
  for (var i = 0; i < n; i++) {
    final topo = y1 - i * h;
    final ultima = i == n - 1;
    // A última fecha exatamente na base: a conta acumulada deixaria um resto
    // de ponto flutuante entre a fatia e a prateleira.
    final base = ultima ? y0 : topo - h;
    faixas.add((y0: ultima ? base : base + filete, y1: topo, cor: cores[i]));
    if (!ultima) faixas.add((y0: base, y1: base + filete, cor: corFileteFatia));
  }
  return faixas;
}

/// Acrescenta a caixa listrada em [faces], com a mesma régua de caixa de
/// cada cena (as seis faces de um paralelepípedo, como o `_box` delas).
void addCaixaListrada(
  List<Face> faces, {
  required double x0,
  required double x1,
  required double y0,
  required double y1,
  required double z0,
  required double z1,
  required List<Color> cores,
}) {
  for (final f in fatiasDaCaixa(y0, y1, cores)) {
    // O filete fica um tico para dentro: não briga com as faces das fatias.
    final dentro = f.cor == corFileteFatia ? 0.002 : 0.0;
    _caixa(faces,
        x0: x0 + dentro, x1: x1 - dentro,
        y0: f.y0,        y1: f.y1,
        z0: z0 + dentro, z1: z1 - dentro,
        cor: f.cor);
  }
}

void _caixa(
  List<Face> faces, {
  required double x0, required double x1,
  required double y0, required double y1,
  required double z0, required double z1,
  required Color cor,
}) {
  faces.add(Face([Vec3(x0,y1,z0), Vec3(x0,y1,z1), Vec3(x1,y1,z1), Vec3(x1,y1,z0)], cor)); // topo
  faces.add(Face([Vec3(x0,y0,z1), Vec3(x1,y0,z1), Vec3(x1,y1,z1), Vec3(x0,y1,z1)], cor)); // frente
  faces.add(Face([Vec3(x1,y0,z0), Vec3(x0,y0,z0), Vec3(x0,y1,z0), Vec3(x1,y1,z0)], cor)); // fundo
  faces.add(Face([Vec3(x1,y0,z1), Vec3(x1,y0,z0), Vec3(x1,y1,z0), Vec3(x1,y1,z1)], cor)); // direita
  faces.add(Face([Vec3(x0,y0,z0), Vec3(x0,y0,z1), Vec3(x0,y1,z1), Vec3(x0,y1,z0)], cor)); // esquerda
}

/// Selo "+N" de uma caixa mista: ponto (no mundo) acima do meio da frente da
/// caixa e o texto.
typedef SeloCaixa = ({Vec3 ponto, String texto});

SeloCaixa seloDaCaixa({
  required double x0,
  required double x1,
  required double y1,
  required double zFrente,
  required int produtos,
}) => (ponto: Vec3((x0 + x1) / 2, y1 + 0.06, zFrente), texto: '+$produtos');

/// Projeta e desenha os [selos] com a câmera da cena — a mesma conta de
/// projeção dos painters das estantes, que só diferem no [fovGraus].
void desenharSelos(
  Canvas canvas,
  Size size,
  Camera camera,
  List<SeloCaixa> selos, {
  double fovGraus = 45,
}) {
  if (selos.isEmpty) return;
  final eye   = camera.position;
  final fwd   = (camera.target - eye).normalized;
  final right = fwd.cross(const Vec3(0, 1, 0)).normalized;
  final up    = right.cross(fwd).normalized;
  final tanH   = math.tan(fovGraus * math.pi / 180.0 / 2);
  final aspect = size.width / size.height;
  for (final selo in selos) {
    final d  = selo.ponto - eye;
    final cz = d.dot(fwd);
    if (cz <= 0.01) continue;
    final cx = d.dot(right) / (cz * tanH * aspect);
    final cy = d.dot(up)    / (cz * tanH);
    desenharSeloCaixa(
      canvas,
      Offset((cx + 1) / 2 * size.width, (1 - cy) / 2 * size.height),
      cz,
      selo.texto,
    );
  }
}

/// Desenha o selo laranja "+N" já projetado em [centro]; [cz] é a distância
/// da câmera, que escala o selo como os rótulos das cenas.
void desenharSeloCaixa(Canvas canvas, Offset centro, double cz, String texto) {
  final fontSize = 12.0 * (5.0 / cz).clamp(0.5, 1.6);
  final tp = TextPainter(
    text: TextSpan(
      text: texto,
      style: TextStyle(
        color: const Color(0xFF0b0d10),
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = tp.width + fontSize * 0.9;
  final h = fontSize * 1.35;
  final rect = RRect.fromRectAndRadius(
    Rect.fromCenter(center: centro, width: w, height: h),
    Radius.circular(h / 2),
  );
  canvas.drawRRect(rect, Paint()..color = corSeloCaixaMista);
  canvas.drawRRect(
    rect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF0b0d10),
  );
  tp.paint(canvas, centro - Offset(tp.width / 2, tp.height / 2));
}

/// As caixas de [linhas] prontas para a cena: a cor de cada uma (lisa) ou as
/// fatias (mista). Destaque de busca e de conferência pintam a caixa inteira,
/// como numa caixa comum — o destaque é momentâneo e precisa saltar à vista.
({Color? lisa, List<Color>? fatias}) pinturaDaCaixa(
  CaixaEstante caixa, {
  required Color Function(String codigo) corComum,
  required Map<String, SaldoProduto> saldos,
  required Color corCategoria,
  Color? Function(String codigo)? destaque,
}) {
  if (destaque != null) {
    for (final c in caixa.codigos) {
      final d = destaque(c);
      if (d != null) return (lisa: d, fatias: null);
    }
  }
  if (!caixa.mista) return (lisa: corComum(caixa.principal), fatias: null);
  return (
    lisa: null,
    fatias: [
      for (final c in caixa.codigos)
        corDaFatia(saldos[c], corSemSaldo: corCategoria),
    ],
  );
}

/// Volume de uma caixa na cena (o mesmo de `addBoxProduto` de cada uma) e o
/// tamanho do selo âmbar de endereço desatualizado nela.
typedef VolumeCaixa = ({
  double x0, double x1, double y0, double y1, double z0, double z1,
  double tamanhoBadge,
});

/// Monta as caixas de uma estante para a cena: a caixa comum como sempre
/// (pela [caixaLisa] da cena, que já sabe desenhar o badge), a mista listrada
/// no [volume] da cena. Devolve os selos "+N" das mistas.
///
/// As cores seguem a mesma ordem de sempre — conferência, busca, divergência
/// de contagem, categoria —, e na caixa mista o saldo de cada produto pinta a
/// fatia dele (ver [pinturaDaCaixa]).
List<SeloCaixa> montarCaixasDaEstante(
  List<Face> faces, {
  required Iterable<CaixaColocadaEstante> linhas,
  required int estanteNum,
  required Map<String, Color> corPorProduto,
  required Map<String, SaldoProduto> saldos,
  required String? destacadoCodigo,
  required Set<String> destacadosCodigos,
  required Set<String> divergentes,
  required Set<String> divergentesPositivas,
  required Set<String> desatualizados,
  required Color corConferencia,
  required VolumeCaixa? Function(CaixaEstante caixa) volume,
  required void Function(CaixaEstante caixa, Color cor, bool desatualizado)
      caixaLisa,
}) {
  final selos = <SeloCaixa>[];
  for (final caixa in agruparCaixas(linhas)) {
    final v = volume(caixa);
    // Caixa em endereço que não existe mais nesta estante (layout antigo):
    // não desenha.
    if (v == null) continue;
    String chave(String codigo) => chaveEnderecoEstoque(
          produtoCodigo: codigo,
          localTipo:     'estante',
          localNum:      estanteNum,
          faceOuColuna:  caixa.coluna,
          andarOuNivel:  caixa.nivel,
        );
    Color corComum(String codigo) {
      final k = chave(codigo);
      return divergentesPositivas.contains(k)
          ? corEnderecoDivergentePositiva
          : divergentes.contains(k)
              ? corEnderecoDivergente
              : (corPorProduto[codigo] ?? const Color(0xFF888888));
    }
    final pintura = pinturaDaCaixa(
      caixa,
      corComum:     corComum,
      saldos:       saldos,
      corCategoria: corPorProduto[caixa.principal] ?? const Color(0xFF888888),
      destaque: (codigo) => destacadosCodigos.contains(codigo)
          ? corConferencia
          : codigo == destacadoCodigo
              ? corSeloCaixaMista
              : null,
    );
    final desatualizado =
        caixa.codigos.any((c) => desatualizados.contains(chave(c)));
    if (pintura.fatias != null) {
      addCaixaListrada(faces,
          x0: v.x0, x1: v.x1, y0: v.y0, y1: v.y1, z0: v.z0, z1: v.z1,
          cores: pintura.fatias!);
      if (desatualizado) {
        addBadgeEnderecoDesatualizado(faces,
            x1: v.x1, y1: v.y1, z1: v.z1, tamanho: v.tamanhoBadge);
      }
    } else {
      caixaLisa(caixa, pintura.lisa!, desatualizado);
    }
    // Mista com destaque de busca/conferência fica lisa, mas mantém o selo.
    if (caixa.mista) {
      selos.add(seloDaCaixa(
        x0: v.x0, x1: v.x1, y1: v.y1, zFrente: v.z1,
        produtos: caixa.linhas.length,
      ));
    }
  }
  return selos;
}
