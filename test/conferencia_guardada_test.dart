import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/modo_conferencia_service.dart';

// A conferência do dia guardada no serviço. Cada pedido varria contagem_itens
// (a tabela do app de contagem, que só cresce) mais quatro consultas, e a loja
// pedia a cada volta de gôndola, o galpão e o barracão a cada aviso de dados.

ModoConferenciaResultado _resultado(int pendentes) => ModoConferenciaResultado(
  estruturas: const {},
  semEndereco: const [],
  totalProdutos: pendentes,
  totalFiltradosDeposito: 0,
);

void main() {
  final servico = ModoConferenciaService();
  late int leituras;
  late Future<ModoConferenciaResultado> Function() leitura;

  setUp(() {
    leituras = 0;
    leitura = () async => _resultado(leituras);
    servico.esquecer();
    servico.leitorParaTeste = () {
      leituras++;
      return leitura();
    };
  });

  tearDown(() {
    servico.leitorParaTeste = null;
    servico.esquecer();
  });

  test('dentro de um minuto, a guardada responde sem ler', () async {
    await servico.buscarConferenciaDoDia();
    await servico.buscarConferenciaDoDia();
    await servico.buscarConferenciaDoDia();
    expect(leituras, 1);
  });

  test('pedidos ao mesmo tempo dividem a mesma leitura', () async {
    final lenta = Completer<ModoConferenciaResultado>();
    leitura = () => lenta.future;
    final a = servico.buscarConferenciaDoDia();
    final b = servico.buscarConferenciaDoDia();
    lenta.complete(_resultado(3));
    expect((await a).totalProdutos, 3);
    expect((await b).totalProdutos, 3);
    expect(leituras, 1);
  });

  test('forçar lê na hora e não pega carona na leitura antiga', () async {
    final antiga = Completer<ModoConferenciaResultado>();
    leitura = () => antiga.future;
    final primeira = servico.buscarConferenciaDoDia();

    leitura = () async => _resultado(9);
    final forcada = await servico.buscarConferenciaDoDia(forcar: true);
    expect(forcada.totalProdutos, 9);
    expect(leituras, 2);

    // A antiga chega depois e não desfaz a forçada.
    antiga.complete(_resultado(1));
    await primeira;
    expect((await servico.buscarConferenciaDoDia()).totalProdutos, 9);
    expect(leituras, 2);
  });

  test('esquecer (volta ao app) faz a próxima busca ler', () async {
    await servico.buscarConferenciaDoDia();
    servico.esquecer();
    await servico.buscarConferenciaDoDia();
    expect(leituras, 2);
  });

  test('falha não fica guardada como "nada pendente"', () async {
    leitura = () async => throw StateError('sem rede');
    final r = await servico.buscarConferenciaDoDia();
    expect(r.vazioHoje, isTrue);

    leitura = () async => _resultado(4);
    expect((await servico.buscarConferenciaDoDia()).totalProdutos, 4);
    expect(leituras, 2);
  });
}
