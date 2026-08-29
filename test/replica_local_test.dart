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

    // Terceiro texto real do aparelho (CAMDA, agosto/2026): a MESMA divergência
    // de frame, só que pelo outro desfecho do libsql — o servidor respondeu
    // "ok" com um frame muito à frente do enviado. Sem reconhecer, o app
    // despejava o panic na tela e o Sincronizar ficava preso nele para sempre:
    // com frame local à frente do confirmado, o libsql escolhe empurrar e nem
    // chega a puxar.
    const panicoFrameAlto =
        'PanicException(called `Result::unwrap()` on an `Err` value: '
        'Sync(InvalidPushFrameNoHigh(1, 230))Backtrace [{ fn: '
        '"_ZL15__pthread_startPv" }])';

    test('reconhece o frame do servidor à frente do que foi empurrado', () {
      expect(erroDeReplicaDivergente(panicoFrameAlto), isTrue);
    });

    test('o frame alto também explica o cache local ao usuário', () {
      final msg = descreverErroSync(panicoFrameAlto);
      expect(msg, contains('cache local'));
      expect(msg, isNot(contains('PanicException')));
      expect(msg, isNot(contains('token')));
    });

    test('o frame BAIXO não apaga o cache: o libsql reenvia sozinho', () {
      // InvalidPushFrameNoLow é o caso em que o libsql corrige o ponto de
      // partida e tenta de novo dentro do próprio sync_offline. Tratar como
      // divergência apagaria as gravações pendentes do usuário sem precisar.
      expect(
        erroDeReplicaDivergente('Sync(InvalidPushFrameNoLow(231, 230))'),
        isFalse,
      );
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
      // Só o servidor move esse número: o app pode dizer "sincronizado" sem
      // gastar mais nenhuma ida à rede.
      expect(
        avaliarSync(
          antes: parado,
          depois: const EstadoDaReplica(geracao: 1, frame: 41),
          gravacoesPendentes: 3,
        ),
        ResultadoDoSync.confirmado,
      );
    });

    test('geração virada pelo servidor também é confirmação', () {
      expect(
        avaliarSync(
          antes: parado,
          depois: const EstadoDaReplica(geracao: 2, frame: 1),
          gravacoesPendentes: 0,
        ),
        ResultadoDoSync.confirmado,
      );
    });

    test('frame parado COM gravação esperando é envio que não saiu', () {
      // É o caso do relato. E dá para afirmar sem perguntar ao servidor: no
      // libsql, um push aceito termina em write_metadata() DEPOIS de mover o
      // durable_frame_num — push que dá certo sempre mexe no -info.
      expect(
        avaliarSync(
            antes: parado, depois: parado, gravacoesPendentes: 1),
        ResultadoDoSync.naoConfirmado,
      );
    });

    test('frame parado SEM nada esperando é só "não havia o que mover"', () {
      expect(
        avaliarSync(
            antes: parado, depois: parado, gravacoesPendentes: 0),
        ResultadoDoSync.semNovidade,
      );
    });

    test('frame que andou para trás na mesma geração não confirma', () {
      expect(
        avaliarSync(
          antes: parado,
          depois: const EstadoDaReplica(geracao: 1, frame: 39),
          gravacoesPendentes: 0,
        ),
        ResultadoDoSync.semNovidade,
      );
    });

    test('sem -info legível não se afirma nada', () {
      expect(
        avaliarSync(antes: null, depois: parado, gravacoesPendentes: 5),
        ResultadoDoSync.indeterminado,
      );
      expect(
        avaliarSync(antes: parado, depois: null, gravacoesPendentes: 0),
        ResultadoDoSync.indeterminado,
      );
    });
  });

  group('o que o resultado do sync prova', () {
    test('sync mudo sem pendência não prova nada sozinho', () {
      // O caso do modo avião: nada para enviar, nada se moveu — e é
      // exatamente o que se vê online, em dia. Por isso `semNovidade` não
      // pode virar sucesso sem perguntar ao banco.
      const parado = EstadoDaReplica(geracao: 1, frame: 42);
      expect(
        avaliarSync(antes: parado, depois: parado, gravacoesPendentes: 0),
        ResultadoDoSync.semNovidade,
      );
    });
  });

  group('carimbo do banco', () {
    Map<String, AssinaturaTabela> carimbo({
      int gondola = 3,
      String marcaGondola = '2026-08-20T19:00:00',
      int localizado = 10,
      String marcaLocalizado = '2026-08-20T19:30:00',
    }) =>
        {
          'gondola_layout':
              AssinaturaTabela(contagem: gondola, marca: marcaGondola),
          'estante_layout':
              const AssinaturaTabela(contagem: 5, marca: '2026-08-19T10:00:00'),
          'estoque_localizado':
              AssinaturaTabela(contagem: localizado, marca: marcaLocalizado),
          'galpao_racks':
              const AssinaturaTabela(contagem: 7, marca: '2026-08-18T08:00:00'),
          'paletes':
              const AssinaturaTabela(contagem: 15, marca: '2026-01-02#15'),
          'contagens_log': const AssinaturaTabela(contagem: -1, marca: '900'),
        };

    test('a consulta cobre todas as tabelas do carimbo, numa linha só', () {
      final sql = sqlDoCarimbo();
      expect(sql.split('SELECT').length - 1, greaterThan(1));
      for (final tabela in tabelasDoCarimbo) {
        expect(sql, contains('${tabela.nome}_n'));
        expect(sql, contains('${tabela.nome}_m'));
      }
      // O log que só cresce não é contado: COUNT(*) nele cresceria para sempre,
      // e o maior id já denuncia linha nova de graça.
      expect(sql, contains('-1 AS contagens_log_n'));
    });

    test('lê a linha devolvida pelo banco', () {
      final linha = <String, dynamic>{
        for (final t in tabelasDoCarimbo) ...{
          '${t.nome}_n': 4,
          '${t.nome}_m': 'x',
        }
      };
      final lido = carimboDaLinha(linha);
      expect(lido, isNotNull);
      expect(lido!['paletes'],
          const AssinaturaTabela(contagem: 4, marca: 'x'));
    });

    test('coluna faltando invalida o carimbo inteiro', () {
      // Meia leitura seria pior que nenhuma: compararia o que sobrou e diria
      // "iguais".
      expect(carimboDaLinha(const {'gondola_layout_n': 1}), isNull);
      expect(carimboDaLinha(null), isNull);
    });

    test('carimbos iguais são a prova de que o sync trouxe tudo', () {
      expect(compararCarimbos(aparelho: carimbo(), remoto: carimbo()),
          ConferenciaDoCarimbo.iguais);
    });

    test('linha a mais no banco online é pull que não veio inteiro', () {
      // O buraco que o SELECT 1 não via: servidor no ar, aparelho velho.
      expect(
        compararCarimbos(aparelho: carimbo(), remoto: carimbo(localizado: 12)),
        ConferenciaDoCarimbo.remotoAdiante,
      );
    });

    test('linha a mais no aparelho é push que não subiu', () {
      expect(
        compararCarimbos(aparelho: carimbo(localizado: 12), remoto: carimbo()),
        ConferenciaDoCarimbo.aparelhoAdiante,
      );
    });

    test('mesma contagem com marca diferente é alteração no lugar', () {
      // Quantidade corrigida não muda o número de linhas — sem a marca, a
      // conferência diria "iguais" com valores diferentes na tela.
      expect(
        compararCarimbos(
          aparelho: carimbo(),
          remoto: carimbo(marcaLocalizado: '2026-08-20T20:45:00'),
        ),
        ConferenciaDoCarimbo.divergentes,
      );
    });

    test('cada lado com o que o outro não tem não escolhe culpado', () {
      expect(
        compararCarimbos(
          aparelho: carimbo(gondola: 4),
          remoto: carimbo(localizado: 12),
        ),
        ConferenciaDoCarimbo.divergentes,
      );
    });

    test('sem carimbo de um dos lados não há o que afirmar', () {
      expect(compararCarimbos(aparelho: null, remoto: carimbo()),
          ConferenciaDoCarimbo.indeterminada);
      expect(compararCarimbos(aparelho: carimbo(), remoto: null),
          ConferenciaDoCarimbo.indeterminada);
    });

    test('aponta as tabelas que não bateram', () {
      expect(
        tabelasDivergentes(
          aparelho: carimbo(),
          remoto: carimbo(gondola: 9, localizado: 12),
        ),
        ['gondola_layout', 'estoque_localizado'],
      );
      expect(tabelasDivergentes(aparelho: carimbo(), remoto: carimbo()),
          isEmpty);
    });

    test('atraso não é confundido com replica divergente', () {
      // Se casasse, o app apagaria o cache local por um simples atraso.
      expect(
        erroDeReplicaDivergente(
            const DadosForaDeSincronia(ConferenciaDoCarimbo.remotoAdiante)),
        isFalse,
      );
    });

    test('a mensagem diz quem está atrasado', () {
      expect(
        descreverErroSync(
            const DadosForaDeSincronia(ConferenciaDoCarimbo.remotoAdiante)),
        contains('ainda não chegaram ao aparelho'),
      );
      expect(
        descreverErroSync(
            const DadosForaDeSincronia(ConferenciaDoCarimbo.aparelhoAdiante)),
        contains('continua salvo aqui'),
      );
      expect(
        descreverErroSync(
            const DadosForaDeSincronia(ConferenciaDoCarimbo.divergentes)),
        contains('dados diferentes'),
      );
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

    test('uma gravação sozinha é anunciada no singular', () {
      // A frase aparece exatamente para quem lançou UM item e precisa acreditar
      // que ele não sumiu: "1 gravação continua salvas" quebrava essa confiança
      // na única linha que o usuário lê nessa hora.
      final msg = descreverErroSync(const SincronizacaoNaoConfirmada(1));
      expect(msg, contains('1 gravação continua salva no aparelho'));
      expect(msg, isNot(contains('salvas')));
      expect(descreverErroSync(const SincronizacaoNaoConfirmada(2)),
          contains('2 gravações continuam salvas'));
    });

    test('banco no ar não vira acusação de internet', () {
      // Com o servidor respondendo, mandar "verifique a internet" é errado — e
      // é o conselho que deixava o usuário repetindo Sincronizar sem saída.
      final msg = descreverErroSync(const SincronizacaoNaoConfirmada(1, true));
      expect(msg, contains('o banco online respondeu'));
      expect(msg, contains('1 gravação continua salva'));
      expect(msg, isNot(contains('verifique a internet')));
      // Sem resposta do banco, o conselho de rede continua valendo.
      expect(descreverErroSync(const SincronizacaoNaoConfirmada(1)),
          contains('verifique a internet'));
    });

    test('não é confundido com replica divergente', () {
      // A checagem de texto de erroDeReplicaDivergente varre a mensagem
      // inteira: se ela casasse aqui, o app apagaria o cache local (e as
      // gravações pendentes) por uma simples falha de rede.
      expect(erroDeReplicaDivergente(const SincronizacaoNaoConfirmada(2)),
          isFalse);
    });

    test('sucesso mostra quantas gravações subiram', () {
      expect(resumoDoSync(modoLocal: true, enviadas: 0),
          'Sincronizado com o banco online ✓');
      expect(resumoDoSync(modoLocal: true, enviadas: 1),
          contains('1 gravação enviada'));
      expect(resumoDoSync(modoLocal: true, enviadas: 7),
          contains('7 gravações enviadas'));
    });

    test('sem cache local não promete envio que nunca houve', () {
      // No modo remoto cada gravação já foi direto ao servidor: não existe
      // fila para esvaziar, e dizer "sincronizado" seria inventar um envio.
      final msg = resumoDoSync(modoLocal: false, enviadas: 0);
      expect(msg, isNot(contains('Sincronizado')));
      expect(msg, contains('nada em fila'));
    });
  });
}
