// Local checks without Flutter or network. Run: dart tool/verify_recovery.dart
import 'dart:async';
import 'dart:convert';

import '../lib/outbox.dart';
import '../lib/replica_coordinator.dart';
import '../lib/rack_identity.dart';
import '../lib/rack_model.dart';
import '../lib/galpao_pilhas.dart';

void check(bool ok, String message) {
  if (!ok) throw StateError(message);
}

Future<void> main(List<String> args) async {
  if (args.contains('--sql')) {
    print(jsonEncode(migracaoRackIdentidade));
    return;
  }
  final pilha = [
    for (var i = 1; i <= 3; i++)
      RackGalpao(
        rackUuid: 'rack-$i',
        posicao: 1,
        ordem: i,
        produtoCodigo: 'TESTE',
        quantidade: 10,
      ),
  ];
  final desceu = pilhaAposEsvaziar(pilha, 1);
  check(
    desceu[0].rackUuid == 'rack-2' && desceu[0].ordem == 1,
    'Renumerar não pode trocar a identidade do rack do meio',
  );
  check(
    desceu[1].rackUuid == 'rack-3' && desceu[1].ordem == 2,
    'O rack do topo preserva a identidade',
  );
  final ajustada = pilhaAposAjustar(desceu, 1, 7);
  check(
    ajustada[0].rackUuid == 'rack-2' && ajustada[0].quantidade == 7,
    'Ajustar quantidade preserva a identidade',
  );
  check(
    pilha[1].ordem == 2 && pilha[1].quantidade == 10,
    'As operações não alteram o snapshot anterior',
  );
  print('PASS: identidade em retirada, renumeração e ajuste');

  final m = MutacaoOutbox(
    uuid: gerarUuidV4(),
    operacao: 'estoqueLocalizado.upsertQuantidade',
    alvo: const AlvoMutacao(tabela: 'estoque_localizado', chave: {'id': 1}),
    estadoAnterior: const {'quantidade': 10},
    estadoFinal: const {'quantidade': 7},
    criadoEm: DateTime(2026),
    dispositivo: 'teste',
    auditoria: const {'origem': 'teste', 'qtd_nova': 7},
  );
  check(!mutacaoExigeRevisaoManual(m), 'Alteração com auditoria é elegível');
  check(
    mutacaoExigeRevisaoManual(m.copyWith(estado: EstadoMutacao.conflito)),
    'Conflito não pode ser reaplicado na próxima tentativa',
  );
  check(
    mutacaoExigeRevisaoManual(m.copyWith(estado: EstadoMutacao.revisaoManual)),
    'Conferência não pode ser reaplicada na próxima tentativa',
  );
  check(
    m.copyWith(estado: EstadoMutacao.confirmada).auditoria?['qtd_nova'] == 7,
    'Auditoria não pode sumir ao mudar o estado',
  );
  check(
    decidirReaplicacao(
          remoto: {'quantidade': 8},
          anterior: m.estadoAnterior,
          estadoFinal: m.estadoFinal,
          colunas: m.colunasComparadas,
        ) ==
        DecisaoReaplicacao.conflito,
    'Alteração concorrente precisa de conferência',
  );
  check(
    operacaoExigeRevisaoManual('galpao.esvaziar'),
    'UUID não autoriza reaplicar exclusão sem refazer a pilha e o espelho',
  );
  print('PASS: auditoria preservada, conflitos e operação composta');

  final c = CoordenadorReplica()..definirEstado(EstadoReplica.pronta);
  final liberar = Completer<void>();
  final ordem = <String>[];
  final escrita = c.executarEscrita(() async {
    ordem.add('escrita');
    await liberar.future;
  });
  final recuperacao = c.executarRecuperacao(() async {
    ordem.add('recuperacao');
  });
  var recusou = false;
  try {
    await c.executarEscrita(() async => ordem.add('indevida'));
  } on ReplicaNaoProntaParaEscrita {
    recusou = true;
  }
  check(recusou, 'Recuperação reservada deve recusar novas gravações');
  liberar.complete();
  await escrita;
  await recuperacao;
  check(
    ordem.join(',') == 'escrita,recuperacao',
    'Recuperação espera a gravação terminar',
  );
  c.exigirRecuperacao();
  try {
    await c.executarRecuperacao(
      () async => throw StateError('falha de proteção'),
    );
  } catch (_) {}
  check(
    c.recuperacaoTravada && !c.syncReservado,
    'Falha mantém a trava e libera a reserva',
  );
  await c.executarRecuperacao(() async => c.concluirRecuperacao());
  check(!c.recuperacaoTravada, 'Recuperação explícita concluída destrava');
  print('PASS: exclusão mútua, falha de recuperação e liberação');
}
