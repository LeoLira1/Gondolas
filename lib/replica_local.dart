import 'dart:async';
import 'dart:convert';

/// Regras puras sobre a replica local do Turso (o "cache local"): como ler o
/// arquivo de metadados do sync, como reconhecer uma replica que divergiu do
/// servidor e como explicar uma falha de sincronização para o usuário.
///
/// Mora fora do `TursoService` pelo mesmo motivo do `layout_cache.dart`: sem
/// Flutter, sem libsql e sem I/O, dá para testar direto em `flutter test` — e
/// é justamente aqui que ficam as decisões que quebraram o app em produção
/// (ver `frameDuravelDaReplica` e `erroDeReplicaDivergente`).

/// Frame que a replica local já tem confirmado no servidor, lido do arquivo
/// `<banco>-info` que o libsql grava ao lado do `.db`.
///
/// O conteúdo é um JSON `{"hash":…,"version":…,"durable_frame_num":…,
/// "generation":…}`. Zero é o valor que o libsql escreve logo depois de baixar
/// o snapshot inicial (endpoint `/export`): o arquivo `.db` já tem TODOS os
/// dados, mas do ponto de vista do protocolo de sync a replica ainda não
/// confirmou frame nenhum e precisa puxar (pull) os frames da geração antes de
/// poder empurrar (push) qualquer coisa. Escrever no banco local nesse estado
/// é o que produz o `InvalidPushFrameConflict(1, N)`: o cliente tenta empurrar
/// a partir do frame 1 e o servidor responde que já está no frame N.
///
/// Devolve null quando o JSON não é o esperado (versão nova do libsql, arquivo
/// truncado) — quem chama decide o fallback em vez de adivinhar aqui.
int? frameDuravelDaReplica(String conteudoInfo) =>
    estadoDaReplica(conteudoInfo)?.frame;

/// Geração + frame confirmado da replica local, lidos juntos do `-info`.
///
/// Os dois só fazem sentido em par: o frame é um contador DENTRO da geração,
/// e o servidor zera esse contador toda vez que a geração vira (checkpoint,
/// restore, banco recriado). Comparar frames de gerações diferentes diria
/// "andou para trás" num sync que na verdade deu certo.
class EstadoDaReplica {
  final int geracao;
  final int frame;

  const EstadoDaReplica({required this.geracao, required this.frame});

  /// True quando este estado é posterior a [anterior] — ou seja, quando o
  /// libsql realmente moveu frames com o servidor entre as duas leituras.
  /// Geração nova conta como avanço mesmo com frame menor, pelo motivo acima.
  bool avancouSobre(EstadoDaReplica anterior) => geracao == anterior.geracao
      ? frame > anterior.frame
      : geracao > anterior.geracao;

  @override
  String toString() => 'EstadoDaReplica(geracao: $geracao, frame: $frame)';
}

/// Lê `{"generation":…,"durable_frame_num":…}` do arquivo `-info`.
///
/// `durable_frame_num` é obrigatório: sem ele não há o que comparar e quem
/// chama precisa saber que a leitura não serve (null), em vez de receber um
/// zero que passaria por "replica recém-baixada". Já a geração é opcional —
/// versões do libsql que não a escrevem viram geração 0, e a comparação
/// continua valendo entre duas leituras do mesmo formato.
EstadoDaReplica? estadoDaReplica(String conteudoInfo) {
  try {
    final json = jsonDecode(conteudoInfo);
    if (json is! Map) return null;
    final frame = json['durable_frame_num'];
    if (frame is! int) return null;
    final geracao = json['generation'];
    return EstadoDaReplica(
      geracao: geracao is int ? geracao : 0,
      frame:   frame,
    );
  } catch (_) {
    return null;
  }
}

/// O que se pode afirmar sobre um `client.sync()` que voltou SEM exceção.
///
/// As regras abaixo saem da leitura do `sync.rs` do libsql 0.9.30 (a versão
/// que o `libsql_dart` embute), conferida contra um servidor libsql rodando de
/// verdade. Dois fatos do `sync_offline` sustentam tudo:
///
/// * ele só empurra quando `wal_frame_count > durable_frame_num` — ou seja, o
///   próprio libsql sabe se há gravação local esperando;
/// * um push aceito termina em `write_metadata()`, DEPOIS de mover o
///   `durable_frame_num`. Push que dá certo sempre mexe no `-info`.
///
/// Daí a regra que interessa: `-info` parado COM gravação local esperando é
/// prova de que o envio não saiu. Sem gravação esperando, `-info` parado é só
/// "não havia o que mover".
enum ResultadoDoSync {
  /// O `-info` avançou (frame ou geração). Só o servidor move aquele número.
  confirmado,

  /// Havia gravação local esperando e o `-info` não andou: o push não saiu.
  /// É a mentira que o usuário enxerga como "sincronizou rápido e não mudou
  /// nada" — e aqui dá para afirmar sem gastar mais nenhuma ida à rede.
  naoConfirmado,

  /// Nada avançou, e também não havia nada para enviar.
  ///
  /// Parece o estado normal de quem já está em dia, e por isso o app tratava
  /// isto como sucesso: a leitura do `sync.rs` dizia que um HTTP que não
  /// completa vira `SyncError::HttpDispatch` e sobe como exceção. O aparelho
  /// desmentiu — com Wi-Fi e dados DESLIGADOS o `sync()` voltou calado e sem
  /// erro, e a tela anunciou "Sincronizado com o banco online ✓".
  ///
  /// Então este caso não prova conversa nenhuma: é "o arquivo não se mexeu",
  /// que tanto pode ser "não havia novidade" quanto "não saiu daqui". Quem
  /// chama confirma com o próprio banco antes de dizer que sincronizou (ver
  /// `compararCarimbos`).
  semNovidade,

  /// Não deu para ler o `-info` de um dos lados (arquivo ausente, formato novo
  /// do libsql). Nada a afirmar — quem chama confirma com o servidor.
  indeterminado,
}

/// Classifica um `sync()` comparando o `-info` de antes e o de depois.
///
/// [gravacoesPendentes] é quantas escritas locais foram confirmadas no arquivo
/// desde o último sync bem-sucedido. É ele que separa `naoConfirmado` de
/// `semNovidade` — as duas situações em que o arquivo não se mexe, e que pedem
/// respostas opostas ao usuário.
ResultadoDoSync avaliarSync({
  required EstadoDaReplica? antes,
  required EstadoDaReplica? depois,
  required int gravacoesPendentes,
}) {
  if (antes == null || depois == null) return ResultadoDoSync.indeterminado;
  if (depois.avancouSobre(antes)) return ResultadoDoSync.confirmado;
  return gravacoesPendentes > 0
      ? ResultadoDoSync.naoConfirmado
      : ResultadoDoSync.semNovidade;
}

// ----------------------------------------------------------------------------
// Carimbo do banco: a prova de que o aparelho e o Turso têm os MESMOS dados.
// ----------------------------------------------------------------------------
//
// O `-info` só conta o que o libsql confirmou, e um `SELECT 1` só diz que o
// servidor está no ar. Nenhum dos dois enxerga o pull que voltou pela metade:
// o servidor responde, o arquivo local fica velho, e o app anuncia
// "Sincronizado ✓" sem ter recebido as gravações dos outros aparelhos.
//
// O carimbo fecha esse buraco sem depender de nada interno do libsql: a MESMA
// consulta roda nos dois lados e as respostas são comparadas. Depois de um
// sync que deu certo elas têm de bater — se não batem, alguém está atrasado,
// e dá até para dizer quem.

/// Assinatura de uma tabela num instante.
///
/// [contagem] pega inserção e remoção; [marca] pega alteração no lugar (uma
/// quantidade corrigida não mexe no número de linhas, mas mexe no
/// `atualizado_em`). Contagem -1 marca tabela que não é contada — ver
/// `TabelaDoCarimbo.contarLinhas`.
class AssinaturaTabela {
  final int contagem;
  final String marca;

  const AssinaturaTabela({required this.contagem, required this.marca});

  @override
  bool operator ==(Object outro) =>
      outro is AssinaturaTabela &&
      outro.contagem == contagem &&
      outro.marca == marca;

  @override
  int get hashCode => Object.hash(contagem, marca);

  @override
  String toString() => 'AssinaturaTabela($contagem, $marca)';
}

/// Uma tabela do carimbo e como assiná-la.
class TabelaDoCarimbo {
  final String nome;

  /// Expressão SQL escalar que resume "o que mudou por último" na tabela.
  final String marca;

  /// COUNT(*) pega remoção, mas custa varrer a tabela nos DOIS lados a cada
  /// Sincronizar. Fica desligado no log que só cresce, onde o maior id já
  /// denuncia qualquer linha nova e sai de graça (é o rowid).
  final bool contarLinhas;

  const TabelaDoCarimbo(this.nome, this.marca, {this.contarLinhas = true});
}

/// As tabelas que entram no carimbo.
///
/// Só as que ESTE app cria (ver `_criarEsquema`): elas existem dos dois lados
/// depois da carga inicial, então uma consulta que falha é problema de rede,
/// não de esquema.
///
/// O `estoque_mestre` fica de fora de propósito: é do app irmão e pode não
/// existir em todo banco. Uma tabela ausente derruba o carimbo INTEIRO, e
/// perder a conferência toda para cobrir o catálogo é troca ruim. Fica o
/// buraco anotado: catálogo desatualizado não é detectado aqui.
const List<TabelaDoCarimbo> tabelasDoCarimbo = [
  TabelaDoCarimbo('gondola_layout', "COALESCE(MAX(registrado_em),'')"),
  TabelaDoCarimbo('estante_layout', "COALESCE(MAX(registrado_em),'')"),
  TabelaDoCarimbo('estoque_localizado', "COALESCE(MAX(atualizado_em),'')"),
  TabelaDoCarimbo('galpao_racks', "COALESCE(MAX(atualizado_em),'')"),
  // Paletes mudam POR DENTRO: sai da loja (ativo = 0), é renomeado, é
  // arrastado. Nada disso mexe na contagem nem no criado_em, e o carimbo
  // precisa enxergar — é dele que sai a licença para zerar as pendências. Daí
  // as somas: os inteiros vão direto e as coordenadas viram inteiro (×1000)
  // para que o texto do número seja igual dos dois lados.
  TabelaDoCarimbo(
      'paletes',
      "COALESCE(MAX(criado_em),'') || '#' || "
      'COALESCE(SUM(ativo + colunas + fileiras + LENGTH(apelido)),0) '
      "|| '#' || "
      'COALESCE(CAST(SUM((pos_x + pos_z + rotacao) * 1000) AS INTEGER),0)'),
  TabelaDoCarimbo('contagens_log', 'COALESCE(MAX(id),0)',
      contarLinhas: false),
];

/// A consulta do carimbo: uma linha só, uma ida à rede, subconsultas que o
/// SQLite resolve pelo índice (MAX de rowid é O(1); MAX de texto e COUNT
/// varrem tabelas pequenas).
String sqlDoCarimbo() {
  final campos = <String>[];
  for (final tabela in tabelasDoCarimbo) {
    campos.add(tabela.contarLinhas
        ? '(SELECT COUNT(*) FROM ${tabela.nome}) AS ${tabela.nome}_n'
        : '-1 AS ${tabela.nome}_n');
    campos.add(
        '(SELECT ${tabela.marca} FROM ${tabela.nome}) AS ${tabela.nome}_m');
  }
  return 'SELECT ${campos.join(', ')}';
}

/// Lê a linha devolvida por `sqlDoCarimbo()`. Null quando falta coluna — ou
/// seja, quando a resposta não é a que esta versão do app sabe interpretar.
Map<String, AssinaturaTabela>? carimboDaLinha(Map<String, dynamic>? linha) {
  if (linha == null) return null;
  final carimbo = <String, AssinaturaTabela>{};
  for (final tabela in tabelasDoCarimbo) {
    final contagem = linha['${tabela.nome}_n'];
    final marca    = linha['${tabela.nome}_m'];
    if (contagem == null || marca == null) return null;
    carimbo[tabela.nome] = AssinaturaTabela(
      contagem: contagem is int ? contagem : int.tryParse('$contagem') ?? -1,
      marca:    '$marca',
    );
  }
  return carimbo;
}

/// O que a comparação dos dois carimbos permite afirmar.
enum ConferenciaDoCarimbo {
  /// Mesmos dados dos dois lados. É a única prova de sincronismo que existe
  /// sem espiar as tripas do libsql.
  iguais,

  /// O banco online tem linhas que não chegaram ao aparelho: o pull não veio
  /// inteiro. Era este o caso que passava batido como "Sincronizado ✓".
  remotoAdiante,

  /// O aparelho tem linhas que o banco online não tem: o push não subiu.
  aparelhoAdiante,

  /// Diferem sem uma direção clara (alteração no lugar, ou os dois lados com
  /// coisa que o outro não tem).
  divergentes,

  /// Não deu para carimbar um dos lados. Nada a afirmar.
  indeterminada,
}

/// Compara os dois carimbos.
ConferenciaDoCarimbo compararCarimbos({
  required Map<String, AssinaturaTabela>? aparelho,
  required Map<String, AssinaturaTabela>? remoto,
}) {
  if (aparelho == null || remoto == null) {
    return ConferenciaDoCarimbo.indeterminada;
  }
  var remotoTemMais   = false;
  var aparelhoTemMais = false;
  var marcasDiferem   = false;
  for (final tabela in tabelasDoCarimbo) {
    final aqui = aparelho[tabela.nome];
    final la   = remoto[tabela.nome];
    if (aqui == null || la == null) return ConferenciaDoCarimbo.indeterminada;
    if (aqui == la) continue;
    if (aqui.contagem == la.contagem) {
      marcasDiferem = true;
    } else if (la.contagem > aqui.contagem) {
      remotoTemMais = true;
    } else {
      aparelhoTemMais = true;
    }
  }
  if (!remotoTemMais && !aparelhoTemMais && !marcasDiferem) {
    return ConferenciaDoCarimbo.iguais;
  }
  if (remotoTemMais && !aparelhoTemMais) return ConferenciaDoCarimbo.remotoAdiante;
  if (aparelhoTemMais && !remotoTemMais) return ConferenciaDoCarimbo.aparelhoAdiante;
  return ConferenciaDoCarimbo.divergentes;
}

/// Nomes das tabelas cujas assinaturas não bateram — o que vai no log e no
/// texto do erro técnico, para não caçar diferença no escuro.
List<String> tabelasDivergentes({
  required Map<String, AssinaturaTabela>? aparelho,
  required Map<String, AssinaturaTabela>? remoto,
}) {
  if (aparelho == null || remoto == null) return const [];
  return [
    for (final tabela in tabelasDoCarimbo)
      if (aparelho[tabela.nome] != remoto[tabela.nome]) tabela.nome,
  ];
}

/// O sync voltou, o banco respondeu, e mesmo assim os dois lados têm dados
/// diferentes. Não é perda: é atraso — de um lado ou do outro.
class DadosForaDeSincronia implements Exception {
  final ConferenciaDoCarimbo conferencia;
  final List<String> tabelas;

  const DadosForaDeSincronia(this.conferencia, [this.tabelas = const []]);

  @override
  String toString() =>
      'DadosForaDeSincronia: ${conferencia.name} (${tabelas.join(", ")})';
}

/// O `sync()` voltou sem erro, mas nada saiu do aparelho.
///
/// Tipo próprio pelo mesmo motivo de `BaseLocalNaoBaixada`: é uma falha que o
/// libsql não levanta: quem a detecta é o app, comparando o `-info` (ver
/// `avaliarSync`). As gravações continuam salvas localmente — a mensagem
/// precisa dizer isso, senão o usuário acha que perdeu o lançamento.
class SincronizacaoNaoConfirmada implements Exception {
  /// Quantas gravações locais continuavam esperando o envio.
  final int pendentes;

  /// True quando o banco online respondeu a uma consulta logo depois do envio
  /// que não saiu. Muda o conselho por inteiro: com o servidor no ar, mandar
  /// "verifique a internet" é conselho errado — quem está travado assim
  /// segue apertando Sincronizar e vendo a mesma acusação injusta.
  final bool bancoRespondeu;

  const SincronizacaoNaoConfirmada([
    this.pendentes = 0,
    this.bancoRespondeu = false,
  ]);

  @override
  String toString() =>
      'SincronizacaoNaoConfirmada: o servidor não confirmou o envio '
      '($pendentes pendente(s), '
      'banco ${bancoRespondeu ? "respondeu" : "calado"})';
}

/// True quando o erro indica que a replica local não tem mais como conversar
/// com o servidor — nem sincronizando, nem reabrindo. São quatro situações, e
/// todas têm a mesma (única) saída: apagar o arquivo local e rebaixar tudo.
///
/// * `InvalidPushFrameConflict(a, b)` — o servidor recusou os frames locais.
///   Como o cliente sempre empurra a partir do mesmo ponto, o erro se repete
///   para sempre: uma vez divergida, a replica nunca mais sincroniza sozinha.
/// * `InvalidLocalState` — `.db` sem o `-info` ao lado (ou o contrário). O
///   libsql se recusa a abrir a replica nesse estado.
/// * `InvalidLocalGeneration` — a geração local ficou à frente da do servidor
///   (o banco remoto foi recriado ou restaurado por fora).
/// * `Generation ID mismatch` dentro de um `PushFrame(400, …)` — o caso
///   inverso do anterior: quem virou a geração foi o SERVIDOR (checkpoint do
///   Turso, restore, banco recriado) e a replica local continua empurrando
///   frames carimbados com a geração velha. O servidor devolve HTTP 400 e a
///   replica repete o mesmo push a cada Sincronizar, para sempre.
///
/// Qualquer `PushFrame(400, …)` entra na regra, e não só o texto da geração:
/// 400 é o servidor dizendo que os frames locais estão errados, e repetir o
/// envio idêntico nunca muda a resposta. Erro de rede e token vêm com outro
/// formato (socket, 401/403), então não caem aqui por engano.
///
/// A comparação é por texto porque o `libsql_dart` faz `unwrap()` no lado Rust:
/// o que chega no Dart é uma `PanicException` com a mensagem do erro dentro,
/// sem tipo nenhum para checar.
bool erroDeReplicaDivergente(Object erro) {
  final texto = erro.toString();
  return texto.contains('InvalidPushFrameConflict') ||
      texto.contains('InvalidLocalState') ||
      texto.contains('InvalidLocalGeneration') ||
      texto.contains('Generation ID mismatch') ||
      texto.contains('PushFrame(400');
}

/// A base do remoto não pôde ser baixada porque o servidor não respondeu.
///
/// Existe como tipo próprio porque o `sync()` do libsql ENGOLE falha de rede:
/// quando o HTTP não completa, ele devolve "0 frames sincronizados" como se
/// tivesse dado certo. Sem distinguir esse caso, o app acharia que a base está
/// estabelecida e começaria a escrever numa replica atrasada — que é a receita
/// do InvalidPushFrameConflict.
class BaseLocalNaoBaixada implements Exception {
  const BaseLocalNaoBaixada();

  @override
  String toString() => 'BaseLocalNaoBaixada: o servidor não respondeu';
}

/// Texto do Sincronizar que deu certo, para o snackbar.
///
/// [enviadas] é quantas gravações locais o servidor aceitou nesta rodada. O
/// número aparece de propósito: "Sincronizado ✓" sozinho é exatamente o que o
/// app dizia quando NÃO sincronizava nada, então deixou de ser uma informação
/// em que dá para confiar. Com a contagem, quem acabou de lançar cinco paletes
/// vê os cinco subirem — ou vê "0" e sabe que ainda não subiram.
///
/// Sem [modoLocal] não há replica nenhuma: cada gravação já foi direto ao
/// servidor e não existe fila para esvaziar. Dizer "sincronizado" ali seria
/// prometer um envio que nunca houve, então o texto muda.
String resumoDoSync({required bool modoLocal, required int enviadas}) {
  if (!modoLocal) return 'Banco online respondendo ✓ — nada em fila';
  if (enviadas <= 0) return 'Sincronizado com o banco online ✓';
  return enviadas == 1
      ? 'Sincronizado ✓ — 1 gravação enviada'
      : 'Sincronizado ✓ — $enviadas gravações enviadas';
}

/// Traduz a exceção do sync numa dica curta e acionável — a causa real
/// (replica divergente ≠ token expirado ≠ sem internet ≠ demora da rede) muda
/// o que o usuário precisa fazer para resolver.
String descreverErroSync(Object e) {
  if (e is TimeoutException) {
    return 'a rede demorou demais para responder — tente novamente';
  }
  if (e is BaseLocalNaoBaixada) {
    return 'sem conexão para baixar a base do cache local — '
        'conecte à internet e sincronize de novo';
  }
  if (e is DadosForaDeSincronia) {
    // Nada se perdeu — os dois lados estão inteiros, um só está atrasado. A
    // mensagem diz QUEM está atrasado porque a consequência muda: dados que
    // não chegaram significam mapa velho na tela; dados que não subiram
    // significam lançamento ainda preso no aparelho.
    switch (e.conferencia) {
      case ConferenciaDoCarimbo.remotoAdiante:
        return 'o banco online tem dados que ainda não chegaram ao aparelho — '
            'sincronize de novo';
      case ConferenciaDoCarimbo.aparelhoAdiante:
        return 'o envio não saiu do aparelho — o que foi lançado continua '
            'salvo aqui; toque em Sincronizar de novo';
      case ConferenciaDoCarimbo.iguais:
      case ConferenciaDoCarimbo.indeterminada:
      case ConferenciaDoCarimbo.divergentes:
        return 'o aparelho e o banco online estão com dados diferentes — '
            'sincronize de novo';
    }
  }
  if (e is SincronizacaoNaoConfirmada) {
    if (e.pendentes <= 0) {
      return 'não deu para falar com o banco online — verifique a internet e '
          'sincronize de novo';
    }
    // O aparelho não perdeu nada — insistir nisso é o ponto da mensagem: o
    // usuário que vê "não sincronizou" logo depois de lançar precisa saber
    // que o lançamento continua guardado e vai subir na próxima tentativa.
    // Daí a concordância importar: o "salvas" fixo dizia "1 gravação continua
    // salvas no aparelho", na única linha em que ele precisa confiar.
    final quantas = e.pendentes == 1
        ? '1 gravação continua salva'
        : '${e.pendentes} gravações continuam salvas';
    return e.bancoRespondeu
        ? 'o banco online respondeu, mas o envio não saiu do aparelho — '
            '$quantas aqui; toque em Sincronizar de novo'
        : 'o envio não chegou ao banco online — $quantas no aparelho; '
            'verifique a internet e sincronize de novo';
  }
  // Antes das buscas genéricas: o texto de uma PanicException traz o backtrace
  // inteiro e casaria com elas por acidente.
  if (erroDeReplicaDivergente(e)) {
    return 'o cache local divergiu do banco online e não deu para reconstruir '
        'agora — verifique a internet e sincronize de novo';
  }
  final msg   = e.toString().replaceAll('\n', ' ').trim();
  final lower = msg.toLowerCase();
  if (lower.contains('401') ||
      lower.contains('unauthorized') ||
      lower.contains('forbidden') ||
      lower.contains('auth')) {
    return 'token inválido ou expirado — confira em ⚙️';
  }
  if (lower.contains('dns') ||
      lower.contains('socket') ||
      lower.contains('network') ||
      lower.contains('connection refused') ||
      lower.contains('failed to connect') ||
      lower.contains('timed out')) {
    return 'sem conexão com o banco — verifique a internet';
  }
  return msg.length > 140 ? '${msg.substring(0, 140)}…' : msg;
}
