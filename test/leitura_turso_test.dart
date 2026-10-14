import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/consulta_cache.dart';
import 'package:gondola_camda/galpao_saldo.dart';

// O Turso cobra por linha VARRIDA: cada ida de consulta de tabela inteira é a
// tabela inteira na conta, mude ela ou não. Estes testes amarram o que segura
// essas idas — a janela de cada consulta, a volta ao app que só relê o que
// venceu e o saldo do galpão montado das cópias, sem banco.

ConsultaCache _cache({void Function()? aoAtualizar}) => ConsultaCache(
      lerDisco: (_) async => null,
      gravarDisco: (_, __) async {},
      aoAtualizar: aoAtualizar ?? () {},
    );

/// Uma "tabela" que conta quantas vezes foi lida.
class _Tabela {
  int leituras = 0;
  LinhasConsulta linhas;
  _Tabela(this.linhas);

  Future<LinhasConsulta> ler() async {
    leituras++;
    return [for (final r in linhas) Map<String, dynamic>.from(r)];
  }
}

void main() {
  group('janela por consulta', () {
    test('dentro da janela a cópia responde sem ir ao banco', () async {
      final cache = _cache();
      final mestre = _Tabela([
        {'codigo': 'BORAL', 'qtd_sistema': 145},
      ]);
      await cache.ler('mestre', mestre.ler, janela: const Duration(hours: 1));
      expect(mestre.leituras, 1);
      for (var i = 0; i < 20; i++) {
        await cache.ler('mestre', mestre.ler, janela: const Duration(hours: 1));
      }
      await Future<void>.delayed(Duration.zero);
      // Vinte saldos calculados, uma leitura da tabela.
      expect(mestre.leituras, 1);
    });

    test('vencida a janela, serve a cópia e relê por trás', () async {
      final cache = _cache();
      final tabela = _Tabela([
        {'x': 1},
      ]);
      await cache.ler('t', tabela.ler, janela: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final servida = await cache.ler('t', tabela.ler, janela: Duration.zero);
      expect(servida.single['x'], 1);
      await Future<void>.delayed(Duration.zero);
      expect(tabela.leituras, 2);
    });

    test('expirar manda a próxima leitura ao banco mesmo dentro da janela',
        () async {
      final cache = _cache();
      final tabela = _Tabela([
        {'x': 1},
      ]);
      const janela = Duration(hours: 1);
      await cache.ler('t', tabela.ler, janela: janela);
      cache.expirar('t');
      await cache.ler('t', tabela.ler, janela: janela);
      await Future<void>.delayed(Duration.zero);
      expect(tabela.leituras, 2);
    });
  });

  group('volta ao app', () {
    test('soVencidas relê só as consultas cuja janela passou', () async {
      final cache = _cache();
      final grande = _Tabela([
        {'x': 1},
      ]);
      final pequena = _Tabela([
        {'y': 1},
      ]);
      await cache.ler('grande', grande.ler, janela: const Duration(hours: 1));
      await cache.ler('pequena', pequena.ler, janela: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      await cache.atualizar(soVencidas: true);
      expect(grande.leituras, 1,
          reason: 'estoque_mestre não relê a cada desbloqueio');
      expect(pequena.leituras, 2);

      // O Sincronizar continua pedindo tudo.
      await cache.atualizar();
      expect(grande.leituras, 2);
      expect(pequena.leituras, 3);
    });
  });

  group('tabela que o app não grava', () {
    test('resposta que chega depois de um commit vale', () async {
      final cache = _cache();
      final rede = Completer<LinhasConsulta>();
      final leitura = cache.ler(
        'mestre',
        () => rede.future,
        forceRefresh: true,
        somenteLeitura: true,
      );
      await Future<void>.delayed(Duration.zero);
      // Um lançamento no galpão é confirmado no meio da leitura do catálogo.
      await cache.confirmar('galpao', [
        {'posicao': 52},
      ]);
      rede.complete([
        {'codigo': 'NOVO'},
      ]);
      expect((await leitura).single['codigo'], 'NOVO');
      final depois = await cache.ler(
        'mestre',
        () async => throw StateError('não devia ir ao banco'),
        janela: const Duration(hours: 1),
        somenteLeitura: true,
      );
      expect(depois.single['codigo'], 'NOVO');
    });

    test('tabela gravada pelo app continua protegida pela geração', () async {
      final cache = _cache();
      await cache.confirmar('quantidades', [
        {'q': 'gravado'},
      ]);
      final rede = Completer<LinhasConsulta>();
      final leitura = cache.ler(
        'quantidades',
        () => rede.future,
        forceRefresh: true,
      );
      await Future<void>.delayed(Duration.zero);
      await cache.confirmar('quantidades', [
        {'q': 'depois do commit'},
      ]);
      rede.complete([
        {'q': 'resposta velha'},
      ]);
      expect((await leitura).single['q'], 'depois do commit');
    });
  });

  group('releitura por local depois de gravar', () {
    test('troca só as linhas do local gravado', () async {
      final cache = _cache();
      await cache.confirmar('quantidades', [
        {
          'produto_codigo': 'BORAL',
          'local_tipo': 'galpao',
          'local_num': 52,
          'quantidade': 10
        },
        {
          'produto_codigo': 'BORAL',
          'local_tipo': 'galpao',
          'local_num': 7,
          'quantidade': 30
        },
        {
          'produto_codigo': 'BORAL',
          'local_tipo': 'gondola',
          'local_num': 52,
          'quantidade': 4
        },
      ]);
      // O lote empilhou um segundo palete na posição 52: o espelho dela
      // volta do servidor com duas linhas, e só ela é trocada na cópia.
      await cache.atualizarParte(
        'quantidades',
        (r) => r['local_tipo'] == 'galpao' && {52}.contains(r['local_num']),
        [
          {
            'produto_codigo': 'BORAL',
            'local_tipo': 'galpao',
            'local_num': 52,
            'quantidade': 10
          },
          {
            'produto_codigo': 'BORAL',
            'local_tipo': 'galpao',
            'local_num': 52,
            'quantidade': 90
          },
        ],
      );
      final linhas = await cache.ler(
        'quantidades',
        () async => throw StateError('não devia ir ao banco'),
        janela: const Duration(hours: 1),
      );
      expect(linhas, hasLength(4));
      // Gôndola 52 intacta, galpão 7 intacto, galpão 52 com os dois paletes.
      expect(enderecadoPorCodigo(linhas), {'BORAL': 134});
    });
  });

  group('saldo do galpão a partir das cópias', () {
    test('mestrePorCodigo normaliza o código e lê nome e sistema', () {
      final mestre = mestrePorCodigo([
        {'codigo': ' us254185 ', 'produto': 'BORAL', 'qtd_sistema': 171},
        {'codigo': '254185', 'produto': 'BORAL', 'qtd_sistema': 388},
        {'codigo': '', 'produto': 'SEM CODIGO', 'qtd_sistema': 1},
        {'codigo': 'X', 'produto': null, 'qtd_sistema': null},
      ]);
      expect(mestre.keys, unorderedEquals(['US254185', '254185', 'X']));
      expect(mestre['US254185']!.qtdSistema, 171);
      expect(mestre['X']!.nome, '');
      expect(mestre['X']!.qtdSistema, 0);
    });

    test('enderecadoPorCodigo soma todos os locais e grafias do código', () {
      final total = enderecadoPorCodigo([
        {'produto_codigo': '254185', 'local_tipo': 'galpao', 'quantidade': 90},
        {'produto_codigo': '254185', 'local_tipo': 'gondola', 'quantidade': 12},
        {'produto_codigo': ' 254185', 'local_tipo': 'estante', 'quantidade': 3},
        {'produto_codigo': 'LUVA', 'local_tipo': 'galpao', 'quantidade': 30.5},
        {'produto_codigo': null, 'local_tipo': 'galpao', 'quantidade': 1},
      ]);
      expect(total, {'254185': 105, 'LUVA': 30.5});
    });

    test('mesma conta de antes: sistema e endereçado somam os irmãos', () {
      final mestre = mestrePorCodigo([
        {'codigo': '254185', 'produto': 'BORAL', 'qtd_sistema': 388},
        {'codigo': 'US254185', 'produto': 'BORAL', 'qtd_sistema': 171},
      ]);
      final saldos = montarSaldos(
        codigos: ['254185'],
        grupos: {
          '254185': {'254185', 'US254185'},
        },
        sistemaPorCodigo: {
          for (final e in mestre.entries) e.key: e.value.qtdSistema,
        },
        enderecadoPorCodigo: enderecadoPorCodigo([
          {'produto_codigo': '254185', 'quantidade': 300},
          {'produto_codigo': 'US254185', 'quantidade': 200},
        ]),
      );
      expect(saldos['254185']!.qtdSistema, 559);
      expect(saldos['254185']!.enderecado, 500);
      expect(saldos['254185']!.quantoFalta, 59);
    });
  });
}
