import 'dart:math' as math;
import 'package:flutter/material.dart';

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

// O Expositor MagnoJet (painel canaletado com ganchos) reutiliza a infra de
// estantes: local_tipo 'estante', número próprio, coluna = coluna do gancho,
// nivel = linha do gancho, slot sempre 0 (um produto por gancho).
const int expositorMagnojetNum     = 9;
const int colunasExpositorMagnojet = 4;
const int linhasExpositorMagnojet  = 6;

// O Expositor Nellore Isoflex/Avant (estrutura amarela com painel slatwall)
// também reutiliza a infra de estantes: local_tipo 'estante', número próprio,
// slot sempre 0. São 28 endereços em 6 níveis com colunas variando por nível
// (conforme o expositor real da loja): nível 0 = base (4 espaços, rotulada
// 1–4), níveis 1–2 = prateleiras (5 espaços cada), nível 3 = cestos bin
// (4 cestos), níveis 4–5 = ganchos (5 por fileira). Os níveis 1–5 usam
// letras contínuas de cima pra baixo: A–E e F–J nos ganchos, K–N nos
// cestos, O–S e T–X nas prateleiras.
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

/// Posição global P1–P12 da parede — derivada, nunca persistida (mesma
/// filosofia do faceFromPos): cada seção contribui com 2 posições.
int posicaoGlobalParede(int estanteNum, int coluna) =>
    (estanteNum - estanteParedeMin) * colunasParede + coluna + 1;

/// Ordem de navegação do carrossel de estantes. As seções da parede (13–18)
/// ocupam o lugar onde ficavam as estantes 3 e 4.
const List<int> ordemNavegacaoEstantes = [
  1, 2, 13, 14, 15, 16, 17, 18, 5, 6, 7, 8, 9, 10, 11, 12, 19, 20,
];

/// Estantes que saíram da loja (substituídas pela Estante Parede). As linhas
/// antigas delas continuam no Turso, mas esses endereços não aparecem mais em
/// busca nem em conferência — o produto deve ser recadastrado na parede.
const Set<int> estantesRemovidas = {3, 4};

bool temNivelTopoPara(int estanteNum) =>
    estantesComLabelEstendido.contains(estanteNum);

int niveisProdutoPara(int estanteNum) => estanteNum == estanteEdr300Num
    ? niveisProdutoEdr300
    : estanteNum == expositorMagnojetNum
        ? linhasExpositorMagnojet
        : estanteNum == expositorNelloreNum
            ? niveisExpositorNellore
            : estanteNum == expositorMonitorNum
                ? niveisExpositorMonitor
                : ehEstanteParede(estanteNum)
                    ? niveisProdutoParede
                    : temNivelTopoPara(estanteNum)
                        ? niveisProdutoEstendido
                        : niveisProdutoPadrao;

/// Número de colunas de uma estante — usado pra clampar/nomear a coluna
/// encontrada numa busca sem estourar a grade real da estrutura.
int numColunasPara(int estanteNum) => estanteNum == estanteEdr300Num
    ? 1
    : estanteNum == expositorMagnojetNum
        ? colunasExpositorMagnojet
        : estanteNum == expositorNelloreNum
            ? colunasExpositorNellore
            : estanteNum == expositorMonitorNum
                ? colunasExpositorMonitor
                : ehEstanteParede(estanteNum)
                    ? colunasParede
                    : numColunasEstante;

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
/// A Estante Parede usa NÚMEROS contínuos (1..72) em vez de letras, contados
/// de cima pra baixo dentro de cada coluna, coluna esquerda antes da direita,
/// seção 13 antes da 14... — igual à numeração física etiquetada na loja
/// (E13: 1–6 e 7–12; E14: 13–24; ...; E18: 61–72).
String letraEstanteCelula(int estanteNum, int coluna, int nivel) {
  final nNiveis  = niveisProdutoPara(estanteNum);
  if (ehEstanteParede(estanteNum)) {
    final numero = (estanteNum - estanteParedeMin) * nNiveis * colunasParede +
        coluna * nNiveis + (nNiveis - 1 - nivel) + 1;
    return '$numero';
  }
  // No Expositor Nellore a base (nível 0) usa números 1–4; as letras dos
  // níveis 1–5 são contínuas de cima pra baixo com o nº de colunas variando
  // por nível: A–E e F–J (ganchos), K–N (cestos), O–S e T–X (prateleiras).
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
  final nColunas = numColunasPara(estanteNum);
  final offset   =
      (estanteNum == estanteEdr300Num || estanteNum == expositorMagnojetNum)
          ? 0
          : letraOffsetPara(estanteNum);
  final row      = nNiveis - 1 - nivel;
  return letraDoIndice(offset + row * nColunas + coluna);
}

// Cor própria do Modo Conferência (Fase 3) — ciano CAMDA, para não conflitar
// visualmente com o pulsar laranja da busca nem com o badge âmbar de
// endereço desatualizado (Fase 2).
const Color corConferenciaCiano = Color(0xFF22d3ee);

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

  Color get cor {
    final hex = corHex.replaceFirst('#', '');
    return Color(int.parse('FF$hex', radix: 16));
  }
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
