import 'estoque_localizado_service.dart';
import 'galpao_saldo.dart' show SaldoProduto;
import 'models.dart' show localTipoGalpao;

// ─────────────────────────────────────────────────────────────────────────────
// Baixa automática do que foi vendido, a partir da contagem
// ─────────────────────────────────────────────────────────────────────────────
//
// O PROBLEMA. O rack fica azul sozinho. Vende-se 30 do Boral, o ERP baixa o
// `qtd_sistema` na planilha do dia seguinte, e os endereços continuam com a
// quantidade de antes da venda — endereçado 100 contra sistema 70. Nada disso
// é erro de ninguém: o app das gôndolas é o único lugar do mundo que sabe em
// QUE rack o produto está, e ninguém vai lá tirar 30 do palete a cada nota
// emitida. O mapa então mente em azul até alguém corrigir rack por rack.
//
// A CORREÇÃO. Quem tem autoridade para dizer quanto existe fisicamente é a
// CONTAGEM — o app `Contagemsimplificada`, que confere a pilha na frente da
// prateleira e grava a confirmação em `contagem_itens` / `estoque_mestre`. No
// instante em que ela é confirmada, a diferença entre o que os endereços
// somam e o que foi contado é exatamente o que saiu e nunca foi baixado: é
// isso que este arquivo retira dos endereços, de um rack ou de vários.
//
// O ALVO É A CONTAGEM, NÃO O SISTEMA. O app de divergências
// (`LeoLira1/Planilha-`) registra o que falta ou sobra por conta de um
// cooperado SEM mexer no `qtd_sistema`: uma falta de 30 lançada para o
// cooperado quer dizer que o sistema tem 100 e o chão tem 70. Baixar contra o
// sistema puro deixaria 30 unidades no rack que não existem na prateleira —
// por isso o alvo é `qtd_sistema + Σ delta das divergências abertas`, que é o
// mesmo número que o app de contagem gravou em `qtd_fisica`. É essa soma que
// amarra os três apps na mesma conta.
//
// O QUE ELA NUNCA FAZ:
//
//  - **Nunca inventa quantidade.** Endereçado MENOR que o contado é carga sem
//    endereço, e só uma pessoa sabe em que rack ela está. O mapa continua
//    vermelho, que é o aviso certo.
//  - **Nunca baixa sem contagem.** Sem uma confirmação em `contagem_itens`
//    não há quem afirme o que existe no chão; a diferença sozinha pode ser
//    tanto venda quanto planilha atrasada.
//  - **Nunca mexe num produto tocado depois da contagem.** Se QUALQUER
//    endereço do produto é mais novo que a contagem, alguém lançou ou
//    corrigiu carga desde então e a contagem já não descreve o mundo — o
//    produto fica de fora inteiro. É essa regra que também torna a baixa
//    idempotente: o endereço que ela grava nasce mais novo que a contagem,
//    então a mesma contagem nunca é aplicada duas vezes. Uma contagem, uma
//    baixa.
//
// Tudo aqui é função pura, sem banco e sem tela: quem lê e grava é o
// [BaixaPorContagemService].

/// O que a contagem afirma sobre um produto — já somando todos os códigos
/// irmãos (ver codigos_vinculados.dart), porque na prateleira existe uma
/// pilha só.
class ContagemDoProduto {
  /// Códigos do produto, normalizados e em ordem. O primeiro é o que
  /// identifica o produto nos resumos.
  final List<String> codigos;

  /// Nome do produto, para a linha do resumo na tela.
  final String nome;

  /// Soma de `estoque_mestre.qtd_sistema` de todos os códigos do grupo.
  final double qtdSistema;

  /// Soma dos `divergencias.delta` abertos do grupo — negativo é falta
  /// (alguém levou e está lançado para um cooperado), positivo é sobra.
  final double deltaDivergencias;

  /// A confirmação de contagem mais recente do grupo, de `contagem_itens`
  /// (app de contagem) ou de `inventario_cicli` (cíclico). Null = o produto
  /// nunca foi conferido, e aí não há baixa a fazer.
  final DateTime? confirmadaEm;

  const ContagemDoProduto({
    required this.codigos,
    required this.nome,
    required this.qtdSistema,
    required this.deltaDivergencias,
    required this.confirmadaEm,
  });

  String get codigo => codigos.isEmpty ? '' : codigos.first;

  /// Quanto os endereços do produto DEVEM somar depois da baixa: o que o
  /// sistema registra, corrigido pelas divergências já lançadas.
  double get alvoEnderecado => qtdSistema + deltaDivergencias;
}

/// Um endereço que perde quantidade: de [qtdAnterior] para [qtdNova].
class AjusteEndereco {
  final EnderecoLocalizado endereco;
  final double qtdAnterior;
  final double qtdNova;

  const AjusteEndereco({
    required this.endereco,
    required this.qtdAnterior,
    required this.qtdNova,
  });

  double get deduzido => qtdAnterior - qtdNova;

  /// True quando o endereço fica zerado. No galpão isso é esvaziar o rack (a
  /// pilha desce); na loja é a prateleira ficar vazia sem perder o endereço.
  bool get esvazia => qtdNova <= SaldoProduto.tolerancia;
}

/// A baixa planejada para um produto — o que seria gravado, antes de gravar.
class PlanoBaixa {
  final ContagemDoProduto contagem;

  /// Soma dos endereços do produto antes da baixa.
  final double enderecadoAntes;

  /// Os endereços que perdem quantidade, na ordem em que serão gravados.
  final List<AjusteEndereco> ajustes;

  /// Excesso que não coube em endereço nenhum. Só acontece com alvo
  /// NEGATIVO — divergência de falta maior que o próprio saldo do sistema,
  /// que é dado inconsistente, não venda. Plano com sobra não é aplicado.
  final double naoCoberto;

  /// Motivo de o produto ter ficado de fora, ou null quando há baixa a
  /// fazer. É o que o resumo mostra em vez de silenciar.
  final MotivoSemBaixa? motivo;

  const PlanoBaixa({
    required this.contagem,
    required this.enderecadoAntes,
    required this.ajustes,
    this.naoCoberto = 0,
    this.motivo,
  });

  double get deduzido =>
      ajustes.fold<double>(0, (soma, a) => soma + a.deduzido);

  double get enderecadoDepois => enderecadoAntes - deduzido;

  /// Quanto ainda falta endereçar depois da baixa (0 quando não falta). É o
  /// vermelho do mapa, e a baixa nunca o resolve sozinha.
  double get faltaEnderecar {
    final falta = contagem.alvoEnderecado - enderecadoAntes;
    return falta > SaldoProduto.tolerancia ? falta : 0;
  }

  /// True quando há o que gravar e nada bloqueando.
  bool get aplicavel =>
      motivo == null &&
      ajustes.isNotEmpty &&
      naoCoberto <= SaldoProduto.tolerancia;
}

/// Por que um produto não recebeu baixa. Existe para o resumo poder explicar
/// um mapa que continuou azul — "não fiz nada" sem motivo é o que faz o
/// usuário desconfiar do automático e voltar a corrigir rack por rack.
enum MotivoSemBaixa {
  /// Nenhuma contagem confirmada: ninguém afirmou o que existe no chão.
  semContagem,

  /// O produto não tem endereço nenhum — não há de onde tirar.
  semEndereco,

  /// Algum endereço é mais novo que a contagem: houve lançamento ou correção
  /// depois dela, e a contagem já não descreve o mundo.
  mexidoDepoisDaContagem,

  /// Endereçado já bate com o contado (ou está abaixo dele) — nada a retirar.
  semExcesso,

  /// O alvo saiu negativo (divergência maior que o saldo do sistema): dado
  /// inconsistente, que uma baixa automática não tem como resolver.
  alvoNegativo,
}

/// Prioridade do local na hora de tirar o que foi vendido.
///
/// A gôndola primeiro porque é de lá que o cliente pega; depois a estante,
/// que é a reposição da mesma loja; o galpão por último, que é o prédio de
/// onde a carga só sai por separação. Sem essa ordem, uma venda de balcão
/// derrubaria um palete inteiro do galpão e deixaria a gôndola cheia no mapa.
int prioridadeDoLocal(EnderecoLocalizado e) => e.ehGondola
    ? 0
    : e.localTipo == localTipoGalpao
        ? 2
        : 1;

/// Os endereços na ordem em que perdem quantidade.
///
/// Dentro da loja (gôndola e estante), o mais CHEIO primeiro — a mesma regra
/// que [sugerirDeducao] já usava na correção manual, e a que menos espalha a
/// baixa por prateleiras diferentes.
///
/// Dentro do galpão, o mais VAZIO primeiro, ao contrário. Quem separa carga
/// termina o palete aberto antes de romper um fechado, e é assim que a vaga
/// se libera de verdade: baixar o palete cheio deixaria dois pela metade onde
/// antes havia um inteiro e um resto.
///
/// Os empates caem em (localNum, faceOuColuna, andarOuNivel) para a ordem ser
/// a mesma em qualquer aparelho — dois celulares sincronizando não podem
/// escolher racks diferentes para a mesma baixa.
List<EnderecoLocalizado> ordenarParaBaixa(
    Iterable<EnderecoLocalizado> enderecos) {
  final ordenados = List<EnderecoLocalizado>.of(enderecos)
    ..sort((a, b) {
      final porLocal = prioridadeDoLocal(a).compareTo(prioridadeDoLocal(b));
      if (porLocal != 0) return porLocal;

      final noGalpao = a.localTipo == localTipoGalpao;
      final porQtd = noGalpao
          ? a.quantidade.compareTo(b.quantidade)
          : b.quantidade.compareTo(a.quantidade);
      if (porQtd != 0) return porQtd;

      final porNum = a.localNum.compareTo(b.localNum);
      if (porNum != 0) return porNum;
      final porFace = a.faceOuColuna.compareTo(b.faceOuColuna);
      if (porFace != 0) return porFace;
      return a.andarOuNivel.compareTo(b.andarOuNivel);
    });
  return ordenados;
}

/// Monta a baixa de UM produto. Devolve sempre um plano — quando não há o que
/// fazer, com [PlanoBaixa.motivo] preenchido —, para o resumo poder explicar
/// cada produto que ficou de fora.
///
/// [enderecos] são TODOS os endereços do produto (de todos os códigos
/// irmãos), como estão gravados em estoque_localizado.
PlanoBaixa planejarBaixa({
  required ContagemDoProduto contagem,
  required List<EnderecoLocalizado> enderecos,
}) {
  final enderecadoAntes =
      enderecos.fold<double>(0, (soma, e) => soma + e.quantidade);

  PlanoBaixa semBaixa(MotivoSemBaixa motivo) => PlanoBaixa(
        contagem:        contagem,
        enderecadoAntes: enderecadoAntes,
        ajustes:         const [],
        motivo:          motivo,
      );

  final confirmada = contagem.confirmadaEm;
  if (confirmada == null)  return semBaixa(MotivoSemBaixa.semContagem);
  if (enderecos.isEmpty)   return semBaixa(MotivoSemBaixa.semEndereco);

  // Endereço sem data é endereço de origem desconhecida: não dá para afirmar
  // que a contagem veio depois dele, e na dúvida o produto fica inteiro de
  // fora — a mesma regra do endereço mexido depois.
  final mexidoDepois = enderecos.any((e) {
    final atualizado =
        e.atualizadoEm == null ? null : DateTime.tryParse(e.atualizadoEm!);
    return atualizado == null || !atualizado.isBefore(confirmada);
  });
  if (mexidoDepois) return semBaixa(MotivoSemBaixa.mexidoDepoisDaContagem);

  final alvo = contagem.alvoEnderecado;
  if (alvo < -SaldoProduto.tolerancia) {
    return PlanoBaixa(
      contagem:        contagem,
      enderecadoAntes: enderecadoAntes,
      ajustes:         const [],
      naoCoberto:      -alvo,
      motivo:          MotivoSemBaixa.alvoNegativo,
    );
  }

  var restante = enderecadoAntes - alvo;
  if (restante <= SaldoProduto.tolerancia) {
    return semBaixa(MotivoSemBaixa.semExcesso);
  }

  final ajustes = <AjusteEndereco>[];
  for (final e in ordenarParaBaixa(enderecos)) {
    if (restante <= SaldoProduto.tolerancia) break;
    if (e.quantidade <= 0) continue;
    final tira = restante < e.quantidade ? restante : e.quantidade;
    ajustes.add(AjusteEndereco(
      endereco:    e,
      qtdAnterior: e.quantidade,
      qtdNova:     e.quantidade - tira,
    ));
    restante -= tira;
  }

  return PlanoBaixa(
    contagem:        contagem,
    enderecadoAntes: enderecadoAntes,
    ajustes:         ajustes,
    naoCoberto:      restante > SaldoProduto.tolerancia ? restante : 0,
  );
}

/// Os ajustes do galpão na ordem em que TÊM de ser gravados: por posição, e
/// dentro de cada posição do nível mais alto para o mais baixo.
///
/// Esvaziar um rack RENUMERA a pilha — os que estavam acima dele descem um
/// nível. Baixando de cima para baixo, o que ainda falta gravar está sempre
/// ABAIXO do que já saiu, e a numeração dele não mudou. Na ordem inversa,
/// esvaziar o nível 1 faria o nível 3 virar 2, e o ajuste seguinte acertaria
/// o palete errado — um palete inteiro de outro produto.
List<AjusteEndereco> ordenarGravacaoGalpao(Iterable<AjusteEndereco> ajustes) {
  final doGalpao = ajustes
      .where((a) => a.endereco.localTipo == localTipoGalpao)
      .toList()
    ..sort((a, b) {
      final porPosicao = a.endereco.localNum.compareTo(b.endereco.localNum);
      return porPosicao != 0
          ? porPosicao
          : b.endereco.andarOuNivel.compareTo(a.endereco.andarOuNivel);
    });
  return doGalpao;
}

/// O que a baixa fez numa passada — o que a tela mostra e o que o teste lê.
class ResumoBaixa {
  /// Planos efetivamente gravados.
  final List<PlanoBaixa> aplicados;

  /// Planos que tinham baixa a fazer mas cuja gravação falhou (sem conexão,
  /// rack que sumiu no meio). Ficam para a próxima passada.
  final List<PlanoBaixa> falhados;

  /// Produtos avaliados e deixados de fora, com o motivo. Só os que têm
  /// endereço e contagem entram aqui — o catálogo inteiro não é notícia.
  final List<PlanoBaixa> ignorados;

  const ResumoBaixa({
    this.aplicados = const [],
    this.falhados  = const [],
    this.ignorados = const [],
  });

  static const ResumoBaixa vazio = ResumoBaixa();

  int get produtos => aplicados.length;

  double get totalDeduzido =>
      aplicados.fold<double>(0, (soma, p) => soma + p.deduzido);

  int get enderecosTocados =>
      aplicados.fold<int>(0, (soma, p) => soma + p.ajustes.length);

  /// True quando nada foi gravado — o mapa já estava em dia, ou não havia
  /// contagem nova para aplicar.
  bool get semBaixas => aplicados.isEmpty;

  /// Produtos que continuam faltando endereço depois da baixa — o vermelho
  /// que sobra no mapa e que só uma pessoa resolve.
  List<PlanoBaixa> get comFaltaDeEndereco => [
        ...aplicados,
        ...ignorados,
      ].where((p) => p.faltaEnderecar > SaldoProduto.tolerancia).toList();
}
