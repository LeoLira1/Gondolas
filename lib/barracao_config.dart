// ─────────────────────────────────────────────────────────────────────────────
// Configuração do BARRACÃO da CAMDA — a ÚNICA fonte da geometria
// ─────────────────────────────────────────────────────────────────────────────
//
// O barracão é um galpão de alvenaria simples: um retângulo de 35 m × 10 m com
// pé-direito de 6 m, sem racks e sem pilha. A unidade de armazenagem é o
// PALETE de madeira apoiado no chão, com um bag de 1000 kg em cima — e cada
// palete é UM endereço, com UM produto. Não há nível, não há ordem na pilha:
// o endereço é o próprio palete, e por isso ele nunca renumera (a lição que
// moldou o galpão, ver galpao_config.dart, aqui simplesmente não se aplica).
//
// ATENÇÃO À UNIDADE. O barracão inteiro — a planta desta tabela, as colunas
// pos_x/pos_z no Turso e as coordenadas do mundo 3D da cena — trabalha em
// CENTÍMETROS, que é a unidade em que a obra foi medida. A loja e o galpão
// trabalham em metros. Isso não colide em lugar nenhum porque o renderizador
// (Vec3/Camera/ProjecaoCamera de gondola_scene.dart) é adimensional e as três
// cenas nunca dividem coordenada: cada uma monta a sua câmera a partir do seu
// próprio envelope. O que NÃO pode acontecer é misturar as duas unidades
// dentro do barracão — é por isso que não há conversão nenhuma aqui.
//
//   Planta (vista de cima, X para a direita, Z para o fundo):
//
//     z = 1000  ┌───────────────────────────────────────────────┐  parede cheia
//               │                                               │
//               │   ▤ ▤ ▤ ▤ ▤ ▤ ▤ ▤ ▤ … 25 paletes por fileira  │
//               │   ▤ ▤ ▤ ▤ ▤ ▤ ▤ ▤ ▤ …                         │
//               │   ▤ ▤ ▤ ▤ ▤ ▤ ▤ ▤ ▤ …  4 fileiras             │
//               │   ▤ ▤ ▤ ▤ ▤ ▤ ▤ ▤ ▤ …                         │
//               │                                               │
//               │        corredor de manobra da empilhadeira    │
//     z = 0     └────┤PORTA├──────┤ PORTÃO ├──────┤PORTA├───────┘
//                x = 0                                    x = 3500
//
// As aberturas ficam TODAS na parede de 35 m em Z = 0; as outras três são
// cheias.

import 'dart:math' as math;

/// Tipo de abertura da parede da frente — muda só as medidas do vão, e é o
/// que o rótulo da cena mostra.
enum TipoAbertura { porta, portao }

/// Uma abertura na parede da frente (Z = 0), em centímetros.
///
/// [x0]/[x1] são as bordas ao longo de X e [altura] é o vão livre; acima dele
/// vai VERGA (parede) até o pé-direito — ver [BarracaoConfig.vergas].
class AberturaBarracao {
  final TipoAbertura tipo;
  final double x0, x1;
  final double altura;

  const AberturaBarracao({
    required this.tipo,
    required this.x0,
    required this.x1,
    required this.altura,
  });

  double get largura => x1 - x0;
  double get centroX => (x0 + x1) / 2;

  String get rotulo => tipo == TipoAbertura.portao ? 'PORTÃO' : 'PORTA';
}

/// Um trecho cheio de parede, em centímetros: a caixa [x0..x1] × [y0..y1] no
/// plano da parede. Serve tanto para os panos entre as aberturas (y0 = 0)
/// quanto para as vergas acima delas (y0 = altura do vão).
class TrechoParede {
  final double x0, x1, y0, y1;

  const TrechoParede({
    required this.x0,
    required this.x1,
    required this.y0,
    required this.y1,
  });

  double get largura => x1 - x0;
  double get altura  => y1 - y0;
}

/// Um endereço de palete no chão do barracão: o retângulo onde o palete se
/// apoia, com o rótulo etiquetado nele.
///
/// A posição é o CENTRO do palete, em centímetros. Não guarda produto nem
/// quantidade: isso é ocupação, vive na tabela `barracao_enderecos` e chega
/// pela camada de serviço (ver barracao_service.dart).
class PosicaoBarracao {
  /// Rótulo do endereço, contínuo no barracão inteiro: 'BAR-01', 'BAR-02', …
  final String rotulo;

  /// Centro do palete no chão, em centímetros.
  final double x, z;

  /// Fileira (0 = a encostada na parede do fundo) e coluna (0 = a de menor X)
  /// — derivadas do layout, guardadas só para orientar quem lê a planta.
  final int fileira, coluna;

  const PosicaoBarracao({
    required this.rotulo,
    required this.x,
    required this.z,
    required this.fileira,
    required this.coluna,
  });
}

/// Estrutura fixa do barracão: medidas da obra, aberturas e o layout PADRÃO
/// dos paletes.
///
/// O layout daqui é a SEMENTE da tabela `barracao_enderecos`, não a verdade
/// corrente: quantos paletes existem no barracão é dado que muda (entram e
/// saem conforme a carga), então quem desenha lê o banco, nunca esta classe.
/// Ver a nota em [posicoesPadrao].
class BarracaoConfig {
  // ── Obra (centímetros) ─────────────────────────────────────────────────────

  /// Comprimento no eixo X — a parede das aberturas tem esta medida.
  static const double largura = 3500;

  /// Profundidade no eixo Z: da parede das aberturas (Z = 0) à do fundo.
  static const double profundidade = 1000;

  /// Pé-direito.
  static const double peDireito = 600;

  /// Espessura de qualquer parede.
  static const double espessuraParede = 20;

  /// Faces INTERNAS do barracão — é o retângulo em que os paletes cabem, e o
  /// que o corredor de manobra mede.
  static const double interiorX0 = espessuraParede;
  static const double interiorX1 = largura - espessuraParede;
  static const double interiorZ0 = espessuraParede;
  static const double interiorZ1 = profundidade - espessuraParede;

  // ── Aberturas (todas na parede Z = 0) ──────────────────────────────────────

  /// Sequência ao longo de X, da esquerda para a direita, de quem está de
  /// frente para a parede. Entre elas e nas pontas há parede cheia — os panos
  /// são DERIVADOS daqui ([panosDaFrente]), nunca escritos à mão: assim mexer
  /// numa abertura não deixa um pano velho para trás.
  static const List<AberturaBarracao> aberturas = [
    AberturaBarracao(
        tipo: TipoAbertura.porta,  x0: 600,  x1: 800,  altura: 300),
    AberturaBarracao(
        tipo: TipoAbertura.portao, x0: 1300, x1: 1800, altura: 450),
    AberturaBarracao(
        tipo: TipoAbertura.porta,  x0: 2300, x1: 2500, altura: 300),
  ];

  /// Os panos cheios da parede da frente, do chão ao pé-direito: o que sobra
  /// de [largura] depois de tirar as [aberturas]. Sai em ordem de X.
  static List<TrechoParede> get panosDaFrente {
    final panos = <TrechoParede>[];
    var x = 0.0;
    for (final a in aberturas) {
      if (a.x0 > x) {
        panos.add(TrechoParede(x0: x, x1: a.x0, y0: 0, y1: peDireito));
      }
      x = a.x1;
    }
    if (x < largura) {
      panos.add(TrechoParede(x0: x, x1: largura, y0: 0, y1: peDireito));
    }
    return panos;
  }

  /// A verga de cada abertura: parede do topo do vão até o pé-direito.
  static List<TrechoParede> get vergas => [
        for (final a in aberturas)
          TrechoParede(x0: a.x0, x1: a.x1, y0: a.altura, y1: peDireito),
      ];

  // ── Palete e bag (centímetros) ─────────────────────────────────────────────

  /// Palete de madeira: 120 (X) × 100 (Z), 15 de altura.
  static const double paleteX = 120;
  static const double paleteZ = 100;
  static const double paleteAltura = 15;

  /// Bag de 1000 kg em cima do palete: 100 (X) × 85 (Z), 130 de altura.
  static const double bagX = 100;
  static const double bagZ = 85;
  static const double bagAltura = 130;

  /// Altura do conjunto palete + bag — o teto do volume que recebe o toque.
  static const double alturaCarga = paleteAltura + bagAltura;

  // ── Layout padrão dos paletes ──────────────────────────────────────────────

  /// Passo entre paletes vizinhos ao longo de X: 120 do palete + 15 de folga.
  static const double passoX = 135;

  /// Passo entre fileiras no eixo Z: 100 do palete + 20 de folga.
  static const double passoZ = 120;

  /// Corredor de manobra da empilhadeira: espaço livre exigido entre a face
  /// interna da parede das aberturas e a fileira mais à frente.
  static const double corredorManobra = 400;

  /// Quantas fileiras cabem entre a parede do fundo e o corredor de manobra.
  ///
  /// As fileiras começam ENCOSTADAS na parede do fundo e avançam para a
  /// frente; a última só é válida enquanto a borda dianteira dela deixa
  /// [corredorManobra] livre até a parede das aberturas.
  static int get fileiras {
    final disponivel =
        interiorZ1 - paleteZ - (interiorZ0 + corredorManobra);
    if (disponivel < 0) return 0;
    return 1 + (disponivel / passoZ).floor();
  }

  /// Quantos paletes cabem numa fileira, entre as duas paredes laterais.
  static int get colunas {
    final disponivel = (interiorX1 - interiorX0) - paleteX;
    if (disponivel < 0) return 0;
    return 1 + (disponivel / passoX).floor();
  }

  /// Z do centro da fileira [i] (0 = a encostada na parede do fundo).
  static double zDaFileira(int i) => interiorZ1 - paleteZ / 2 - i * passoZ;

  /// X do centro da coluna [j], com a grade CENTRADA entre as laterais: a
  /// sobra que não fecha um passo inteiro vira folga igual dos dois lados, em
  /// vez de uma faixa larga só na direita.
  static double xDaColuna(int j) {
    final ocupado = paleteX + (colunas - 1) * passoX;
    final margem  = ((interiorX1 - interiorX0) - ocupado) / 2;
    return interiorX0 + margem + paleteX / 2 + j * passoX;
  }

  /// Espaço livre entre a fileira mais à frente e a face interna da parede
  /// das aberturas. Existe para o teste cobrar o corredor de manobra sem
  /// refazer a conta do layout.
  static double get corredorLivre =>
      (zDaFileira(fileiras - 1) - paleteZ / 2) - interiorZ0;

  /// Rótulo do endereço de índice [i] (0-based), na sequência CONTÍNUA do
  /// barracão inteiro: BAR-01, BAR-02, … BAR-100. Não reinicia por fileira —
  /// o rótulo é o endereço, e um 'BAR-03' em duas fileiras seriam dois
  /// lugares com o mesmo nome.
  ///
  /// Duas casas é o piso, não o teto: acima de 99 o número simplesmente
  /// cresce (BAR-100), em vez de truncar.
  static String rotuloDoIndice(int i) =>
      'BAR-${(i + 1).toString().padLeft(2, '0')}';

  /// O layout PADRÃO: fileiras paralelas à parede do fundo, começando nela e
  /// avançando para a frente, numeradas continuamente da fileira do fundo
  /// para a da frente e, dentro de cada uma, da esquerda para a direita.
  ///
  /// É SEMENTE, não verdade corrente. Quem desenha o barracão lê
  /// `barracao_enderecos` no Turso (ver BarracaoService), porque o número de
  /// paletes muda com a operação — tirar um palete do chão não pode exigir
  /// uma versão nova do app. Esta lista só é usada para popular a tabela na
  /// primeira vez que o barracão abre num banco vazio.
  static List<PosicaoBarracao> get posicoesPadrao {
    final lista = <PosicaoBarracao>[];
    for (var fileira = 0; fileira < fileiras; fileira++) {
      for (var coluna = 0; coluna < colunas; coluna++) {
        lista.add(PosicaoBarracao(
          rotulo:  rotuloDoIndice(lista.length),
          x:       xDaColuna(coluna),
          z:       zDaFileira(fileira),
          fileira: fileira,
          coluna:  coluna,
        ));
      }
    }
    return lista;
  }

  // ── Envelope (para enquadrar a câmera e prender o pan) ─────────────────────

  /// Caixa que contém o barracão inteiro, paredes e pé-direito incluídos.
  static ({double minX, double maxX, double minY, double maxY,
           double minZ, double maxZ}) get envelope => (
        minX: 0, maxX: largura,
        minY: 0, maxY: peDireito,
        minZ: 0, maxZ: profundidade,
      );

  /// Ponto para onde a câmera padrão olha: o meio do salão, na altura em que
  /// a carga e a parede se equilibram no quadro.
  static ({double x, double y, double z}) get alvoCamera => (
        x: largura / 2,
        y: peDireito / 2,
        z: profundidade / 2,
      );

  /// Azimute da câmera padrão: de FRENTE para a parede das aberturas.
  ///
  /// O olho fica em `alvo + dir · dist`, com
  /// `dir.z = cos(rotY) · cos(rotX)` (ver [Camera.position] em
  /// gondola_scene.dart). Para o olho cair do lado de fora da parede da
  /// frente — que está em Z = 0, ou seja, em Z MENOR que o alvo —, cos(rotY)
  /// tem de ser negativo: daí o π. O desvio de 0,16 rad é o mesmo truque do
  /// galpão: dá volume às caixas sem jogar os 35 m na diagonal da tela.
  static const double rotYPadrao = math.pi + 0.16;

  /// Elevação da câmera padrão. Alta o bastante para a vista passar POR CIMA
  /// da parede de 6 m e alcançar a primeira fileira de paletes: a sombra
  /// geométrica da parede cobre `peDireito / tan(rotX)` ≈ 458 cm atrás dela,
  /// e o corredor de manobra ([corredorManobra], 400 cm) mais a meia-folga do
  /// layout deixam a fileira da frente 500 cm adentro — do lado de fora dessa
  /// sombra. Um teste cobra os dois números juntos.
  static const double rotXPadrao = 0.92;
}
