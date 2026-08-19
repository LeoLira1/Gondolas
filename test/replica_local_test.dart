import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/replica_local.dart';

void main() {
  group('metadados da replica local (arquivo -info)', () {
    test('lê o frame confirmado no servidor', () {
      const info = '{"hash":123,"version":0,"durable_frame_num":102,'
          '"generation":1}';
      expect(frameDuravelDaReplica(info), 102);
    });

    test('frame 0 é o estado logo após baixar o snapshot inicial', () {
      // É este o caso que o app precisa reconhecer: o arquivo .db já tem todos
      // os dados, mas nenhum frame foi confirmado — escrever agora quebra o
      // push para sempre.
      const info = '{"hash":9,"version":0,"durable_frame_num":0,'
          '"generation":1}';
      expect(frameDuravelDaReplica(info), 0);
    });

    test('devolve null quando o formato não é o esperado', () {
      expect(frameDuravelDaReplica(''), isNull);
      expect(frameDuravelDaReplica('não é json'), isNull);
      expect(frameDuravelDaReplica('[1,2,3]'), isNull);
      expect(frameDuravelDaReplica('{"generation":1}'), isNull);
      expect(frameDuravelDaReplica('{"durable_frame_num":"102"}'), isNull);
    });
  });

  group('replica divergente', () {
    // Texto real que chegou no app (Samsung, cache local ligado): o lado Rust
    // do libsql_dart faz unwrap() e o erro vira uma PanicException com a
    // mensagem inteira dentro — não há tipo para checar, só o texto.
    const panicoDoAparelho =
        'PanicException(called `Result::unwrap()` on an `Err` value: '
        'Sync(InvalidPushFrameConflict(1, 102))Backtrace [{ fn: '
        '"_ZL15__pthread_startPv" }])';

    test('reconhece o conflito de frame do push', () {
      expect(erroDeReplicaDivergente(panicoDoAparelho), isTrue);
    });

    test('reconhece o arquivo local inconsistente e a geração à frente', () {
      expect(
        erroDeReplicaDivergente(
            'Sync(InvalidLocalState("metadata file exists but db file '
            'does not"))'),
        isTrue,
      );
      expect(
        erroDeReplicaDivergente('Sync(InvalidLocalGeneration(3, 2))'),
        isTrue,
      );
    });

    // Segundo texto real do aparelho, meses depois: desta vez quem virou a
    // geração foi o servidor (checkpoint no Turso) e o push local morreu com
    // 400. Sem reconhecer isso, o Sincronizar repetia o mesmo erro para sempre
    // e despejava o panic na tela de configuração.
    const panicoGeracao =
        'PanicException(called `Result::unwrap()` on an `Err` value: '
        'Sync(PushFrame(400, "{\\"error\\": \\"Protocol error: Generation '
        'ID mismatch: expected 5, got 4\\"}"))Backtrace [{ fn: '
        '"_ZL15__pthread_startPv" }])';

    test('reconhece a geração do servidor à frente da replica', () {
      expect(erroDeReplicaDivergente(panicoGeracao), isTrue);
    });

    test('reconhece qualquer 400 no push de frames', () {
      // Um 400 é o servidor recusando os frames locais: o conteúdo do JSON
      // pode mudar com a versão do sqld, a saída é sempre reconstruir.
      expect(
        erroDeReplicaDivergente('Sync(PushFrame(400, "{}"))'),
        isTrue,
      );
      // 5xx é o servidor com problema, não a replica: continua sendo tentar
      // de novo, nunca apagar o cache do usuário.
      expect(
        erroDeReplicaDivergente('Sync(PushFrame(503, "unavailable"))'),
        isFalse,
      );
    });

    test('a geração divergente também explica o cache local ao usuário', () {
      final msg = descreverErroSync(panicoGeracao);
      expect(msg, contains('cache local'));
      expect(msg, isNot(contains('PanicException')));
    });

    test('não confunde falha de rede com divergência', () {
      expect(erroDeReplicaDivergente('SocketException: failed to connect'),
          isFalse);
      expect(erroDeReplicaDivergente(TimeoutException('sync')), isFalse);
      expect(erroDeReplicaDivergente('HTTP 401 unauthorized'), isFalse);
    });

    test('a mensagem do usuário fala do cache local, não do backtrace', () {
      final msg = descreverErroSync(panicoDoAparelho);
      expect(msg, contains('cache local'));
      // Sem isso a dica cairia na regra genérica de "auth" (o backtrace tem a
      // palavra "pthread"… e qualquer outra), ou despejaria o panic na tela.
      expect(msg, isNot(contains('PanicException')));
    });
  });

  group('mensagens das outras falhas de sync', () {
    test('base não baixada vira dica de internet, não de token', () {
      final msg = descreverErroSync(const BaseLocalNaoBaixada());
      expect(msg, contains('cache local'));
      expect(msg, contains('internet'));
    });

    test('timeout vira pedido de nova tentativa', () {
      expect(descreverErroSync(TimeoutException('sync')),
          contains('demorou demais'));
    });

    test('401 vira dica de token', () {
      expect(descreverErroSync('HTTP status 401 Unauthorized'),
          contains('token'));
    });

    test('erro de socket vira dica de internet', () {
      expect(descreverErroSync('SocketException: Failed host lookup'),
          contains('internet'));
    });

    test('erro desconhecido é truncado para caber no snackbar', () {
      final msg = descreverErroSync('x' * 500);
      expect(msg.length, lessThanOrEqualTo(141));
      expect(msg, endsWith('…'));
    });
  });
}
