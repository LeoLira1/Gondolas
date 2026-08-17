// ─────────────────────────────────────────────────────────────────────────────
// Configuração do galpão de racks — a ÚNICA fonte da geometria
// ─────────────────────────────────────────────────────────────────────────────
//
// O galpão não tem porta-palete: são racks metálicos empilháveis (estrutura de
// aço sobre palete de madeira), e o rack é a própria unidade de armazenagem —
// empilhado direto sobre outro, no máximo 4 de altura.
//
// Duas consequências que moldam TODO o modelo:
//
//  * a POSIÇÃO no chão é fixa e existe sempre, mesmo vazia (a vaga vazia fica
//    no mesmo lugar esperando carga — é informação, não ausência dela);
//  * o NÍVEL não é identidade, é a ordem do rack dentro da pilha. Tirar o rack
//    do nível 1 faz o que estava no 2 PASSAR A SER o nível 1. Por isso nível é
//    sempre calculado a partir da ordem, e nunca gravado como parte de um
//    código de endereço textual (nada de 'GALPAO-52-N3': tal referência vence
//    na primeira movimentação).
//
// A numeração das posições é GLOBAL e contínua de 1 a 78 — não reinicia por
// rua. O endereço exibido é '<número> · N<nível>' (ex.: '52 · N3'); a rua é
// derivada, mostrada só para orientar quem vai buscar.
//
// ATENÇÃO ao mexer aqui: as larguras de corredor embutidas nas coordenadas
// abaixo ainda NÃO foram medidas no galpão — são estimativas. É para isso que
// a tabela inteira vive nesta única constante: trocar as coordenadas quando a
// medição chegar não deve exigir tocar na cena nem na lógica de pilha. Já
// confirmado no galpão: a Rua 2 é fileira simples, e os pares 4/5 e 6/7 estão
// encostados fundo com fundo, sem folga entre eles.

/// Eixo ao longo do qual as posições de uma rua se sucedem.
///
/// Seis das sete ruas correm em Z (o comprimento do galpão); só a Rua 2, no
/// topo do croqui, corre em X.
enum EixoRua { x, z }

/// Uma rua do galpão: uma fileira de posições no chão.
///
/// [primeiroNoFim] resolve o sentido da numeração sem depender de o croqui ser
/// lido na mesma ordem do eixo. Os índices sempre correm do menor para o maior
/// valor do eixo (Z negativo → Z positivo, X negativo → X positivo); quando o
/// primeiro número da rua fica no extremo OPOSTO a esse começo, a bandeira é
/// `true` e a numeração anda de trás para frente. É o que faz a sequência
/// 1 → 36 percorrer o perímetro de forma contínua (sobe pela direita,
/// atravessa o topo para a esquerda, desce pela esquerda) — útil para uma
/// futura rota de separação.
class RuaGalpao {
  /// Número da rua, 1–7, como está etiquetado no galpão.
  final int numero;

  /// Eixo ao longo do qual as posições se sucedem.
  final EixoRua eixo;

  /// Coordenada FIXA da rua: x para as ruas de eixo Z, z para a Rua 2.
  final double coordFixa;

  /// Centro da rua ao longo do seu eixo (zc para eixo Z, xc para eixo X).
  final double centro;

  /// Quantas posições a rua tem.
  final int quantidade;

  /// Número global da primeira posição da rua.
  final int primeiroNumero;

  /// `true` quando a primeira posição fica no extremo de MAIOR coordenada do
  /// eixo (e a numeração desce dali).
  final bool primeiroNoFim;

  /// Para que lado fica o corredor, no eixo perpendicular ao da rua: -1 ou +1.
  /// É o lado onde a etiqueta do número é desenhada — quem anda no corredor
  /// precisa ler o número de onde está, não do lado que encosta no vizinho.
  final int ladoCorredor;

  const RuaGalpao({
    required this.numero,
    required this.eixo,
    required this.coordFixa,
    required this.centro,
    required this.quantidade,
    required this.primeiroNumero,
    required this.primeiroNoFim,
    required this.ladoCorredor,
  });

  /// Número global da última posição da rua.
  int get ultimoNumero => primeiroNumero + quantidade - 1;

  bool contem(int numeroPosicao) =>
      numeroPosicao >= primeiroNumero && numeroPosicao <= ultimoNumero;
}

/// Uma das 78 posições de chão do galpão: a vaga onde uma pilha de até
/// [GalpaoConfig.niveisMax] racks se apoia.
///
/// Não guarda nível nenhum de propósito — o nível é a ordem do rack na pilha,
/// e essa ordem é dado de ocupação, não de estrutura.
class PosicaoGalpao {
  /// Número global 1–78, único no galpão inteiro. É o endereço.
  final int numero;

  /// Rua a que a posição pertence — informação derivada, para orientação.
  final RuaGalpao rua;

  /// Centro da posição no chão, em metros (origem no centro do galpão,
  /// X horizontal, Z profundidade; Z negativo = topo do croqui).
  final double x, z;

  const PosicaoGalpao({
    required this.numero,
    required this.rua,
    required this.x,
    required this.z,
  });

  /// Tamanho da posição no eixo X. O lado de 1,20 m do rack corre ao longo da
  /// rua; nas ruas de eixo Z isso deixa 1,00 m em X, e na Rua 2 é o contrário.
  double get tamanhoX => rua.eixo == EixoRua.z
      ? GalpaoConfig.larguraRack
      : GalpaoConfig.comprimentoRack;

  /// Tamanho da posição no eixo Z (ver [tamanhoX]).
  double get tamanhoZ => rua.eixo == EixoRua.z
      ? GalpaoConfig.comprimentoRack
      : GalpaoConfig.larguraRack;

  /// Ponto no chão onde a etiqueta do número é desenhada: ao lado da posição,
  /// do lado do corredor.
  (double x, double z) get pontoEtiqueta => rua.eixo == EixoRua.z
      ? (x + rua.ladoCorredor * (tamanhoX / 2 + GalpaoConfig.recuoEtiqueta), z)
      : (x, z + rua.ladoCorredor * (tamanhoZ / 2 + GalpaoConfig.recuoEtiqueta));
}

/// Estrutura fixa do galpão: medidas do rack, tabela das ruas e as 78 posições
/// derivadas dela.
class GalpaoConfig {
  // ── Medidas do rack (metros) ───────────────────────────────────────────────

  /// Lado de 1,20 m — corre SEMPRE ao longo da rua.
  static const double comprimentoRack = 1.20;

  /// Lado de 1,00 m — atravessado à rua.
  static const double larguraRack = 1.00;

  /// Altura de um nível de rack.
  static const double alturaNivel = 1.10;

  /// Passo entre posições vizinhas ao longo da rua: rack (1,20) + folga.
  static const double passoPosicao = 1.34;

  /// Passo vertical entre níveis empilhados: altura (1,10) + encaixe.
  static const double passoNivel = 1.16;

  /// Distância entre os centros de duas ruas em par, costas com costas.
  /// Não entra no cálculo das posições (as coordenadas já a embutem): fica
  /// aqui como a medida confirmada no galpão, e um teste garante que os pares
  /// 4/5 e 6/7 continuem obedecendo a ela quando as coordenadas forem
  /// remedidas.
  static const double distanciaParCostas = 1.05;

  /// Máximo de racks empilhados numa posição.
  static const int niveisMax = 4;

  /// Folga entre a borda da posição e a etiqueta do número, no chão.
  static const double recuoEtiqueta = 0.30;

  // ── Tabela das ruas ────────────────────────────────────────────────────────
  //
  // 7 ruas, 78 posições, 312 endereços (78 × 4 níveis).
  //
  //   Rua 1 │  1–14 │ 14 │ fileira simples (lado direito / perímetro)
  //   Rua 2 │ 15–25 │ 11 │ fileira simples, confirmada (topo, na horizontal)
  //   Rua 3 │ 26–36 │ 11 │ fileira simples (lado esquerdo / perímetro)
  //   Rua 4 │ 37–46 │ 10 │ encostada fundo com fundo na Rua 5, confirmado
  //   Rua 5 │ 47–56 │ 10 │ encostada fundo com fundo na Rua 4, confirmado
  //   Rua 6 │ 57–67 │ 11 │ encostada fundo com fundo na Rua 7, confirmado
  //   Rua 7 │ 68–78 │ 11 │ encostada fundo com fundo na Rua 6, confirmado
  static const List<RuaGalpao> ruas = [
    RuaGalpao(
      numero: 1, eixo: EixoRua.z, coordFixa: 8.30, centro: 1.00,
      quantidade: 14, primeiroNumero: 1,
      // Sobe pela direita: o nº 1 fica no extremo Z positivo e a numeração
      // corre até o 14 no extremo Z negativo (topo do croqui).
      primeiroNoFim: true, ladoCorredor: -1,
    ),
    RuaGalpao(
      numero: 2, eixo: EixoRua.x, coordFixa: -9.30, centro: 0.50,
      quantidade: 11, primeiroNumero: 15,
      // Atravessa o topo da direita para a esquerda: nº 15 em X positivo,
      // nº 25 em X negativo.
      primeiroNoFim: true, ladoCorredor: 1,
    ),
    RuaGalpao(
      numero: 3, eixo: EixoRua.z, coordFixa: -7.60, centro: 0,
      quantidade: 11, primeiroNumero: 26,
      // Desce pela esquerda, fechando o perímetro: nº 26 no extremo Z
      // negativo.
      primeiroNoFim: false, ladoCorredor: 1,
    ),
    RuaGalpao(
      numero: 4, eixo: EixoRua.z, coordFixa: -2.90, centro: 0,
      quantidade: 10, primeiroNumero: 37,
      primeiroNoFim: false, ladoCorredor: -1,
    ),
    RuaGalpao(
      numero: 5, eixo: EixoRua.z, coordFixa: -1.85, centro: 0,
      quantidade: 10, primeiroNumero: 47,
      primeiroNoFim: false, ladoCorredor: 1,
    ),
    RuaGalpao(
      numero: 6, eixo: EixoRua.z, coordFixa: 2.60, centro: 0,
      quantidade: 11, primeiroNumero: 57,
      primeiroNoFim: true, ladoCorredor: -1,
    ),
    RuaGalpao(
      numero: 7, eixo: EixoRua.z, coordFixa: 3.65, centro: 0,
      quantidade: 11, primeiroNumero: 68,
      primeiroNoFim: false, ladoCorredor: 1,
    ),
  ];

  /// Total de posições de chão do galpão (contado no galpão: 78).
  static int get totalPosicoes =>
      ruas.fold(0, (soma, r) => soma + r.quantidade);

  /// Total de endereços possíveis: posições × níveis.
  static int get totalEnderecos => totalPosicoes * niveisMax;

  // ── Seed das 78 posições ───────────────────────────────────────────────────

  static List<PosicaoGalpao>? _cachePosicoes;
  static Map<int, PosicaoGalpao>? _cachePorNumero;

  /// As 78 posições, em ordem de número global (1 → 78).
  ///
  /// Memoizada e imutável: a cena, o hit-test e os rótulos pedem esta lista o
  /// tempo todo, e ela é geometria fixa — remontá-la a cada frame seria lixo
  /// puro para o GC (mesmo motivo de `EstanteGeometry.celulasPara`).
  static List<PosicaoGalpao> get posicoes =>
      _cachePosicoes ??= List.unmodifiable(_montarPosicoes());

  /// Posição pelo número global, ou null se fora de 1–78.
  static PosicaoGalpao? porNumero(int numero) {
    final index = _cachePorNumero ??= {
      for (final p in posicoes) p.numero: p,
    };
    return index[numero];
  }

  /// Rua a que um número de posição pertence, ou null se fora de 1–78.
  static RuaGalpao? ruaDe(int numeroPosicao) {
    for (final r in ruas) {
      if (r.contem(numeroPosicao)) return r;
    }
    return null;
  }

  static List<PosicaoGalpao> _montarPosicoes() {
    final lista = <PosicaoGalpao>[];
    for (final rua in ruas) {
      for (var i = 0; i < rua.quantidade; i++) {
        // Deslocamento do índice i em relação ao centro da rua. i = 0 é sempre
        // a ponta de MENOR coordenada do eixo (Z negativo ou X negativo).
        final desloc = (i - (rua.quantidade - 1) / 2) * passoPosicao;
        // Sentido da numeração: ver RuaGalpao.primeiroNoFim.
        final ordinal = rua.primeiroNoFim ? rua.quantidade - 1 - i : i;
        lista.add(PosicaoGalpao(
          numero: rua.primeiroNumero + ordinal,
          rua:    rua,
          x:      rua.eixo == EixoRua.z ? rua.coordFixa : rua.centro + desloc,
          z:      rua.eixo == EixoRua.z ? rua.centro + desloc : rua.coordFixa,
        ));
      }
    }
    lista.sort((a, b) => a.numero.compareTo(b.numero));
    return lista;
  }

  // ── Geometria vertical da pilha ────────────────────────────────────────────

  /// Altura do piso do rack de ordem [ordem] (1 = o de baixo).
  ///
  /// Recebe a ORDEM na pilha, nunca um nível gravado: quem esvazia o rack de
  /// baixo faz o de cima descer, e é a nova ordem que manda.
  static double yBase(int ordem) => (ordem - 1) * passoNivel;

  /// Altura do topo do rack de ordem [ordem].
  static double yTopo(int ordem) => yBase(ordem) + alturaNivel;

  // ── Envelope do galpão (para enquadrar a câmera) ───────────────────────────

  /// Retângulo que contém todas as posições, já com a meia-medida do rack.
  static ({double minX, double maxX, double minZ, double maxZ}) get limites {
    var minX = double.infinity, maxX = double.negativeInfinity;
    var minZ = double.infinity, maxZ = double.negativeInfinity;
    for (final p in posicoes) {
      final hx = p.tamanhoX / 2, hz = p.tamanhoZ / 2;
      if (p.x - hx < minX) minX = p.x - hx;
      if (p.x + hx > maxX) maxX = p.x + hx;
      if (p.z - hz < minZ) minZ = p.z - hz;
      if (p.z + hz > maxZ) maxZ = p.z + hz;
    }
    return (minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ);
  }
}
