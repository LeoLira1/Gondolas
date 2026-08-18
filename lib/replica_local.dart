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
int? frameDuravelDaReplica(String conteudoInfo) {
  try {
    final json = jsonDecode(conteudoInfo);
    if (json is! Map) return null;
    final frame = json['durable_frame_num'];
    return frame is int ? frame : null;
  } catch (_) {
    return null;
  }
}

/// True quando o erro indica que a replica local não tem mais como conversar
/// com o servidor — nem sincronizando, nem reabrindo. São três situações, e
/// todas têm a mesma (única) saída: apagar o arquivo local e rebaixar tudo.
///
/// * `InvalidPushFrameConflict(a, b)` — o servidor recusou os frames locais.
///   Como o cliente sempre empurra a partir do mesmo ponto, o erro se repete
///   para sempre: uma vez divergida, a replica nunca mais sincroniza sozinha.
/// * `InvalidLocalState` — `.db` sem o `-info` ao lado (ou o contrário). O
///   libsql se recusa a abrir a replica nesse estado.
/// * `InvalidLocalGeneration` — a geração local ficou à frente da do servidor
///   (o banco remoto foi recriado ou restaurado por fora).
///
/// A comparação é por texto porque o `libsql_dart` faz `unwrap()` no lado Rust:
/// o que chega no Dart é uma `PanicException` com a mensagem do erro dentro,
/// sem tipo nenhum para checar.
bool erroDeReplicaDivergente(Object erro) {
  final texto = erro.toString();
  return texto.contains('InvalidPushFrameConflict') ||
      texto.contains('InvalidLocalState') ||
      texto.contains('InvalidLocalGeneration');
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
