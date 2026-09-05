import 'dart:convert';
import 'dart:math';

/// Regras puras da outbox de mutações: o que é uma mutação registrada, como
/// comparar estados de banco sem tropeçar em formato, e o que fazer com cada
/// registro depois que a réplica local foi reconstruída.
///
/// Mora fora do `TursoService` pelo mesmo motivo do `replica_local.dart`: sem
/// Flutter, sem libsql e sem I/O, dá para testar direto em `flutter test`. E é
/// aqui que estão as decisões que, erradas, reconstroem um estoque errado sem
/// ninguém perceber.

/// Onde uma mutação mexeu: a tabela e as colunas que identificam a linha.
///
/// A chave é o que permite reler a MESMA linha no remoto depois de uma
/// reconstrução. Por isso ela precisa ser estável de verdade — ver
/// [operacaoExigeRevisaoManual] para o caso em que ela não é.
class AlvoMutacao {
  final String tabela;
  final Map<String, Object?> chave;

  const AlvoMutacao({required this.tabela, required this.chave});

  Map<String, Object?> toJson() => {'tabela': tabela, 'chave': chave};

  static AlvoMutacao fromJson(Map<String, Object?> json) => AlvoMutacao(
    tabela: json['tabela'] as String,
    chave: Map<String, Object?>.from(json['chave'] as Map),
  );
}

enum EstadoMutacao {
  /// Gravada no arquivo local; ainda sem confirmação do servidor.
  pendente,

  /// O servidor confirmou: o UUID foi encontrado em `app_mutacoes_aplicadas`
  /// numa consulta AO REMOTO, não à réplica.
  confirmada,

  /// A transação local caiu antes do commit. Nada foi gravado — mas o registro
  /// fica, porque a outbox não apaga nada.
  abortada,

  /// O remoto não corresponde nem ao estado anterior nem ao final: alguém mexeu
  /// no meio do caminho e reaplicar sobrescreveria trabalho de outra pessoa.
  conflito,

  /// A operação não é reaplicável com segurança (ver
  /// [operacaoExigeRevisaoManual]). Fica esperando uma pessoa decidir.
  revisaoManual,
}

/// Uma mutação registrada ANTES do commit local, com o estado de onde ela
/// partiu e o estado a que ela pretendia chegar.
///
/// Os dois estados são o que torna a reaplicação segura: sem o "anterior" não
/// dá para saber se o remoto ainda está onde estava quando o usuário agiu.
class MutacaoOutbox {
  final String uuid;

  /// Nome estável da operação, no formato `dominio.acao` (ex: `galpao.lancar`).
  final String operacao;
  final AlvoMutacao alvo;

  /// Estado da linha antes da mutação. `null` significa "a linha não existia".
  final Map<String, Object?>? estadoAnterior;

  /// Estado a que a mutação pretendia levar a linha. `null` significa
  /// "a linha deixa de existir" (um DELETE).
  final Map<String, Object?>? estadoFinal;

  /// Colunas que a linha PRECISA ter para ser recriada, mas que não entram na
  /// comparação: `atualizado_em`, `criado_em` e afins, que são NOT NULL no
  /// esquema e mudam a cada gravação. Sem elas, reaplicar uma linha que o
  /// remoto não tem mais falharia no INSERT — e uma gravação perfeitamente
  /// reaplicável viraria conflito.
  final Map<String, Object?> extrasParaInsercao;

  final DateTime criadoEm;
  final String dispositivo;
  final Map<String, Object?>? auditoria;
  final EstadoMutacao estado;

  // Campos de exibição da revisão manual. Ficam gravados em vez de derivados
  // porque a tela de revisão não pode depender de conhecer cada operação — e
  // porque o nome do produto pode ter mudado no catálogo desde então.
  final String? produtoCodigo;
  final String? produtoNome;
  final int? posicao;
  final int? ordem;
  final double? quantidadeAnterior;
  final double? quantidadePretendida;

  const MutacaoOutbox({
    required this.uuid,
    required this.operacao,
    required this.alvo,
    required this.estadoAnterior,
    required this.estadoFinal,
    required this.criadoEm,
    required this.dispositivo,
    this.extrasParaInsercao = const {},
    this.auditoria,
    this.estado = EstadoMutacao.pendente,
    this.produtoCodigo,
    this.produtoNome,
    this.posicao,
    this.ordem,
    this.quantidadeAnterior,
    this.quantidadePretendida,
  });

  MutacaoOutbox copyWith({EstadoMutacao? estado}) => MutacaoOutbox(
    uuid: uuid,
    auditoria: auditoria,
    operacao: operacao,
    alvo: alvo,
    estadoAnterior: estadoAnterior,
    estadoFinal: estadoFinal,
    criadoEm: criadoEm,
    dispositivo: dispositivo,
    extrasParaInsercao: extrasParaInsercao,
    estado: estado ?? this.estado,
    produtoCodigo: produtoCodigo,
    produtoNome: produtoNome,
    posicao: posicao,
    ordem: ordem,
    quantidadeAnterior: quantidadeAnterior,
    quantidadePretendida: quantidadePretendida,
  );

  /// Colunas que participam da comparação de estado: a união do que o anterior
  /// e o final declaram. O que não está aqui (carimbos de `atualizado_em`, por
  /// exemplo) NÃO entra na conta — senão toda comparação daria conflito só
  /// porque o relógio andou.
  Set<String> get colunasComparadas => {
    ...?estadoAnterior?.keys,
    ...?estadoFinal?.keys,
  };
}

/// Operações que a reconstrução automática NÃO pode reaplicar sozinha.
///
/// Novas gravações do galpão usam rack_uuid. Registros antigos ainda usam
/// (posição, ordem). Ambos continuam exigindo revisão: lançamento e exclusão
/// reordenam a pilha, e todas as operações atualizam também o espelho e o log.
/// Identidade estável, sozinha, não torna esses efeitos reaplicáveis por linha.
/// Os dois salvamentos de layout entram pelo outro motivo: eles substituem o
/// layout INTEIRO de uma gôndola/estante (DELETE + INSERT), e a reaplicação
/// deste primeiro desenho compara e aplica linha a linha. Reaplicar uma troca
/// de tabela inteira por cima de uma base reconstruída apagaria o desenho que
/// outra pessoa fez no meio do caminho. O layout de antes e o de depois ficam
/// gravados, então a revisão mostra exatamente o que refazer.
/// E há um terceiro motivo, o mais sutil: operações cujo efeito NÃO cabe numa
/// linha. `barracao.atribuir` e `barracao.esvaziar` também reescrevem o espelho
/// em `estoque_localizado`; `concluirContagem` também mexe no ciclo em
/// `estoque_mestre`. A reaplicação genérica sabe acertar uma linha, então
/// reaplicá-las deixaria o endereço certo e o saldo velho — e, pior, com o
/// UUID confirmado, o desencontro ficaria invisível. Enquanto a reaplicação não
/// souber refazer o efeito inteiro numa transação, elas vão para conferência.
const Set<String> operacoesDeRevisaoManual = {
  'galpao.lancar',
  'galpao.esvaziar',
  'galpao.ajustarQuantidade',
  'layout.salvarGondola',
  'layout.salvarEstante',
  'barracao.atribuir',
  'barracao.esvaziar',
  'estoqueLocalizado.concluirContagem',
};

bool operacaoExigeRevisaoManual(String operacao) =>
    operacoesDeRevisaoManual.contains(operacao);

/// Revisão é persistente: uma nova tentativa não autoriza sobrescrever dados.
bool mutacaoExigeRevisaoManual(MutacaoOutbox m) =>
    m.estado == EstadoMutacao.revisaoManual ||
    m.estado == EstadoMutacao.conflito ||
    operacaoExigeRevisaoManual(m.operacao) ||
    (m.operacao.startsWith('estoqueLocalizado.') && m.auditoria == null);

/// O que fazer com uma mutação não confirmada depois de reconstruir a réplica.
enum DecisaoReaplicacao {
  /// O remoto está onde estava quando o usuário agiu: pode aplicar o final.
  aplicarFinal,

  /// O remoto já está no estado final — a mutação chegou lá antes de tudo dar
  /// errado, ou alguém fez a mesma coisa. Nada a fazer.
  jaAplicada,

  /// O remoto não corresponde a nenhum dos dois. Reaplicar aqui sobrescreveria
  /// o trabalho de outra pessoa com um número velho.
  conflito,
}

/// Compara o que o remoto tem HOJE com os dois estados que a mutação registrou.
///
/// A ordem das perguntas importa: "já está no final?" vem primeiro para que uma
/// mutação que não mudava nada (anterior == final) termine como [jaAplicada] em
/// vez de mandar reescrever o que já está lá.
DecisaoReaplicacao decidirReaplicacao({
  required Map<String, Object?>? remoto,
  required Map<String, Object?>? anterior,
  required Map<String, Object?>? estadoFinal,
  required Set<String> colunas,
}) {
  // Operação sem estado declarado: não há o que comparar. São as que se
  // reexecutam sozinhas por construção (o seed da planta do galpão, a limpeza
  // de endereços zerados) — registradas para que nenhuma mutação fique de
  // fora, mas sem nada a reaplicar.
  if (colunas.isEmpty) return DecisaoReaplicacao.jaAplicada;

  final atual = canonico(projetar(remoto, colunas));
  if (atual == canonico(projetar(estadoFinal, colunas))) {
    return DecisaoReaplicacao.jaAplicada;
  }
  if (atual == canonico(projetar(anterior, colunas))) {
    return DecisaoReaplicacao.aplicarFinal;
  }
  return DecisaoReaplicacao.conflito;
}

/// Reduz uma linha às [colunas] que a mutação declarou. Uma linha que o remoto
/// não tem continua `null` — "não existe" é um estado, não um mapa vazio.
Map<String, Object?>? projetar(
  Map<String, Object?>? linha,
  Set<String> colunas,
) {
  if (linha == null) return null;
  return {
    for (final coluna in colunas)
      if (linha.containsKey(coluna)) coluna: linha[coluna],
  };
}

/// Texto canônico de um estado, para comparação.
///
/// Duas normalizações, cada uma por um motivo concreto:
///
/// - chaves em ordem, porque a ordem de um `Map` não é significativa e o SQLite
///   devolve as colunas na ordem do SELECT;
/// - número inteiro vira inteiro, porque a mesma quantidade volta do SQLite
///   como `90` ou `90.0` dependendo do caminho, e `"90" != "90.0"` acusaria
///   conflito numa linha idêntica.
String canonico(Map<String, Object?>? estado) {
  if (estado == null) return 'ausente';
  final chaves = estado.keys.toList()..sort();
  return jsonEncode({
    for (final chave in chaves) chave: _valorCanonico(estado[chave]),
  });
}

Object? _valorCanonico(Object? valor) {
  if (valor is num) {
    // `90.0` e `90` são a mesma quantidade de baldes.
    if (valor == valor.roundToDouble() && valor.abs() < 1e15) {
      return valor.toInt();
    }
    return valor.toDouble();
  }
  if (valor is bool) return valor ? 1 : 0;
  return valor;
}

/// UUID v4 a partir de [Random.secure]. Sem pacote novo: a única exigência aqui
/// é não colidir entre dispositivos, e 122 bits aleatórios bastam.
String gerarUuidV4([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // versão 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variante RFC 4122
  String hex(int inicio, int fim) => bytes
      .sublist(inicio, fim)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
