import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/busca_local.dart';
import 'package:gondola_camda/consulta_cache.dart';
import 'package:gondola_camda/layouts_copia.dart';
import 'package:gondola_camda/models.dart';

// Os layouts de gôndola e estante saem de UMA cópia por tabela (a mesma da
// busca), e abrir uma estrutura relê só ela pelo índice. Aqui com a
// ConsultaCache de verdade por baixo — é dela a janela, a geração e o disco.

/// Uma tabela de layout que conta as idas ao banco.
class _Tabela {
  _Tabela(this.linhas);
  LinhasLayout linhas;
  int leiturasInteiras = 0;
  int leiturasDeEstrutura = 0;
  Completer<void>? trava;
  bool semRede = false;

  Future<LinhasLayout> lerInteira() async {
    leiturasInteiras++;
    if (semRede) throw StateError('sem rede');
    return [for (final r in linhas) Map<String, dynamic>.from(r)];
  }

  Future<LinhasLayout> lerEstrutura(int numero) async {
    leiturasDeEstrutura++;
    final agora = [
      for (final r in linhas)
        if (r['gondola_num'] == numero) Map<String, dynamic>.from(r),
    ];
    if (trava != null) await trava!.future;
    if (semRede) throw StateError('sem rede');
    return agora;
  }
}

Map<String, dynamic> _caixa(int gondola, String codigo, {double x = 0.1}) => {
  'gondola_num': gondola,
  'andar': 0,
  'produto_codigo': codigo,
  'produto_nome': 'Produto $codigo',
  'pos_x': x,
  'pos_z': 0.2,
  'cor_hex': '#888888',
};

({ConsultaCache cache, LayoutsDaCopia layouts}) _montar(
  _Tabela tabela, {
  Duration janela = const Duration(hours: 1),
  Map<String, String>? disco,
}) {
  final d = disco ?? <String, String>{};
  final cache = ConsultaCache(
    lerDisco: (k) async => d[k],
    gravarDisco: (k, v) async => d[k] = v,
    aoAtualizar: () {},
  );
  const chave = 'layouts';
  final layouts = LayoutsDaCopia(
    coluna: 'gondola_num',
    janelaEstrutura: janela,
    lerEstrutura: tabela.lerEstrutura,
    corrigirCopia: (pertence, novas, {required deGravacao}) =>
        cache.atualizarParte(
          chave,
          pertence,
          novas,
          descartarNoAr: deGravacao,
        ),
    copiaEmMemoria: () => cache.emMemoria(chave),
    carregarCopia: () => cache.carregar(chave),
    copiaVencida: (j) => cache.vencida(chave, j),
  );
  return (cache: cache, layouts: layouts);
}

Future<void> _lerCopiaInteira(ConsultaCache cache, _Tabela tabela) =>
    cache.ler('layouts', tabela.lerInteira, releNaVolta: false);

List<String> _codigos(LinhasLayout linhas) =>
    [for (final r in linhas) r['produto_codigo'] as String];

void main() {
  group('estrutura servida da cópia completa', () {
    test('cópia fresca: abrir a estrutura não vai ao banco', () async {
      final tabela = _Tabela([_caixa(1, 'A'), _caixa(2, 'B'), _caixa(2, 'C')]);
      final m = _montar(tabela);
      await _lerCopiaInteira(m.cache, tabela);

      expect(_codigos(await m.layouts.linhas(2)), ['B', 'C']);
      expect(_codigos(m.layouts.linhasEmMemoria(1)!), ['A']);
      expect(tabela.leiturasDeEstrutura, 0);
    });

    test('estrutura sem caixas é lista vazia; sem cópia é null', () async {
      final tabela = _Tabela([_caixa(1, 'A')]);
      final m = _montar(tabela);
      expect(m.layouts.linhasEmMemoria(7), isNull);
      await _lerCopiaInteira(m.cache, tabela);
      expect(m.layouts.linhasEmMemoria(7), isEmpty);
    });

    test('a fatia é guardada enquanto a cópia não muda', () async {
      final tabela = _Tabela([_caixa(1, 'A')]);
      final m = _montar(tabela);
      await _lerCopiaInteira(m.cache, tabela);
      final a = m.layouts.linhasEmMemoria(1);
      expect(identical(a, m.layouts.linhasEmMemoria(1)), isTrue);
      await m.layouts.salva(1, [_caixa(1, 'Z')]);
      expect(_codigos(m.layouts.linhasEmMemoria(1)!), ['Z']);
    });
  });

  group('releitura por estrutura', () {
    test('passada a janela, relê só a estrutura e corrige a cópia', () async {
      final tabela = _Tabela([_caixa(1, 'A'), _caixa(2, 'B')]);
      final m = _montar(tabela, janela: Duration.zero);
      await _lerCopiaInteira(m.cache, tabela);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      tabela.linhas = [_caixa(1, 'A'), _caixa(2, 'NOVO')];
      expect(_codigos(await m.layouts.linhas(2)), ['NOVO']);
      expect(tabela.leiturasDeEstrutura, 1);
      expect(tabela.leiturasInteiras, 1, reason: 'nada de tabela inteira');
      // A busca, que lê a mesma cópia, já vê a estrutura nova.
      expect(_codigos(m.cache.emMemoria('layouts')!), ['A', 'NOVO']);
    });

    test('dentro da janela da estrutura não relê de novo', () async {
      final tabela = _Tabela([_caixa(1, 'A')]);
      final m = _montar(tabela);
      await m.layouts.linhas(1);
      await m.layouts.linhas(1);
      expect(tabela.leiturasDeEstrutura, 1);
    });

    test('pedidos ao mesmo tempo dividem uma ida', () async {
      final tabela = _Tabela([_caixa(1, 'A')])..trava = Completer<void>();
      final m = _montar(tabela);
      final a = m.layouts.linhas(1);
      final b = m.layouts.linhas(1);
      tabela.trava!.complete();
      await Future.wait([a, b]);
      expect(tabela.leiturasDeEstrutura, 1);
    });

    test('gravação deste aparelho no meio descarta a leitura antiga',
        () async {
      final tabela = _Tabela([_caixa(1, 'ANTES')])..trava = Completer<void>();
      final m = _montar(tabela, janela: Duration.zero);
      await _lerCopiaInteira(m.cache, tabela);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      final leitura = m.layouts.linhas(1);
      await Future<void>.delayed(Duration.zero);
      await m.layouts.salva(1, [_caixa(1, 'GRAVADO')]);
      tabela.trava!.complete();

      expect(_codigos(await leitura), ['GRAVADO']);
      expect(_codigos(m.layouts.linhasEmMemoria(1)!), ['GRAVADO']);
    });

    test('releitura de uma estrutura não joga fora a leitura completa no ar',
        () async {
      // A pré-carga (ou o Sincronizar) lia a tabela inteira enquanto alguém
      // abria uma gôndola; a releitura dela descartava a leitura completa já
      // cobrada, e a próxima busca lia a tabela de novo.
      final tabela = _Tabela([_caixa(1, 'A'), _caixa(2, 'B')]);
      final m = _montar(tabela, janela: Duration.zero);
      await _lerCopiaInteira(m.cache, tabela);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      tabela.linhas = [_caixa(1, 'A2'), _caixa(2, 'B2')];
      final inteira = Completer<LinhasLayout>();
      final completa = m.cache.ler(
        'layouts',
        () => inteira.future,
        forceRefresh: true,
        releNaVolta: false,
      );
      await Future<void>.delayed(Duration.zero);
      expect(_codigos(await m.layouts.linhas(1)), ['A2']);
      inteira.complete(await tabela.lerInteira());
      await completa;

      expect(_codigos(m.cache.emMemoria('layouts')!), ['A2', 'B2']);
      expect(
        await m.cache.vencida('layouts', const Duration(minutes: 1)),
        isFalse,
        reason: 'a leitura completa ficou guardada, com idade nova',
      );
    });

    test('sem cópia, a releitura de uma estrutura também não a descarta',
        () async {
      final tabela = _Tabela([_caixa(1, 'A'), _caixa(2, 'B')]);
      final m = _montar(tabela);
      final inteira = Completer<LinhasLayout>();
      final completa = m.cache.ler(
        'layouts',
        () => inteira.future,
        releNaVolta: false,
      );
      await Future<void>.delayed(Duration.zero);
      await m.layouts.linhas(2);
      inteira.complete(await tabela.lerInteira());
      await completa;
      expect(_codigos(m.cache.emMemoria('layouts')!), ['A', 'B']);
    });

    test('suja força a releitura mesmo com a cópia em dia', () async {
      final tabela = _Tabela([_caixa(1, 'A')]);
      final m = _montar(tabela);
      await _lerCopiaInteira(m.cache, tabela);
      m.layouts.suja(1);
      tabela.linhas = [_caixa(1, 'DO_OUTRO')];
      expect(_codigos(await m.layouts.linhas(1)), ['DO_OUTRO']);
      expect(tabela.leiturasDeEstrutura, 1);
    });
  });

  group('sem cópia e sem rede', () {
    test('instalação nova: a estrutura lida fica guardada à parte', () async {
      final tabela = _Tabela([_caixa(3, 'A')]);
      final m = _montar(tabela);
      expect(_codigos(await m.layouts.linhas(3)), ['A']);
      expect(_codigos(m.layouts.linhasEmMemoria(3)!), ['A']);
      m.layouts.esquecer();
      expect(m.layouts.linhasEmMemoria(3), isNull);
    });

    test('sem rede com cópia: serve a cópia', () async {
      final tabela = _Tabela([_caixa(1, 'A')]);
      final m = _montar(tabela, janela: Duration.zero);
      await _lerCopiaInteira(m.cache, tabela);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      tabela.semRede = true;
      expect(_codigos(await m.layouts.linhas(1)), ['A']);
    });

    test('sem rede e sem cópia: lança, nunca uma estrutura vazia', () async {
      // Vazia na tela + "Salvar layout" apagava o layout de verdade.
      final tabela = _Tabela([_caixa(1, 'A')])..semRede = true;
      final m = _montar(tabela);
      await expectLater(m.layouts.linhas(1), throwsStateError);
      expect(m.layouts.linhasEmMemoria(1), isNull);
    });

    test('cópia em disco de outra sessão serve offline', () async {
      final disco = <String, String>{
        'layouts': jsonEncode([_caixa(4, 'DISCO')]),
      };
      final tabela = _Tabela([])..semRede = true;
      final m = _montar(tabela, disco: disco);
      expect(_codigos(await m.layouts.linhas(4)), ['DISCO']);
    });
  });

  group('conferência do salvar (conflito)', () {
    String g(LinhasLayout l) => assinaturaLayout(l, colunasConteudoGondola);

    test('mesma caixas em outra ordem, nome e cor diferentes: igual', () {
      final a = [_caixa(1, 'A', x: 0.1), _caixa(1, 'B', x: 0.3)];
      final b = [
        {..._caixa(1, 'B', x: 0.3), 'produto_nome': 'Outro nome'},
        {..._caixa(1, 'A', x: 0.1), 'cor_hex': '#ffffff'},
      ];
      expect(g(a), g(b));
    });

    test('inteiro e double, e o que passou por JSON, comparam igual', () {
      final banco = [
        {'andar': 1, 'produto_codigo': 'A', 'pos_x': 1, 'pos_z': 0.35},
      ];
      final tela = (jsonDecode(jsonEncode([
        {'andar': 1.0, 'produto_codigo': 'A', 'pos_x': 1.0, 'pos_z': 0.35},
      ])) as List).cast<Map<String, dynamic>>();
      expect(g(banco), g(tela));
    });

    test('caixa a mais, a menos, repetida ou em outro lugar: diferente', () {
      final base = [_caixa(1, 'A')];
      expect(g([...base, _caixa(1, 'B')]), isNot(g(base)));
      expect(g(const []), isNot(g(base)));
      expect(g([...base, _caixa(1, 'A')]), isNot(g(base)));
      expect(g([_caixa(1, 'A', x: 0.2)]), isNot(g(base)));
    });

    test('conflito só quando o banco não é nem a base nem o que vai gravar',
        () {
      final base = [_caixa(1, 'A'), _caixa(1, 'B', x: 0.3)];
      final edicao = [_caixa(1, 'A'), _caixa(1, 'C', x: 0.5)];
      bool mudou(LinhasLayout banco) => layoutMudouPorBaixo(
        noBanco: banco,
        base: base,
        itens: edicao,
        colunas: colunasConteudoGondola,
      );
      expect(mudou(base), isFalse, reason: 'ninguém mexeu');
      // Salvou, a resposta se perdeu e a pessoa tocou em Salvar de novo: o
      // banco já tem a edição. Não é "outro aparelho".
      expect(mudou(edicao), isFalse);
      expect(mudou([_caixa(1, 'A'), _caixa(1, 'D')]), isTrue);
    });

    test('estante: coluna, nível, slot e código', () {
      String e(LinhasLayout l) => assinaturaLayout(l, colunasConteudoEstante);
      final a = [
        {'coluna': 0, 'nivel': 1, 'slot': 2, 'produto_codigo': 'X'},
      ];
      expect(
        e(a),
        e([
          {...a.single, 'produto_nome': 'outro', 'cor_hex': '#000'},
        ]),
      );
      expect(
        e(a),
        isNot(e([
          {...a.single, 'slot': 3},
        ])),
      );
    });
  });

  group('busca nas estantes da cópia completa', () {
    // O SELECT DISTINCT antigo (colunas da busca, sem estantes removidas e
    // sem a base do Nellore, ORDER BY nome) contra a cópia completa filtrada
    // em Dart: mesmos resultados.
    Map<String, dynamic> linha(
      int estante,
      int nivel,
      String codigo, {
      int coluna = 0,
      int slot = 0,
      String cor = '#888888',
    }) => {
      'estante_num': estante,
      'coluna': coluna,
      'nivel': nivel,
      'slot': slot,
      'produto_codigo': codigo,
      'produto_nome': 'BORAL $codigo',
      'cor_hex': cor,
    };

    final completa = [
      linha(1, 2, '10', coluna: 0, slot: 0),
      linha(1, 2, '10', coluna: 1, slot: 3, cor: '#ff0000'),
      linha(1, 3, '10'),
      linha(3, 1, '11'),
      linha(4, 2, '12'),
      linha(expositorNelloreNum, 0, '13'),
      linha(expositorNelloreNum, 1, '13'),
      linha(101, 0, '14'),
      linha(2, 1, '15'),
    ];

    List<String> chaves(List<Map<String, dynamic>> r) => [
      for (final l in r)
        '${l['produto_codigo']}|${l['estante_num']}|${l['nivel']}',
    ]..sort();

    for (final termo in ['', 'boral', '10', '13', 'boral 1']) {
      test('termo "$termo"', () {
        final vistas = <String>{};
        final antiga = [
          for (final r in completa)
            if (!estantesRemovidas.contains(r['estante_num']) &&
                !(r['estante_num'] == expositorNelloreNum && r['nivel'] == 0))
              {
                'produto_codigo': r['produto_codigo'],
                'produto_nome': r['produto_nome'],
                'estante_num': r['estante_num'],
                'nivel': r['nivel'],
              },
        ].where((r) => vistas.add(jsonEncode(r))).toList()
          ..sort(
            (a, b) => (a['produto_nome'] as String).compareTo(
              b['produto_nome'] as String,
            ),
          );

        final nova = filtrarBuscaLocal([
          for (final r in completa)
            if (linhaDeEstanteBuscavel(r)) r,
        ], termo);
        expect(chaves(nova), chaves(filtrarBuscaLocal(antiga, termo)));
      });
    }
  });
}
