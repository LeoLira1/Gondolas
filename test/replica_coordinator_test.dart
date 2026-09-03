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
}
