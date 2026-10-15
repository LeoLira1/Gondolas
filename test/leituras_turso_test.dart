import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/leituras_turso.dart';

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

    test('sem o tamanho, fica o devolvido e o tipo é apontado', () {
      final sem = <String>{};
      expect(
        estimarVarridas(tipos, {'contagem_itens': 2000}, semTamanho: sem),
        8000 + 3 * 2000 + 900,
      );
      expect(sem, {'ultima_contagem_ciclico_v1'});
    });
  });
}
