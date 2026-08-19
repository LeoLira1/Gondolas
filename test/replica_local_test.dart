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

  group('estado da replica (geração + frame)', () {
    test('lê geração e frame juntos', () {
      const info = '{"hash":1,"version":0,"durable_frame_num":102,'
          '"generation":7}';
      final estado = estadoDaReplica(info)!;
      expect(estado.geracao, 7);
      expect(estado.frame,   102);
    });

    test('geração ausente vira 0 — libsql antigo ainda é comparável', () {
      final estado = estadoDaReplica('{"durable_frame_num":5}')!;
      expect(estado.geracao, 0);
      expect(estado.frame,   5);
    });

    test('sem durable_frame_num não há o que comparar', () {
      expect(estadoDaReplica('{"generation":7}'), isNull);
      expect(estadoDaReplica('não é json'),       isNull);
    });

    test('frame maior na mesma geração é avanço', () {
      const antes  = EstadoDaReplica(geracao: 3, frame: 10);
      const depois = EstadoDaReplica(geracao: 3, frame: 11);
      expect(depois.avancouSobre(antes), isTrue);
      expect(antes.avancouSobre(depois), isFalse);
    });

    test('frame parado na mesma geração não é avanço', () {
      const estado = EstadoDaReplica(geracao: 3, frame: 10);
      expect(estado.avancouSobre(estado), isFalse);
    });

    test('geração nova é avanço mesmo com frame menor', () {
      // O servidor zera o contador de frames quando vira a geração
      // (checkpoint, restore). Sem esta regra, o sync que ACABOU de dar certo
      // seria lido como "andou para trás" e viraria falha.
      const antes  = EstadoDaReplica(geracao: 3, frame: 900);
      const depois = EstadoDaReplica(geracao: 4, frame: 2);
      expect(depois.avancouSobre(antes), isTrue);
    });
  });

  group('veredito do sync que voltou sem exceção', () {
    const parado = EstadoDaReplica(geracao: 1, frame: 40);

    test('frame que andou é sincronização confirmada', () {
      // Só o servidor move esse número: aqui o app pode dizer "sincronizado"
      // sem gastar mais nenhuma ida à rede.
      expect(
        avaliarSync(
          antes: parado,
          depois: const EstadoDaReplica(geracao: 1, frame: 41),
        ),
        ResultadoDoSync.confirmado,
      );
    });

    test('geração virada pelo servidor também é confirmação', () {
      expect(
        avaliarSync(
          antes: parado,
          depois: const EstadoDaReplica(geracao: 2, frame: 1),
        ),
        ResultadoDoSync.confirmado,
      );
    });

    test('frame parado não é prova de nada — precisa confirmar', () {
      // É o caso do relato: o botão responde na hora e diz "sincronizado".
      // Frame parado tanto pode ser "já estava em dia" quanto o sync que
      // voltou calado sem rede, então quem chama tem de perguntar ao servidor.
      expect(
        avaliarSync(antes: parado, depois: parado),
        ResultadoDoSync.naoVerificado,
      );
    });

    test('frame que andou para trás na mesma geração não confirma', () {
      expect(
        avaliarSync(
          antes: parado,
          depois: const EstadoDaReplica(geracao: 1, frame: 39),
        ),
        ResultadoDoSync.naoVerificado,
      );
    });

    test('sem -info legível, confirma pelo servidor', () {
      expect(avaliarSync(antes: null, depois: parado),
          ResultadoDoSync.naoVerificado);
      expect(avaliarSync(antes: parado, depois: null),
          ResultadoDoSync.naoVerificado);
    });
  });

  group('mensagens do sync', () {
    test('envio não confirmado diz que os dados continuam no aparelho', () {
      final msg = descreverErroSync(const SincronizacaoNaoConfirmada(3));
      expect(msg, contains('3 gravações'));
      expect(msg, contains('aparelho'));
    });

    test('singular sem pendência vira aviso de rede', () {
      expect(descreverErroSync(const SincronizacaoNaoConfirmada(1)),
          contains('1 gravação continua'));
      expect(descreverErroSync(const SincronizacaoNaoConfirmada()),
          contains('não deu para falar com o banco online'));
    });

    test('não é confundido com replica divergente', () {
      // A checagem de texto de erroDeReplicaDivergente varre a mensagem
      // inteira: se ela casasse aqui, o app apagaria o cache local (e as
      // gravações pendentes) por uma simples falha de rede.
      expect(erroDeReplicaDivergente(const SincronizacaoNaoConfirmada(2)),
          isFalse);
    });

    test('sucesso mostra quantas gravações subiram', () {
      expect(resumoDoSync(0), 'Sincronizado com o banco online ✓');
      expect(resumoDoSync(1), contains('1 gravação enviada'));
      expect(resumoDoSync(7), contains('7 gravações enviadas'));
    });
  });
}
