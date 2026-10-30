import 'dart:async';

import '../lib/consulta_cache.dart';

void conferir(bool ok, String mensagem) {
  if (!ok) throw StateError(mensagem);
}

Future<void> main() async {
  final disco = <String, String>{'banco_a_estante': '[{"produto":"antigo"}]'};
  var avisos = 0;
  final cache = ConsultaCache(
    lerDisco: (k) async => disco[k],
    gravarDisco: (k, v) async {
      disco[k] = v;
    },
    aoAtualizar: () {
      avisos++;
    },
  );
  final rede = Completer<LinhasConsulta>();
  var consultas = 0;
  Future<LinhasConsulta> consultar() {
    consultas++;
    return rede.future;
  }

  final inicial = await cache.ler('banco_a_estante', consultar);
  conferir(
    inicial.first['produto'] == 'antigo',
    'Cache deve aparecer antes da rede',
  );
  await Future<void>.delayed(Duration.zero);
  final repetida = await cache.ler('banco_a_estante', consultar);
  conferir(
    consultas == 1 && repetida.first['produto'] == 'antigo',
    'Coalescer revalidações',
  );
  await cache.confirmar('banco_a_estante', [
    {'produto': 'gravado'},
  ]);
  rede.complete([
    {'produto': 'resposta velha'},
  ]);
  await Future<void>.delayed(Duration.zero);
  final depois = await cache.ler('banco_a_estante', consultar);
  conferir(
    depois.first['produto'] == 'gravado',
    'Resposta anterior ao commit não pode desfazer a gravação',
  );
  conferir(
    disco['banco_a_estante']!.contains('gravado'),
    'Disco deve preservar commit',
  );
  conferir(avisos == 0, 'Resposta velha não deve notificar telas');

  final reiniciado = ConsultaCache(
    lerDisco: (k) async => disco[k],
    gravarDisco: (k, v) async {
      throw StateError('disco cheio');
    },
    aoAtualizar: () {
      avisos++;
    },
  );
  Future<LinhasConsulta> falhar() async {
    throw StateError('rede indisponível');
  }

  final offline = await reiniciado.ler('banco_a_estante', falhar);
  conferir(
    offline.first['produto'] == 'gravado',
    'Reabertura offline mantém cache confirmado',
  );
  await Future<void>.delayed(Duration.zero);
  final outro = await reiniciado.ler('banco_b_estante', falhar);
  conferir(outro.isEmpty, 'Nunca misturar bancos');
  await reiniciado.confirmar('banco_a_estante', [
    {'produto': 'confirmado online'},
  ]);
  conferir(
    (await reiniciado.ler('banco_a_estante', falhar)).first['produto'] ==
        'confirmado online',
    'Falha no disco não pode desfazer sucesso online',
  );
  var falhou = false;
  try {
    await reiniciado.ler('banco_a_estante', falhar, forceRefresh: true);
  } catch (_) {
    falhou = true;
  }
  conferir(falhou, 'Atualização explícita deve reportar falha');

  var semDadosFalhou = false;
  try {
    await reiniciado.ler('banco_sem_copia', falhar, falharSemCache: true);
  } catch (_) {
    semDadosFalhou = true;
  }
  conferir(semDadosFalhou, 'Falha sem cópia não pode parecer quantidade zero');
  conferir(
    (await reiniciado.ler(
          'banco_a_estante',
          falhar,
          falharSemCache: true,
        )).first['produto'] ==
        'confirmado online',
    'Modo estrito ainda mostra cópia disponível sem rede',
  );

  final vazio = ConsultaCache(
    lerDisco: (_) async => '[]',
    gravarDisco: (_, __) async {},
    aoAtualizar: () {},
  );
  final pendente = Completer<LinhasConsulta>();
  conferir(
    (await vazio.ler('vazia', () => pendente.future)).isEmpty,
    'Estante vazia também é cache válido',
  );
  pendente.complete([]);
  await Future<void>.delayed(Duration.zero);

  // Recarga do Sincronizar: uma consulta que falha não derruba as outras, e
  // elas rodam uma de cada vez (sem fila disputando a mesma conexão).
  final recarga = ConsultaCache(
    lerDisco: (_) async => null,
    gravarDisco: (_, __) async {},
    aoAtualizar: () {},
  );
  var simultaneas = 0;
  var maxSimultaneas = 0;
  Future<LinhasConsulta> Function() lenta(String nome) => () async {
    simultaneas++;
    if (simultaneas > maxSimultaneas) maxSimultaneas = simultaneas;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    simultaneas--;
    return [
      {'v': nome},
    ];
  };
  await recarga.ler('a', lenta('a1'));
  await recarga.ler('b', falhar);
  await recarga.ler('c', lenta('c1'));
  maxSimultaneas = 0;
  final semAtualizar = await recarga.atualizar();
  conferir(semAtualizar == 1, 'Só a consulta que falhou conta como falha');
  conferir(maxSimultaneas == 1, 'Recarga deve rodar uma consulta por vez');
  conferir(!recarga.atualizando, 'Recarga com falha libera a trava');
  final esgotado = await recarga.atualizar(prazo: Duration.zero);
  conferir(esgotado == 3, 'Prazo esgotado conta as que ficaram para depois');
  print(
    'Cache: leitura imediata, deduplicação, corrida com commit, reinício, bancos separados, falhas e vazio OK',
  );
}
