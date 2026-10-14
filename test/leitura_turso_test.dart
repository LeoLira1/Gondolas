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

ConsultaCache _cacheComDisco(
  Map<String, String> disco, {
  void Function()? aoAtualizar,
}) =>
    ConsultaCache(
      lerDisco: (k) async => disco[k],
      gravarDisco: (k, v) async => disco[k] = v,
      aoAtualizar: aoAtualizar ?? () {},
    );

/// Espera as gravações em disco e as releituras em segundo plano.
Future<void> _assentar() => Future<void>.delayed(const Duration(milliseconds: 5));

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

  group('janela que sobrevive ao app fechado', () {
    const janela = Duration(hours: 1);

    test('reabrir dentro da janela não vai ao banco', () async {
      final disco = <String, String>{};
      final mestre = _Tabela([
        {'codigo': 'BORAL'},
      ]);
      await _cacheComDisco(disco).ler('mestre', mestre.ler, janela: janela);
      await _assentar();
      expect(mestre.leituras, 1);

      // O Android matou o app: uma ConsultaCache nova lê o mesmo disco.
      final reaberto = _cacheComDisco(disco);
      final linhas = await reaberto.ler('mestre', mestre.ler, janela: janela);
      await _assentar();
      expect(linhas.single['codigo'], 'BORAL');
      expect(mestre.leituras, 1);
      expect(await reaberto.vencida('mestre', janela), isFalse);
    });

    test('cópia antiga, sem carimbo, é relida uma vez', () async {
      final disco = <String, String>{'mestre': '[{"codigo":"VELHO"}]'};
      final mestre = _Tabela([
        {'codigo': 'NOVO'},
      ]);
      final cache = _cacheComDisco(disco);
      expect(await cache.vencida('mestre', janela), isTrue);
      await cache.ler('mestre', mestre.ler, janela: janela);
      await _assentar();
      expect(mestre.leituras, 1);
      expect(disco['mestre|em'], isNotEmpty);
    });

    test('expirar apaga o carimbo em disco também', () async {
      final disco = <String, String>{};
      final tabela = _Tabela([
        {'x': 1},
      ]);
      final cache = _cacheComDisco(disco);
      await cache.ler('t', tabela.ler, janela: janela);
      await _assentar();
      cache.expirar('t');
      await _assentar();

      final reaberto = _cacheComDisco(disco);
      await reaberto.ler('t', tabela.ler, janela: janela);
      await _assentar();
      expect(tabela.leituras, 2);
    });

    test('esquecerCarimboEmDisco não mexe na sessão, só na reabertura',
        () async {
      final disco = <String, String>{};
      final tabela = _Tabela([
        {'x': 1},
      ]);
      final cache = _cacheComDisco(disco);
      await cache.ler('t', tabela.ler, janela: janela);
      await _assentar();
      cache.esquecerCarimboEmDisco('t');
      await _assentar();
      await cache.ler('t', tabela.ler, janela: janela);
      await _assentar();
      expect(tabela.leituras, 1, reason: 'na sessão a cópia segue fresca');

      await _cacheComDisco(disco).ler('t', tabela.ler, janela: janela);
      await _assentar();
      expect(tabela.leituras, 2, reason: 'reaberto, relê a tabela');
    });

    test('tentativa que falhou não deixa a cópia mais nova', () async {
      final disco = <String, String>{};
      final cache = _cacheComDisco(disco);
      final tabela = _Tabela([
        {'x': 1},
      ]);
      await cache.ler('t', tabela.ler, janela: Duration.zero);
      await _assentar();
      final carimbo = disco['t|em'];
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await cache.ler(
        't',
        () async => throw StateError('sem rede'),
        janela: Duration.zero,
      );
      await _assentar();
      // A janela cai entre o sucesso (60 ms atrás) e a falha (agora): se a
      // falha contasse como sucesso, a cópia pareceria fresca.
      expect(
        await cache.vencida('t', const Duration(milliseconds: 30)),
        isTrue,
      );
      expect(disco['t|em'], carimbo);
    });

    test('leitura que começou antes de apagarem a idade não a devolve',
        () async {
      // A fila grava um palete com uma leitura inteira das quantidades no
      // ar: o carimbo sai do disco (a correção ainda vai ser feita) e a
      // leitura, que pode ter saído antes do commit, não pode recolocá-lo.
      final disco = <String, String>{};
      final cache = _cacheComDisco(disco);
      final rede = Completer<LinhasConsulta>();
      final leitura = cache.ler('q', () => rede.future, forceRefresh: true);
      await Future<void>.delayed(Duration.zero);
      cache.esquecerCarimboEmDisco('q');
      rede.complete([
        {'antes': true},
      ]);
      await leitura;
      await _assentar();
      expect(disco['q|em'], isEmpty);
      expect(await _cacheComDisco(disco).vencida('q', janela), isTrue);

      final expirada = Completer<LinhasConsulta>();
      final outra = cache.ler('e', () => expirada.future, forceRefresh: true);
      await Future<void>.delayed(Duration.zero);
      cache.expirar('e');
      expirada.complete([
        {'antes': true},
      ]);
      await outra;
      expect(await cache.vencida('e', janela), isTrue);
    });

    test('duas leituras da mesma chave na abertura respeitam o carimbo',
        () async {
      final disco = <String, String>{};
      final tabela = _Tabela([
        {'x': 1},
      ]);
      await _cacheComDisco(disco).ler('q', tabela.ler, janela: janela);
      await _assentar();

      final reaberto = _cacheComDisco(disco);
      await Future.wait([
        reaberto.ler('q', tabela.ler, janela: janela),
        reaberto.ler('q', tabela.ler, janela: janela),
        reaberto.vencida('q', janela),
      ]);
      await _assentar();
      expect(tabela.leituras, 1, reason: 'o carimbo de 0 s vale para as duas');
      expect(await reaberto.vencida('q', janela), isFalse);
    });

    test('corrigir sem cópia descarta a leitura inteira que estava no ar',
        () async {
      final cache = _cache();
      final antiga = Completer<LinhasConsulta>();
      var leituras = 0;
      Future<LinhasConsulta> ler() {
        leituras++;
        return leituras == 1
            ? antiga.future
            : Future.value([
                {'local': 1, 'depois': true},
              ]);
      }

      final primeira = cache.ler('q', ler);
      await Future<void>.delayed(Duration.zero);
      expect(
        await cache.atualizarParte('q', (r) => r['local'] == 1, [
          {'local': 1, 'depois': true},
        ]),
        isNull,
      );
      final segunda = cache.ler('q', ler);
      antiga.complete([
        {'local': 1, 'antes': true},
      ]);
      await primeira;
      expect((await segunda).single['depois'], isTrue);
      expect(leituras, 2);
      final guardada = await cache.ler(
        'q',
        () async => throw StateError('não devia ir ao banco'),
        janela: const Duration(hours: 1),
      );
      expect(guardada.single['depois'], isTrue);
    });

    test('correção parcial não renova a janela da cópia inteira', () async {
      final cache = _cache();
      final tabela = _Tabela([
        {'local': 1, 'q': 1},
        {'local': 2, 'q': 2},
      ]);
      await cache.ler('q', tabela.ler, janela: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await cache.atualizarParte('q', (r) => r['local'] == 1, [
        {'local': 1, 'q': 9},
      ]);
      expect(await cache.vencida('q', const Duration(milliseconds: 1)), isTrue);
    });

    test('releitura por posição volta para o lugar da posição', () async {
      // O galpão relê só as posições gravadas; sem ordenar, elas iriam para o
      // fim da cópia e a busca do galpão sairia fora de (posicao, ordem).
      final cache = _cache();
      final tabela = _Tabela([
        {'posicao': 1, 'ordem': 0},
        {'posicao': 2, 'ordem': 0},
        {'posicao': 3, 'ordem': 0},
      ]);
      await cache.ler('galpao', tabela.ler);
      int porPosicao(Map<String, dynamic> a, Map<String, dynamic> b) {
        final p = (a['posicao'] as int).compareTo(b['posicao'] as int);
        return p != 0 ? p : (a['ordem'] as int).compareTo(b['ordem'] as int);
      }

      final corrigida = await cache.atualizarParte(
        'galpao',
        (r) => r['posicao'] == 2,
        [
          {'posicao': 2, 'ordem': 1},
          {'posicao': 2, 'ordem': 0},
        ],
        ordenar: porPosicao,
      );
      final esperado = [
        (1, 0),
        (2, 0),
        (2, 1),
        (3, 0),
      ];
      expect(corrigida!.map((r) => (r['posicao'], r['ordem'])), esperado);
      final lida = await cache.ler('galpao', tabela.ler);
      expect(lida.map((r) => (r['posicao'], r['ordem'])), esperado);
    });
  });

  group('volta ao app relê só o que está em uso', () {
    test('o prewarm não conta como uso', () async {
      final cache = _cache();
      final usada = _Tabela([
        {'x': 1},
      ]);
      final soPrewarm = _Tabela([
        {'y': 1},
      ]);
      await cache.ler('usada', usada.ler, janela: Duration.zero);
      await ConsultaCache.semMarcarUso(
        () => cache.ler('layout_9', soPrewarm.ler, janela: Duration.zero),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));

      await cache.atualizar(soVencidas: true, soUsadas: true);
      expect(usada.leituras, 2);
      expect(soPrewarm.leituras, 1);

      // O Sincronizar continua relendo tudo.
      await cache.atualizar();
      expect(soPrewarm.leituras, 2);
    });

    test('a recarga que o aviso de uma leitura do prewarm dispara conta como uso',
        () async {
      // A tela recarrega pelo aviso; se herdasse a zona do prewarm, as
      // consultas dela nunca contariam como uso e a volta ao app as pularia.
      late ConsultaCache cache;
      final tela = _Tabela([
        {'t': 1},
      ]);
      final recargas = <Future<void>>[];
      cache = _cache(
        aoAtualizar: () => recargas.add(
          Future<void>.delayed(
            Duration.zero,
            () => cache.ler('tela', tela.ler, janela: Duration.zero),
          ),
        ),
      );
      final mestre = _Tabela([
        {'m': 1},
      ]);
      await cache.ler('mestre', mestre.ler, janela: Duration.zero);
      mestre.linhas = [
        {'m': 2},
      ];
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await ConsultaCache.semMarcarUso(
        () => cache.ler('mestre', mestre.ler, forceRefresh: true),
      );
      await Future.wait(recargas);
      expect(recargas, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 2));

      await cache.atualizar(soVencidas: true, soUsadas: true);
      expect(tela.leituras, 2);
    });

    test('consulta esquecida sai do Sincronizar', () async {
      final cache = _cache();
      final boa = _Tabela([
        {'x': 1},
      ]);
      await cache.ler('boa', boa.ler);
      await expectLater(
        cache.ler(
          'coluna_ausente',
          () async => throw StateError('no such column: confirmado_em'),
          falharSemCache: true,
        ),
        throwsStateError,
      );
      cache.esquecer('coluna_ausente');
      await cache.atualizar();
      expect(boa.leituras, 2);
    });

    test('Sincronizar durante a volta ao app espera e relê tudo', () async {
      final cache = _cache();
      final lenta = Completer<LinhasConsulta>();
      var leiturasLenta = 0;
      Future<LinhasConsulta> lerLenta() {
        leiturasLenta++;
        return leiturasLenta == 1 ? Future.value([]) : lenta.future;
      }

      await cache.ler('lenta', lerLenta, janela: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final volta = cache.atualizar(soVencidas: true);
      expect(cache.atualizando, isTrue);

      var sincronizou = false;
      final sincronizar = cache.atualizar().then((_) => sincronizou = true);
      await Future<void>.delayed(Duration.zero);
      expect(sincronizou, isFalse);
      lenta.complete([
        {'v': 2},
      ]);
      await volta;
      await sincronizar;
      expect(sincronizou, isTrue);
      expect(leiturasLenta, 3, reason: 'a passada do Sincronizar relê de novo');
    });
  });

  group('avisos', () {
    test('avisar: false não chama aoAtualizar quando a cópia muda', () async {
      var avisos = 0;
      final cache = _cache(aoAtualizar: () => avisos++);
      final contagens = _Tabela([
        {'codigo': 'A'},
      ]);
      await cache.ler('c', contagens.ler, janela: Duration.zero, avisar: false);
      contagens.linhas = [
        {'codigo': 'B'},
      ];
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await cache.ler('c', contagens.ler, janela: Duration.zero, avisar: false);
      await _assentar();
      expect(contagens.leituras, 2);
      expect(avisos, 0);
    });

    test('a ordem das linhas e das colunas não conta como mudança', () async {
      var avisos = 0;
      final cache = _cache(aoAtualizar: () => avisos++);
      final tabela = _Tabela([
        {'a': 1, 'b': 2},
        {'a': 3, 'b': 4},
      ]);
      await cache.ler('t', tabela.ler, janela: Duration.zero);
      tabela.linhas = [
        {'b': 4, 'a': 3},
        {'a': 1, 'b': 2},
      ];
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await cache.ler('t', tabela.ler, janela: Duration.zero);
      await _assentar();
      expect(tabela.leituras, 2);
      expect(avisos, 0);

      tabela.linhas = [
        {'a': 1, 'b': 5},
      ];
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await cache.ler('t', tabela.ler, janela: Duration.zero);
      await _assentar();
      expect(avisos, 1);
    });
  });

  group('geração por chave', () {
    test('commit em X não descarta a leitura em andamento de Y', () async {
      final cache = _cache();
      final rede = Completer<LinhasConsulta>();
      final leitura = cache.ler('y', () => rede.future, forceRefresh: true);
      await Future<void>.delayed(Duration.zero);
      await cache.confirmar('x', [
        {'gravado': true},
      ]);
      rede.complete([
        {'y': 'novo'},
      ]);
      expect((await leitura).single['y'], 'novo');
      final depois = await cache.ler(
        'y',
        () async => throw StateError('não devia ir ao banco'),
        janela: const Duration(hours: 1),
      );
      expect(depois.single['y'], 'novo');
    });

    test('invalidar sem chaves poupa as somenteLeitura', () async {
      final cache = _cache();
      final ro = Completer<LinhasConsulta>();
      final rw = Completer<LinhasConsulta>();
      await cache.confirmar('rw', [
        {'v': 'antes'},
      ]);
      final leituraRo = cache.ler(
        'ro',
        () => ro.future,
        forceRefresh: true,
        somenteLeitura: true,
      );
      final leituraRw = cache.ler('rw', () => rw.future, forceRefresh: true);
      await Future<void>.delayed(Duration.zero);
      cache.invalidarConsultasEmAndamento();
      ro.complete([
        {'v': 'ro'},
      ]);
      rw.complete([
        {'v': 'resposta velha'},
      ]);
      expect((await leituraRo).single['v'], 'ro');
      expect((await leituraRw).single['v'], 'antes');
    });

    test('invalidar com chaves mexe só nelas', () async {
      final cache = _cache();
      await cache.confirmar('galpao', [
        {'v': 'antes'},
      ]);
      await cache.confirmar('outra', [
        {'v': 'antes'},
      ]);
      final g = Completer<LinhasConsulta>();
      final o = Completer<LinhasConsulta>();
      final lg = cache.ler('galpao', () => g.future, forceRefresh: true);
      final lo = cache.ler('outra', () => o.future, forceRefresh: true);
      await Future<void>.delayed(Duration.zero);
      cache.invalidarConsultasEmAndamento(['galpao']);
      g.complete([
        {'v': 'velha'},
      ]);
      o.complete([
        {'v': 'nova'},
      ]);
      expect((await lg).single['v'], 'antes');
      expect((await lo).single['v'], 'nova');
    });
  });
}
