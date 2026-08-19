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
/// Existe porque "sem exceção" não quer dizer "sincronizou": o `sync()` do
/// libsql engole falha de rede e devolve sucesso quando a requisição HTTP não
/// completa (o mesmo defeito que `BaseLocalNaoBaixada` trata na carga inicial).
/// É esse retorno mudo que fazia o app piscar "Sincronizado ✓" em menos de um
/// segundo sem ter falado com o servidor.
enum ResultadoDoSync {
  /// O arquivo local avançou (frame ou geração). Só o servidor faz isso
  /// acontecer, então aqui não há o que confirmar — e é o caminho de graça:
  /// nenhuma ida à rede além do próprio sync.
  confirmado,

  /// Nada avançou. Pode ser "já estava tudo em dia" ou o sync que voltou
  /// calado sem falar com o servidor — o `-info` sozinho NÃO separa os dois,
  /// e chutar "deu certo" aqui é justamente o bug. Quem chama desempata com
  /// um round-trip curto no remoto.
  naoVerificado,
}

/// Classifica um `sync()` comparando o `-info` de antes e o de depois.
///
/// Só afirma o lado positivo: frame (ou geração) que andou é prova de que o
/// servidor respondeu. O contrário não é prova de nada — daí `naoVerificado`
/// em vez de "falhou". Sem os dois lados da comparação (arquivo ausente,
/// formato novo do libsql) cai no mesmo caso: confere com o servidor.
ResultadoDoSync avaliarSync({
  required EstadoDaReplica? antes,
  required EstadoDaReplica? depois,
}) =>
    antes != null && depois != null && depois.avancouSobre(antes)
        ? ResultadoDoSync.confirmado
        : ResultadoDoSync.naoVerificado;

/// O `sync()` voltou sem erro, mas nada saiu do aparelho.
///
/// Tipo próprio pelo mesmo motivo de `BaseLocalNaoBaixada`: é uma falha que o
/// libsql não levanta: quem a detecta é o app, comparando o `-info` (ver
/// `avaliarSync`). As gravações continuam salvas localmente — a mensagem
/// precisa dizer isso, senão o usuário acha que perdeu o lançamento.
class SincronizacaoNaoConfirmada implements Exception {
  /// Quantas gravações locais continuavam esperando o envio.
  final int pendentes;

  const SincronizacaoNaoConfirmada([this.pendentes = 0]);

  @override
  String toString() =>
      'SincronizacaoNaoConfirmada: o servidor não confirmou o envio '
      '($pendentes pendente(s))';
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
String resumoDoSync(int enviadas) {
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
  if (e is SincronizacaoNaoConfirmada) {
    // O aparelho não perdeu nada — insistir nisso é o ponto da mensagem: o
    // usuário que vê "não sincronizou" logo depois de lançar precisa saber
    // que o lançamento continua guardado e vai subir na próxima tentativa.
    final quantas = e.pendentes == 1
        ? '1 gravação continua'
        : '${e.pendentes} gravações continuam';
    return e.pendentes > 0
        ? 'o envio não chegou ao banco online — $quantas salvas no aparelho; '
            'verifique a internet e sincronize de novo'
        : 'não deu para falar com o banco online — verifique a internet e '
            'sincronize de novo';
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
