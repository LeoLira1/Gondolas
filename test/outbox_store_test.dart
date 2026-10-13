import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/outbox.dart';
import 'package:gondola_camda/outbox_store.dart';

void main() {
  test('store fechada não aceita gravação nem finge fila vazia', () async {
    final store = OutboxStore();
    final m = MutacaoOutbox(
      uuid: 'teste',
      operacao: 'teste',
      alvo: const AlvoMutacao(tabela: 'teste', chave: {'id': 1}),
      estadoAnterior: null,
      estadoFinal: const {'quantidade': 1},
      criadoEm: DateTime(2026),
      dispositivo: 'teste',
    );
    await expectLater(store.registrar(m), throwsStateError);
    await expectLater(store.quantidadeNaoConfirmada(), throwsStateError);
    await expectLater(store.naoConfirmadas(), throwsStateError);
    await expectLater(store.paraRevisao(), throwsStateError);
    await expectLater(
      store.marcar('teste', EstadoMutacao.confirmada),
      throwsStateError,
    );
  });
}
