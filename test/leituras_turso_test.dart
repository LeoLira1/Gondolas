import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/leituras_turso.dart';
import 'package:gondola_camda/turso_service.dart';

// O diagnóstico de leituras conta, por dia e por tipo, o que este aparelho
// pediu ao Turso — o gráfico do Turso é da conta inteira.

void main() {
  test('conta por dia e por tipo, e junta com o que estava no disco',
      () async {
    String? disco =
        '{"2026-10-14":{"galpao":[3,90]},"2026-10-15":{"galpao":[1,30]}}';
    var agora = DateTime(2026, 10, 15, 9);
    final contador = ContadorDeLeituras(
      carregarDisco: () async => disco,
      gravarDisco: (t) async => disco = t,
      agora: () => agora,
    );
    contador.registrar('galpao', 30);
    contador.registrar('quantidades_detalhes_v2', 4000);
    agora = DateTime(2026, 10, 16, 0, 5);
    contador.registrar('galpao', 30);

    final dias = await contador.dias();
    expect(dias.map((d) => d.dia), ['2026-10-16', '2026-10-15', '2026-10-14']);
    final dia15 = dias[1].tipos;
    expect(dia15['galpao']!.consultas, 2);
    expect(dia15['galpao']!.linhas, 60);
    expect(dia15['quantidades_detalhes_v2']!.linhas, 4000);
    expect(dias[2].tipos['galpao']!.consultas, 3);

    await contador.gravarJa();
    expect(disco, contains('"2026-10-16":{"galpao":[1,30]}'));
  });

  test('grava no máximo uma vez por respiro', () {
    fakeAsync((async) {
      var gravacoes = 0;
      final contador = ContadorDeLeituras(
        carregarDisco: () async => null,
        gravarDisco: (_) async => gravacoes++,
        respiro: const Duration(seconds: 60),
      );
      for (var i = 0; i < 50; i++) {
        contador.registrar('galpao', 10);
      }
      async.elapse(const Duration(seconds: 59));
      expect(gravacoes, 0);
      async.elapse(const Duration(seconds: 2));
      expect(gravacoes, 1);
    });
  });

  test('guarda só os últimos dias', () async {
    String? disco;
    var agora = DateTime(2026, 10, 1);
    final contador = ContadorDeLeituras(
      carregarDisco: () async => disco,
      gravarDisco: (t) async => disco = t,
      agora: () => agora,
      diasGuardados: 3,
    );
    for (var d = 1; d <= 5; d++) {
      agora = DateTime(2026, 10, d);
      contador.registrar('galpao', 1);
    }
    await contador.gravarJa();
    expect((await contador.dias()).map((d) => d.dia), [
      '2026-10-05',
      '2026-10-04',
      '2026-10-03',
    ]);
  });

  test('guarda pela data: um dia de meses atrás sai, mesmo sendo dos 8 '
      'mais novos', () async {
    String? disco = '{"2026-06-01":{"galpao":[1,10]},'
        '"2026-10-09":{"galpao":[1,10]},"2026-10-08":{"galpao":[1,10]}}';
    final contador = ContadorDeLeituras(
      carregarDisco: () async => disco,
      gravarDisco: (t) async => disco = t,
      agora: () => DateTime(2026, 10, 15, 9),
    );
    // 8 dias: de 08/10 a 15/10.
    expect((await contador.dias()).map((d) => d.dia), [
      '2026-10-09',
      '2026-10-08',
    ]);
    contador.registrar('galpao', 1);
    await contador.gravarJa();
    expect(disco, isNot(contains('2026-06-01')));
    expect(disco, contains('2026-10-08'));
  });

  test('consultas: 0 soma linhas sem inventar consulta', () async {
    final contador = ContadorDeLeituras(
      carregarDisco: () async => null,
      gravarDisco: (_) async {},
    );
    contador.registrar('medicao_tabelas', 1);
    contador.registrar('medicao_tabelas', 4999, consultas: 0);
    final l = (await contador.dias()).single.tipos['medicao_tabelas']!;
    expect(l.consultas, 1);
    expect(l.linhas, 5000);
  });

  test('em segundo plano grava logo, sem esperar o respiro', () {
    fakeAsync((async) {
      var gravacoes = 0;
      final contador = ContadorDeLeituras(
        carregarDisco: () async => null,
        gravarDisco: (_) async => gravacoes++,
      );
      contador.registrar('galpao', 10);
      contador.emPrimeiroPlano = false; // grava o pendente
      async.flushMicrotasks();
      expect(gravacoes, 1);
      // Leitura que terminou já com o app em segundo plano.
      contador.registrar('quantidades_detalhes_v2', 4000);
      async.elapse(Duration.zero);
      expect(gravacoes, 2);
      contador.emPrimeiroPlano = true;
      contador.registrar('galpao', 10);
      async.elapse(const Duration(seconds: 59));
      expect(gravacoes, 2);
      async.elapse(const Duration(seconds: 2));
      expect(gravacoes, 3);
    });
  });

  test('zerar apaga também do disco', () async {
    String? disco = '{"2026-10-14":{"galpao":[3,90]}}';
    final contador = ContadorDeLeituras(
      carregarDisco: () async => disco,
      gravarDisco: (t) async => disco = t,
    );
    contador.registrar('galpao', 1);
    await contador.zerar();
    expect(await contador.dias(), isEmpty);
    expect(disco, '{}');
  });

  test('disco ilegível não derruba a contagem', () async {
    final contador = ContadorDeLeituras(
      carregarDisco: () async => 'não é json',
      gravarDisco: (_) async {},
    );
    contador.registrar('galpao', 5);
    expect((await contador.dias()).single.tipos['galpao']!.linhas, 5);
  });

  group('estimativa das varridas', () {
    final tipos = {
      'quantidades_detalhes_v2': LeiturasDoTipo(2, 8000),
      'ultima_contagem_itens_confirmado_em': LeiturasDoTipo(3, 600),
      'ultima_contagem_ciclico_v1': LeiturasDoTipo(3, 900),
    };

    test('agrupadas contam a tabela inteira por consulta', () {
      expect(
        estimarVarridas(tipos, {
          'contagem_itens': 2000,
          'inventario_cicli': 10000,
        }),
        8000 + 3 * 2000 + 3 * 10000,
      );
    });

    test('estocados filtra sem índice: varre materiais_terceiros', () {
      expect(tabelaVarridaPor('estocados'), 'materiais_terceiros');
      expect(tabelasVarridas, contains('materiais_terceiros'));
      expect(
        estimarVarridas({'estocados': LeiturasDoTipo(20, 3000)}, {
          'materiais_terceiros': 3000,
        }),
        60000,
      );
    });

    test('toda tabela varrida é medida', () {
      for (final tipo in [
        'ultima_contagem_itens_confirmado_em',
        'ultima_contagem_ciclico_v1',
        'baixa_divergencias',
        'estocados',
      ]) {
        expect(tabelasVarridas, contains(tabelaVarridaPor(tipo)));
      }
    });

    test('sem o tamanho, fica o devolvido e o tipo é apontado', () {
      final sem = <String>{};
      expect(
        estimarVarridas(tipos, {'contagem_itens': 2000}, semTamanho: sem),
        8000 + 3 * 2000 + 900,
      );
      expect(sem, {'ultima_contagem_ciclico_v1'});
    });
  });

  test('medição que falhou no meio guarda o que mediu por cima da anterior',
      () {
    expect(
      TursoService.juntarMedidas(
        {'contagem_itens': 100, 'inventario_cicli': 900, 'estoque_mestre': 7},
        {'contagem_itens': 150, 'materiais_terceiros': 40},
      ),
      // inventario_cicli falhou agora: fica a medida anterior; estoque_mestre
      // não é mais medida.
      {'contagem_itens': 150, 'inventario_cicli': 900, 'materiais_terceiros': 40},
    );
  });
}
