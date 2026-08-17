import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'palete_registry.dart';

/// Face 1-6 da gôndola derivada da posição (px, pz) da caixa na prateleira.
/// Face 1 = voltada para a entrada (+Z), numeração horária vista de cima.
/// A face não é persistida no Turso — é sempre derivada de pos_x/pos_z.
int faceFromPos(double px, double pz) {
  final ang = math.atan2(pz, px) * 180 / math.pi;   // graus
  var k = (((90 - ang) / 60).round()) % 6;
  if (k < 0) k += 6;
  return k + 1;
}

// ─────────────────────────────────────────────────────────────────────────────
// Esquema de labels (letras) das posições de produto nas estantes
// ─────────────────────────────────────────────────────────────────────────────
//
// Estantes 3 e 4 ficam fisicamente coladas uma na outra, então usam uma
// sequência de letras estendida e sem repetição entre as duas: a Estante 3
// vai de A a O (15 posições) e a Estante 4 continua de onde a 3 parou,
// de P a AD (mais 15 posições). As demais estantes continuam reaproveitando
// A, B, C... cada uma com seu próprio alfabeto, como sempre.
const int          numColunasEstante         = 3;
const int          niveisProdutoPadrao       = 4;
const int          niveisProdutoEstendido    = 5;
const Set<int>     estantesComLabelEstendido = {3, 4};

// A Estante 8 é a EDR-300 de aço (coluna única, 6 prateleiras), diferente
// das estantes de madeira. A contagem de níveis precisa acompanhar a
// Edr300Geometry para as buscas apontarem o nível certo.
const int estanteEdr300Num    = 8;
const int niveisProdutoEdr300 = 6;

// A Estante 6 é, no espaço físico, a junção de 3 EDR-300 encostadas lado a
// lado (era desenhada como estante de madeira 3×4). No app ela segue sendo
// UMA estante — número 6, uma parada do carrossel — desenhada como 3 módulos
// de aço: coluna = módulo físico (0 = esquerdo), 6 níveis por módulo como na
// Estante 8. As letras são contínuas por módulo, de cima pra baixo — A–F no
// módulo esquerdo, G–L no do meio, M–R no direito — pra etiqueta de cada
// módulo ler igual à da 8 (ver letraEstanteCelula). Endereços antigos da
// grade de madeira (níveis 0–3) continuam válidos no banco, mas apontam para
// letras novas: o recadastro é feito estante a estante, como na parede.
const int estanteEdr300TriplaNum = 6;
const int colunasEdr300Tripla    = 3;

bool ehEstanteEdr300(int estanteNum) =>
    estanteNum == estanteEdr300Num || estanteNum == estanteEdr300TriplaNum;

// O Expositor MagnoJet (painel canaletado com ganchos) reutiliza a infra de
// estantes: local_tipo 'estante', número próprio, coluna = coluna do gancho,
// nivel = linha do gancho, slot sempre 0 (um produto por gancho).
const int expositorMagnojetNum     = 9;
const int colunasExpositorMagnojet = 4;
const int linhasExpositorMagnojet  = 6;

// Chegaram mais produtos e o painel ganhou ganchos NOVOS intercalados entre
// os primários (A–X): em cada vão entre duas colunas primárias entra um
// gancho, então são colunasExpositorMagnojet - 1 ganchos extras por linha.
// Pra NÃO invalidar os endereços A–X já salvos no Turso, os intercalados
// entram como colunas NOVAS, após as primárias — colunas
// colunasExpositorMagnojet .. colunasTotalMagnojet-1. Cada intercalado k
// mora no vão à direita da coluna primária k, e é rotulado com a letra dessa
// primária + "1" (A1 à direita de A, B1 à direita de B, …). A base (1–5)
// segue intocada no nível nivelBaseMagnojet.
const int colunasIntercaladasMagnojet =
    colunasExpositorMagnojet - 1;                              // 3
const int colunasTotalMagnojet =
    colunasExpositorMagnojet + colunasIntercaladasMagnojet;    // 7

// A base do Expositor MagnoJet também recebe produtos: 5 caixas apoiadas no
// pé do expositor, rotuladas com números 1–5 (como as bases do Nellore e do
// Monitor). Para não invalidar os endereços dos ganchos já salvos no Turso
// (níveis 0–5), a base entra como um nível NOVO acima da faixa existente:
// nivel = linhasExpositorMagnojet (6), coluna 0–4, slot 0.
const int nivelBaseMagnojet   = linhasExpositorMagnojet;
const int colunasBaseMagnojet = 5;

// O Expositor Nellore Isoflex/Avant (estrutura amarela com painel slatwall)
// também reutiliza a infra de estantes: local_tipo 'estante', número próprio,
// slot sempre 0. São 24 endereços nos níveis 1–5 com colunas variando por
// nível (conforme o expositor real da loja): níveis 1–2 = prateleiras
// (5 espaços cada), nível 3 = cestos bin (4 cestos), níveis 4–5 = ganchos
// (5 por fileira). Letras contínuas de cima pra baixo: A–E e F–J nos
// ganchos, K–N nos cestos, O–S e T–X nas prateleiras.
//
// O nível 0 era a base (deck, rotulada 1–4), mas a estante real não tem
// essa prateleira — a base SAIU dos endereços. O índice 0 não foi
// reaproveitado (os níveis 1–5 mantêm o significado dos dados salvos) e
// linhas antigas de nível 0 no Turso são ignoradas na carga e na busca.
const int expositorNelloreNum     = 19;
const int colunasExpositorNellore = 5;   // máximo (ganchos e prateleiras)
const int niveisExpositorNellore  = 6;

/// Colunas de cada nível do Expositor Nellore: base e cestos têm 4,
/// ganchos e prateleiras têm 5.
int colunasNivelNellore(int nivel) => (nivel == 0 || nivel == 3) ? 4 : 5;

// O Expositor Monitor Produtos Agropecuários (escalonado: laterais amarelas
// com frente inclinada e prateleiras com profundidade crescente de cima pra
// baixo) também reutiliza a infra de estantes: local_tipo 'estante', número
// próprio, slot sempre 0. São 20 endereços em 4 níveis × 5 colunas — atenção:
// 5 colunas, diferente dos outros expositores que usam 4. Nível 0 = base
// (deck, o mais fundo, rotulada 1–5); níveis 1–3 = prateleiras com letras
// contínuas de cima pra baixo: A–E (nível 3, superior), F–J (nível 2, média),
// K–O (nível 1, inferior).
const int expositorMonitorNum     = 20;
const int colunasExpositorMonitor = 5;
const int niveisExpositorMonitor  = 4;

// O Balcão de Atendimento (7,95 m × 1,10 m, encostado no corredor da parede
// esquerda) ganha número na mesma sequência das estruturas só para o mapa
// saber desenhá-lo: ele NÃO tem endereços de produto e por isso fica fora de
// ordemNavegacaoEstantes, de niveisProdutoPara e de numColunasPara. O número
// 21 está reservado a ele de qualquer forma, para não ser reaproveitado por
// uma estante futura que sim teria endereços.
const int balcaoNum = 21;

// A Estante Parede é uma peça física única (prateleiras verdes flutuantes
// fixadas na parede) dividida em 6 seções iguais de 2 posições, modeladas
// como as estantes 13 a 18. Ela entrou no lugar das antigas estantes 3 e 4,
// que saíram da navegação (os números 3 e 4 não são reutilizados para não
// colidir com dados antigos no banco). Cada seção: 2 colunas × 6 níveis de
// produto (nível 0 = base, 1..5 = prateleiras).
const int      estanteParedeMin    = 13;
const int      estanteParedeMax    = 18;
const Set<int> estantesParede      = {13, 14, 15, 16, 17, 18};
const int      niveisProdutoParede = 6;
const int      colunasParede       = 2;

bool ehEstanteParede(int estanteNum) =>
    estanteNum >= estanteParedeMin && estanteNum <= estanteParedeMax;

// Paletes de madeira do piso (1,20 m × 1,00 m, 15 posições em grade 5 × 3).
// Diferente das estantes e expositores, o número de paletes na loja é VARIÁVEL:
// eles são cadastrados em runtime na tabela `paletes` e lidos pelo
// PaleteRegistry, então não existe const listando cada um — só a faixa de
// números reservada. Números começam em 101 para não colidir com nenhuma
// estante/expositor existente, e nunca são reciclados: palete que sai da loja
// vira ativo = 0 na tabela (nunca DELETE), senão o número voltaria e herdaria
// os endereços velhos em estoque_localizado (mesma lição das estantes 3 e 4,
// ver estantesRemovidas). Reutilizam a infra de estante como os expositores:
// local_tipo 'estante', número próprio, slot sempre 0.
const int paleteNumMin     = 101;
const int colunasPalete    = 5;   // posições na frente (1,20 m ÷ 5 = 24 cm)
const int fileirasPalete   = 3;   // posições na profundidade (1,00 m ÷ 3 ≈ 33 cm)

bool ehPalete(int estanteNum) => estanteNum >= paleteNumMin;

/// Rótulo curto de uma estrutura, do jeito que ela é etiquetada na loja:
/// "G7", "E5", "P101". Paletes reutilizam local_tipo 'estante' no banco, mas
/// nunca são apresentados como estante ao usuário.
String rotuloCurtoEstrutura(String tipo, int numero) => tipo == 'gondola'
    ? 'G$numero'
    : ehPalete(numero)
        ? 'P$numero'
        : 'E$numero';

/// "1 produto" / "3 produtos" — contagem já flexionada.
///
/// Existe porque os banners de conferência moram SOBRE os mapas: cada
/// caractere gasto num "(s)" é mapa coberto, e um banner que cresce esconde
/// justamente a estrutura que ele manda conferir. [plural] cobre os poucos
/// casos em que o plural não é só um 's' ("posição" → "posições").
String pluralizar(int n, String singular, [String? plural]) =>
    '$n ${n == 1 ? singular : (plural ?? '${singular}s')}';

/// Nome por extenso da estrutura: "Gôndola 7", "Estante 5", "Palete 101".
String nomeEstrutura(String tipo, int numero) => tipo == 'gondola'
    ? 'Gôndola $numero'
    : ehPalete(numero)
        ? 'Palete $numero'
        : 'Estante $numero';

/// Posição global P1–P12 da parede — derivada, nunca persistida (mesma
/// filosofia do faceFromPos): cada seção contribui com 2 posições.
int posicaoGlobalParede(int estanteNum, int coluna) =>
    (estanteNum - estanteParedeMin) * colunasParede + coluna + 1;

/// Parte FIXA da ordem de navegação do carrossel de estantes. As seções da
/// parede (13–18) ocupam o lugar onde ficavam as estantes 3 e 4.
const List<int> ordemNavegacaoBase = [
  1, 2, 13, 14, 15, 16, 17, 18, 5, 6, 7, 8, 9, 10, 11, 12, 19, 20,
];

/// Ordem completa do carrossel: a base fixa seguida dos paletes ativos
/// (ordenados por número), no fim — depois dos expositores 19 e 20. É um
/// getter, não const, porque paletes são cadastrados em runtime; a lista é
/// remontada a cada leitura para refletir cadastros/desativações sem
/// reiniciar o app.
List<int> get ordemNavegacaoEstantes =>
    [...ordemNavegacaoBase, ...PaleteRegistry().ativos.map((p) => p.num)];

/// Estantes que saíram da loja (substituídas pela Estante Parede). As linhas
/// antigas delas continuam no Turso, mas esses endereços não aparecem mais em
/// busca nem em conferência — o produto deve ser recadastrado na parede.
const Set<int> estantesRemovidas = {3, 4};

bool temNivelTopoPara(int estanteNum) =>
    estantesComLabelEstendido.contains(estanteNum);

// O palete é testado PRIMEIRO aqui e em numColunasPara: é uma comparação de
// faixa só (>= paleteNumMin), enquanto o resto da cadeia compara número por
// número contra cada expositor. Fica como guarda antes da cadeia, e não como
// mais um ternário dentro dela, porque palete não é "mais um expositor": é a
// única família cujo conjunto de números cresce em runtime.
int niveisProdutoPara(int estanteNum) {
  if (ehPalete(estanteNum)) return fileirasPalete;
  return ehEstanteEdr300(estanteNum)
    ? niveisProdutoEdr300
    : estanteNum == expositorMagnojetNum
        ? linhasExpositorMagnojet + 1   // ganchos (0–5) + base (6)
        : estanteNum == expositorNelloreNum
            ? niveisExpositorNellore
            : estanteNum == expositorMonitorNum
                ? niveisExpositorMonitor
                : ehEstanteParede(estanteNum)
                    ? niveisProdutoParede
                    : temNivelTopoPara(estanteNum)
                        ? niveisProdutoEstendido
                        : niveisProdutoPadrao;
}

/// Número de colunas de uma estante — usado pra clampar/nomear a coluna
/// encontrada numa busca sem estourar a grade real da estrutura.
int numColunasPara(int estanteNum) {
  if (ehPalete(estanteNum)) return colunasPalete;
  return estanteNum == estanteEdr300Num
    ? 1
    : estanteNum == estanteEdr300TriplaNum
        ? colunasEdr300Tripla
        : estanteNum == expositorMagnojetNum
            ? colunasTotalMagnojet  // máx: ganchos primários+intercalados (7) > base (5)
            : estanteNum == expositorNelloreNum
                ? colunasExpositorNellore
                : estanteNum == expositorMonitorNum
                    ? colunasExpositorMonitor
                    : ehEstanteParede(estanteNum)
                        ? colunasParede
                        : numColunasEstante;
}

/// Offset (0-based) somado ao índice local (linha × colunas + coluna) antes
/// de converter para letra. Só a Estante 4 precisa de offset, para continuar
/// a sequência da Estante 3 (que tem 15 posições: 5 níveis × 3 colunas).
/// A Estante Parede não passa por aqui: usa endereços numéricos próprios
/// (ver letraEstanteCelula).
int letraOffsetPara(int estanteNum) =>
    estanteNum == 4 ? niveisProdutoPara(3) * numColunasEstante : 0;

/// Converte um índice 0-based em rótulo estilo planilha: A, B, ..., Z, AA,
/// AB, ..., AD... Suporta labels de mais de uma letra sem truncar.
String letraDoIndice(int index) {
  var n = index + 1;
  var s = '';
  while (n > 0) {
    n--;
    s = String.fromCharCode(0x41 + n % 26) + s;
    n ~/= 26;
  }
  return s;
}

/// Letra da posição de uma célula (coluna, nível) de uma estante — mesma
/// convenção usada no desenho da estante (linhas contadas de cima pra baixo).
/// A Estante 8 (EDR-300) é coluna única, então usa nColunas=1 e offset 0.
/// A Estante 6 (3 EDR-300 lado a lado) usa letras contínuas POR MÓDULO,
/// de cima pra baixo dentro de cada coluna: A–F, G–L, M–R.
/// A Estante Parede usa NÚMEROS contínuos (1..72) em vez de letras, contados
/// de cima pra baixo dentro de cada coluna, coluna esquerda antes da direita,
/// seção 13 antes da 14... — igual à numeração física etiquetada na loja
/// (E13: 1–6 e 7–12; E14: 13–24; ...; E18: 61–72).
String letraEstanteCelula(int estanteNum, int coluna, int nivel) {
  // No palete a grade é HORIZONTAL, então a contagem não é de cima pra baixo
  // como nas estantes: fileira 0 é a do corredor (frente), fileira 2 é a do
  // fundo, e dentro de cada fileira a coluna 0 é a da esquerda. Resulta em
  // 1–5 na frente, 6–10 no meio, 11–15 no fundo — igual à etiqueta física no
  // chão. Rótulos numéricos, não letras, como as bases do Nellore/Monitor/
  // MagnoJet e a Estante Parede.
  if (ehPalete(estanteNum)) {
    return '${nivel * colunasPalete + coluna + 1}';
  }
  final nNiveis  = niveisProdutoPara(estanteNum);
  if (ehEstanteParede(estanteNum)) {
    final numero = (estanteNum - estanteParedeMin) * nNiveis * colunasParede +
        coluna * nNiveis + (nNiveis - 1 - nivel) + 1;
    return '$numero';
  }
  // Na Estante 6 cada coluna é um módulo EDR-300 físico, então as letras
  // correm de cima pra baixo dentro do módulo (como a etiqueta da Estante 8)
  // e continuam no módulo seguinte: esquerdo A–F, meio G–L, direito M–R.
  if (estanteNum == estanteEdr300TriplaNum) {
    return letraDoIndice(coluna * nNiveis + (nNiveis - 1 - nivel));
  }
  // No Expositor Nellore as letras dos níveis 1–5 são contínuas de cima pra
  // baixo com o nº de colunas variando por nível: A–E e F–J (ganchos), K–N
  // (cestos), O–S e T–X (prateleiras). O nível 0 (base, saiu dos endereços)
  // segue numérico só pra dados antigos não ganharem letra de outro nível.
  if (estanteNum == expositorNelloreNum) {
    if (nivel == 0) return '${coluna + 1}';
    var offset = 0;
    for (var n = niveisExpositorNellore - 1; n > nivel; n--) {
      offset += colunasNivelNellore(n);
    }
    return letraDoIndice(offset + coluna);
  }
  // No Expositor Monitor a base (nível 0) usa números 1–5; as prateleiras
  // (níveis 1–3) usam letras contínuas de cima pra baixo: A–E (superior),
  // F–J (média), K–O (inferior).
  if (estanteNum == expositorMonitorNum) {
    if (nivel == 0) return '${coluna + 1}';
    final row = niveisExpositorMonitor - 1 - nivel;
    return letraDoIndice(row * colunasExpositorMonitor + coluna);
  }
  // No Expositor MagnoJet a base (nível nivelBaseMagnojet) usa números 1–5;
  // os ganchos primários (colunas 0–3, níveis 0–5) seguem com as letras A–X de
  // cima pra baixo. Os ganchos intercalados (colunas 4–6) herdam a letra da
  // primária à esquerda + "1": A1 à direita de A, E1 à direita de E, …
  if (estanteNum == expositorMagnojetNum) {
    if (nivel == nivelBaseMagnojet) return '${coluna + 1}';
    final row = linhasExpositorMagnojet - 1 - nivel;
    if (coluna < colunasExpositorMagnojet) {
      return letraDoIndice(row * colunasExpositorMagnojet + coluna);
    }
    final primariaVizinha = coluna - colunasExpositorMagnojet;
    return '${letraDoIndice(row * colunasExpositorMagnojet + primariaVizinha)}1';
  }
  final nColunas = numColunasPara(estanteNum);
  final offset   =
      estanteNum == estanteEdr300Num ? 0 : letraOffsetPara(estanteNum);
  final row      = nNiveis - 1 - nivel;
  return letraDoIndice(offset + row * nColunas + coluna);
}

// Cor própria do Modo Conferência (Fase 3) — ciano CAMDA, para não conflitar
// visualmente com o pulsar laranja da busca nem com o badge âmbar de
// endereço desatualizado (Fase 2).
const Color corConferenciaCiano = Color(0xFF22d3ee);

/// Valor de `local_tipo` dos endereços do galpão em estoque_localizado.
///
/// A tabela é COMPARTILHADA com os apps irmãos (dashboard, inventariocamda,
/// camda-estoque): é dela que saem o total do inventário cíclico e o Modo
/// Conferência. O galpão entra nela como um terceiro tipo, ao lado de
/// 'gondola' e 'estante' — com local_num = número da posição (1–78),
/// face_ou_coluna = 0 (o galpão não tem face nem coluna) e andar_ou_nivel =
/// ordem na pilha.
///
/// ATENÇÃO: os números de posição do galpão (1–78) SE SOBREPÕEM aos números
/// de estante (1–21) e de palete (101+). Qualquer agrupamento de
/// estoque_localizado tem de levar o local_tipo na chave, nunca só o
/// local_num — foi assim que o galpão passou a somar quantidade dentro da
/// estante de mesmo número.
const String localTipoGalpao = 'galpao';

/// Chave que identifica unicamente um endereço físico + produto, usada para
/// casar linhas de estoque_localizado com o conjunto de endereços
/// desatualizados (Fase 2 — aviso de endereço desatualizado).
String chaveEnderecoEstoque({
  required String produtoCodigo,
  required String localTipo,
  required int localNum,
  required int faceOuColuna,
  required int andarOuNivel,
}) => '$produtoCodigo|$localTipo|$localNum|$faceOuColuna|$andarOuNivel';

/// Cor cinza dos produtos sem cor conhecida (fora do catálogo, categoria sem
/// cor cadastrada, ou `cor_hex` inválido vindo do banco).
const Color corProdutoDesconhecido = Color(0xFF888888);

// Memo do parse de hex. São ~9 cores distintas em toda a loja (8 categorias +
// o cinza), mas `corDeHex` é chamada uma vez por produto ao montar o mapa de
// cores da cena — com o catálogo inteiro isso era um `int.parse` por produto,
// a cada vez. O mapa cresce no máximo até o número de hexes distintos que o
// banco tiver, então não precisa de limite nem de expiração.
final Map<String, Color> _memoCores = {};

/// Converte `#rrggbb` (ou `rrggbb`) na [Color] opaca correspondente,
/// memoizando o resultado. Hex malformado devolve [corProdutoDesconhecido] —
/// antes um `cor_hex` inválido no banco estourava dentro do `build()`.
Color corDeHex(String hex) => _memoCores.putIfAbsent(hex, () {
      final limpo = hex.startsWith('#') ? hex.substring(1) : hex;
      // O comprimento tem de ser conferido: 'FF' + '' ainda é um hex válido
      // (255), e sairia como azul transparente em vez de cair no cinza.
      if (limpo.length != 6) return corProdutoDesconhecido;
      final valor = int.tryParse('FF$limpo', radix: 16);
      return valor == null ? corProdutoDesconhecido : Color(valor);
    });

/// Mapa código → cor para a cena pintar as caixas, combinando as duas fontes.
///
/// [doLayout] vem do `cor_hex` gravado nas próprias linhas de
/// `gondola_layout`/`estante_layout` — chega junto com o layout, então serve
/// para pintar já no primeiro frame, sem esperar o catálogo. [catalogo] vem do
/// `estoque_mestre` e vence quando o produto existe nele: o `cor_hex` da linha
/// foi gravado A PARTIR do catálogo no momento do save, então os dois só
/// discordam se a categoria do produto mudou desde então — e aí o certo é a
/// categoria de agora.
Map<String, Color> mesclarCores(
  Map<String, Color> doLayout,
  List<Produto> catalogo,
) {
  final cores = <String, Color>{...doLayout};
  for (final p in catalogo) {
    cores[p.codigo] = p.cor;
  }
  return cores;
}

class Produto {
  final String codigo;
  final String nome;
  final String categoria;
  final String corHex;

  const Produto({
    required this.codigo,
    required this.nome,
    required this.categoria,
    required this.corHex,
  });

  Color get cor => corDeHex(corHex);
}

/// Produtos com caixa num local (gôndola ou estante) para o dialog
/// "Limpar produto". Mantém a ordem do catálogo para os cadastrados e
/// acrescenta, ao final e ordenados por código, os que não estão no catálogo
/// carregado (produto sem cadastro, zerado no sistema ou catálogo ainda não
/// sincronizado) sintetizados só com o código. Sem isso, uma caixa cujo
/// produto não está no catálogo fica presa na prateleira sem opção de
/// exclusão, mesmo continuando visível no local.
List<Produto> produtosComCaixa({
  required Iterable<String> idsComCaixa,
  required List<Produto> catalogo,
}) {
  final ids = idsComCaixa.toSet();
  final produtos = catalogo.where((p) => ids.contains(p.codigo)).toList();
  final noCatalogo = produtos.map((p) => p.codigo).toSet();
  final avulsos = ids.difference(noCatalogo).toList()..sort();
  produtos.addAll(avulsos.map((id) => Produto(
        codigo:    id,
        nome:      id,
        categoria: '',
        corHex:    '#888888',
      )));
  return produtos;
}

class CaixaLayout {
  final int gondolaNum;
  final int andar;
  final String produtoCodigo;
  final String produtoNome;
  final double posX;
  final double posZ;
  final String corHex;

  const CaixaLayout({
    required this.gondolaNum,
    required this.andar,
    required this.produtoCodigo,
    required this.produtoNome,
    required this.posX,
    required this.posZ,
    required this.corHex,
  });
}

class ProdutoEncontrado {
  final String nome;
  final String tipo;            // 'gondola' ou 'estante'
  final int    numero;
  final String nivelDescricao;  // texto pronto: "Face 3 · Andar Meio", "Nível 2", etc.
  final String produtoCodigo;
  final int?   face;            // 1-6, derivada de pos_x/pos_z; null para estantes
  final int?   andar;           // 0-2; null para estantes
  final int?   nivel;           // 0-based; null para gôndolas
  final double? quantidade;     // soma em estoque_localizado neste local; null se nunca contado

  const ProdutoEncontrado({
    required this.nome,
    required this.tipo,
    required this.numero,
    required this.nivelDescricao,
    required this.produtoCodigo,
    this.face,
    this.andar,
    this.nivel,
    this.quantidade,
  });

  ProdutoEncontrado comQuantidade(double? quantidade) => ProdutoEncontrado(
        nome:           nome,
        tipo:           tipo,
        numero:         numero,
        nivelDescricao: nivelDescricao,
        produtoCodigo:  produtoCodigo,
        face:           face,
        andar:          andar,
        nivel:          nivel,
        quantidade:     quantidade,
      );
}

class CaixaColocadaEstante {
  final int    coluna;
  final int    nivel;
  final int    slot;
  final String produtoId;

  const CaixaColocadaEstante({
    required this.coluna,
    required this.nivel,
    required this.slot,
    required this.produtoId,
  });
}

class CaixaLayoutEstante {
  final int    estanteNum;
  final int    coluna;
  final int    nivel;
  final int    slot;
  final String produtoCodigo;
  final String produtoNome;
  final String corHex;

  const CaixaLayoutEstante({
    required this.estanteNum,
    required this.coluna,
    required this.nivel,
    required this.slot,
    required this.produtoCodigo,
    required this.produtoNome,
    required this.corHex,
  });
}
