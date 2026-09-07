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
  print(
    'Cache: leitura imediata, deduplicação, corrida com commit, reinício, bancos separados, falhas e vazio OK',
  );
}
