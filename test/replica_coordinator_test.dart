import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/replica_coordinator.dart';

void main() {
  test('base pendente recusa escrita sem executar mutação', () async {
    final coordenador = CoordenadorReplica()
      ..definirEstado(EstadoReplica.basePendente);
    var executou = false;

    await expectLater(
      coordenador.executarEscrita(() async {
        executou = true;
      }),
      throwsA(isA<ReplicaNaoProntaParaEscrita>()),
    );
    expect(executou, isFalse);
    expect(coordenador.estado, EstadoReplica.basePendente);
  });

  test('base previamente válida permite gravação offline', () async {
    final coordenador = CoordenadorReplica()
      ..definirEstado(EstadoReplica.pronta);
    var pendentes = 0;
    await coordenador.executarEscrita(() async => pendentes++);
    expect(pendentes, 1);
  });

  test('timeout do chamador não solta sync nativo nem admite concorrência',
      () async {
    final coordenador = CoordenadorReplica()
      ..definirEstado(EstadoReplica.pronta);
    final nativo = Completer<void>();
    var simultaneos = 0;
    var maximo = 0;

    final sync = coordenador.executarSincronizacao(() async {
      simultaneos++;
      if (simultaneos > maximo) maximo = simultaneos;
      await nativo.future;
      simultaneos--;
    });
    await expectLater(
      sync.timeout(const Duration(milliseconds: 1)),
      throwsA(isA<TimeoutException>()),
    );
    expect(coordenador.syncReservado, isTrue);
    await expectLater(coordenador.executarSincronizacao(() async {}),
        throwsA(isA<ReplicaNaoProntaParaEscrita>()));
    await expectLater(coordenador.executarEscrita(() async {}),
        throwsA(isA<ReplicaNaoProntaParaEscrita>()));
    expect(maximo, 1);

    nativo.complete();
    await sync;
    expect(coordenador.syncReservado, isFalse);
    expect(coordenador.estado, EstadoReplica.pronta);
  });

  test('sync reservado espera operação composta que já entrou na fila',
      () async {
    final coordenador = CoordenadorReplica()
      ..definirEstado(EstadoReplica.pronta);
    final liberaEscrita = Completer<void>();
    final ordem = <String>[];
    final escrita = coordenador.executarEscrita(() async {
      ordem.add('escrita-inicio');
      await liberaEscrita.future;
      ordem.add('escrita-fim');
    });
    final sync = coordenador.executarSincronizacao(() async {
      ordem.add('sync');
    });
    await Future<void>.delayed(Duration.zero);
    expect(ordem, ['escrita-inicio']);
    liberaEscrita.complete();
    await Future.wait([escrita, sync]);
    expect(ordem, ['escrita-inicio', 'escrita-fim', 'sync']);
  });


  group('recuperação só sai por recuperação explícita', () {
    test('init não destrava: conectando e pronta viram no-op', () async {
      final coordenador = CoordenadorReplica()..exigirRecuperacao();

      // A sequência exata de um _init(): anuncia conectando e conclui pronta.
      coordenador
        ..definirEstado(EstadoReplica.conectando)
        ..definirEstado(EstadoReplica.pronta);

      expect(coordenador.estado, EstadoReplica.recuperacaoNecessaria);
      expect(coordenador.recuperacaoTravada, isTrue);
      var escreveu = false;
      await expectLater(
        coordenador.executarEscrita(() async => escreveu = true),
        throwsA(isA<ReplicaNaoProntaParaEscrita>()),
      );
      expect(escreveu, isFalse);
    });

    test('retry de sync não destrava nem chega a rodar', () async {
      final coordenador = CoordenadorReplica()..exigirRecuperacao();
      var rodou = false;

      await expectLater(
        coordenador.executarSincronizacao(() async => rodou = true),
        throwsA(isA<ReplicaNaoProntaParaEscrita>()),
      );

      expect(rodou, isFalse, reason: 'sync numa réplica divergente repete o '
          'erro que a condenou');
      expect(coordenador.estado, EstadoReplica.recuperacaoNecessaria);
    });

    test('sync que descobre a divergência no meio não é desfeito pelo restauro',
        () async {
      final coordenador = CoordenadorReplica()
        ..definirEstado(EstadoReplica.pronta);

      final ok = await coordenador.executarSincronizacao(() async {
        coordenador.exigirRecuperacao();
        return false;
      });

      expect(ok, isFalse);
      // Era aqui que o estado voltava para `pronta` e o portão reabria.
      expect(coordenador.estado, EstadoReplica.recuperacaoNecessaria);
      expect(coordenador.syncReservado, isFalse);
      await expectLater(coordenador.executarEscrita(() async {}),
          throwsA(isA<ReplicaNaoProntaParaEscrita>()));
    });

    test('timeout do bootstrap não destrava enquanto o nativo continua',
        () async {
      final coordenador = CoordenadorReplica()
        ..definirEstado(EstadoReplica.basePendente);
      final nativo = Completer<void>();

      final bootstrap = coordenador.executarSincronizacao(() async {
        coordenador.exigirRecuperacao();
        await nativo.future;
      });
      await expectLater(
        bootstrap.timeout(const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );

      // Prazo do chamador estourado, sync nativo ainda vivo: o portão continua
      // fechado e ninguém escreve por baixo dele.
      expect(coordenador.estado, EstadoReplica.recuperacaoNecessaria);
      await expectLater(coordenador.executarEscrita(() async {}),
          throwsA(isA<ReplicaNaoProntaParaEscrita>()));

      nativo.complete();
      await bootstrap;
      expect(coordenador.estado, EstadoReplica.recuperacaoNecessaria,
          reason: 'o fim do nativo também não pode restaurar basePendente');
    });

    test('concluirRecuperacao é a única saída', () async {
      final coordenador = CoordenadorReplica()..exigirRecuperacao();

      coordenador.concluirRecuperacao();
      expect(coordenador.recuperacaoTravada, isFalse);
      expect(coordenador.estado, EstadoReplica.desconectada);

      coordenador.definirEstado(EstadoReplica.pronta);
      var escreveu = false;
      await coordenador.executarEscrita(() async => escreveu = true);
      expect(escreveu, isTrue);
    });
  });
}
