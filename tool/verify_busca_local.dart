import 'dart:async';

import '../lib/busca_local.dart';
import '../lib/consulta_cache.dart';

void verificar(bool valor, String motivo) {
  if (!valor) throw StateError(motivo);
}

Future<void> main() async {
  final disco = <String, String>{
    'banco_a':
        '[{"produto_codigo":"001","produto_nome":"BORAL","estante_num":1,"nivel":0},'
        '{"produto_codigo":"002","produto_nome":"OUTRO PRODUTO","estante_num":2,"nivel":0}]',
  };
  final cache = ConsultaCache(
    lerDisco: (k) async => disco[k],
    gravarDisco: (k, v) async {
      disco[k] = v;
    },
    aoAtualizar: () {},
  );
  var chamadas = 0;
  final resposta = Completer<LinhasConsulta>();
  Future<LinhasConsulta> rede() {
    chamadas++;
    return resposta.future;
  }

  final linhas = await cache.ler('banco_a', rede);
  verificar(
    filtrarBuscaLocal(linhas, 'bor').single['produto_codigo'] == '001',
    'Nome ignora caixa',
  );
  verificar(
    filtrarBuscaLocal(linhas, '002').single['estante_num'] == 2,
    'Código encontra posição',
  );
  verificar(
    filtrarBuscaLocal(linhas, 'outro').length == 1,
    'Termo novo usa mesma cópia completa',
  );
  await Future<void>.delayed(Duration.zero);
  await cache.ler('banco_a', rede);
  verificar(chamadas == 1, 'Não faz consultas por termo nem duplica download');
  await cache.atualizarParte('banco_a', (r) => r['estante_num'] == 1, [
    {
      'produto_codigo': '003',
      'produto_nome': 'NOVO',
      'estante_num': 1,
      'nivel': 0,
    },
  ]);
  resposta.complete(linhas);
  await Future<void>.delayed(Duration.zero);
  final atualizado = await cache.ler('banco_a', rede);
  verificar(
    filtrarBuscaLocal(atualizado, 'bor').isEmpty,
    'Remove posição antiga',
  );
  verificar(
    filtrarBuscaLocal(atualizado, 'novo').length == 1,
    'Resposta atrasada não desfaz posição confirmada',
  );
  verificar(
    filtrarBuscaLocal(atualizado, 'outro').length == 1,
    'Preserva outras estantes',
  );
  await cache.atualizarParte('banco_a', (r) => r['estante_num'] == 1, []);
  verificar(
    filtrarBuscaLocal(await cache.ler('banco_a', rede), 'novo').isEmpty,
    'Limpeza remove do índice',
  );
  await cache.atualizarParte('ausente', (_) => true, linhas);
  verificar(
    !disco.containsKey('ausente'),
    'Não publica uma cópia parcial como completa',
  );
  final duplicadas = [
    linhas.first,
    {...linhas.first, 'slot': 2},
    {...linhas.first, 'estante_num': 3},
  ];
  verificar(
    filtrarBuscaLocal(duplicadas, 'bor').length == 2,
    'Agrupa slots mantendo endereços distintos',
  );
  print(
    'Busca local: termos novos, rede lenta, atualização confirmada, remoção e deduplicação OK',
  );
}
