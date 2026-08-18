import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/modo_conferencia_service.dart';

/// Um pendente de hoje. [categoria] é o que decide se ele é "de depósito" —
/// ver categoriasExcluidasKeywords.
ItemPendente _item(String codigo, {String categoria = 'FERRAMENTAS'}) =>
    ItemPendente(
      codigo:     codigo,
      produto:    'PRODUTO $codigo',
      categoria:  categoria,
      qtdEstoque: 10,
    );

ModoConferenciaResultado _montar(
  List<ItemPendente> pendentes, {
  Map<String, Set<int>> gondolas = const {},
  Map<String, Set<int>> estantes = const {},
  Map<String, Set<int>> galpao   = const {},
}) =>
    montarConferencia(
      pendentes:         pendentes,
      gondolasPorCodigo: gondolas,
      estantesPorCodigo: estantes,
      galpaoPorCodigo:   galpao,
    );

void main() {
  group('cruzamento com o galpão', () {
    test('categoria de depósito COM rack no galpão acende lá, e sai da conta '
        'de filtrados', () {
      // É o caso que motivou o galpão no Modo Conferência: herbicida nunca tem
      // endereço na loja, mas tem rack no galpão — e antes ficava invisível.
      final r = _montar(
        [_item('BORAL', categoria: 'HERBICIDAS')],
        galpao: const {'BORAL': {52}},
      );

      expect(r.galpao.keys, [52]);
      expect(r.galpao[52]!.itens.single.codigo, 'BORAL');
      expect(r.totalFiltradosDeposito, 0);
      expect(r.galpaoVazioHoje, isFalse);
      // Nada disso mexe no lado da loja.
      expect(r.estruturas, isEmpty);
      expect(r.semEndereco, isEmpty);
      expect(r.totalProdutos, 0);
    });

    test('categoria de depósito SEM rack no galpão continua oculta', () {
      final r = _montar([
        _item('ADUBO1', categoria: 'ADUBOS'),
        _item('OLEO1',  categoria: 'LUBRIFICANTES'),
      ]);

      expect(r.totalFiltradosDeposito, 2);
      expect(r.galpao, isEmpty);
      expect(r.semEndereco, isEmpty, reason: 'não infla o "sem endereço"');
      expect(r.totalProdutos, 0);
      expect(r.vazioHoje, isTrue);
      expect(r.galpaoVazioHoje, isTrue);
    });

    test('pendente da loja com rack no galpão NÃO cai em "sem endereço"', () {
      final r = _montar(
        [_item('BICO01')],
        galpao: const {'BICO01': {7}},
      );

      expect(r.semEndereco, isEmpty);
      expect(r.galpao.keys, [7]);
      // Continua contado como pendente relevante à loja: é produto de
      // categoria de loja, só está guardado no galpão.
      expect(r.totalProdutos, 1);
    });

    test('pendente sem endereço nenhum cai em "sem endereço"', () {
      final r = _montar([_item('SEMEND')]);

      expect(r.semEndereco.single.codigo, 'SEMEND');
      expect(r.galpao, isEmpty);
      expect(r.totalProdutos, 1);
    });

    test('endereço na loja e no galpão acendem os dois', () {
      final r = _montar(
        [_item('DUPLO')],
        gondolas: const {'DUPLO': {3}},
        galpao:   const {'DUPLO': {70}},
      );

      expect(r.estruturas.keys, ['gondola:3']);
      expect(r.galpao.keys, [70]);
      expect(r.semEndereco, isEmpty);
    });

    test('mesmo produto em vários racks: uma posição cada, um produto só', () {
      final r = _montar(
        [_item('REPETIDO', categoria: 'HERBICIDAS')],
        galpao: const {'REPETIDO': {1, 2, 3}},
      );

      expect(r.totalPosicoesGalpao, 3);
      expect(r.totalProdutosGalpao, 1,
          reason: 'conta produtos distintos, não racks');
      expect(r.codigosGalpao, {'REPETIDO'});
    });

    test('codigosGalpao junta os pendentes de todas as posições', () {
      final r = _montar(
        [
          _item('A', categoria: 'HERBICIDAS'),
          _item('B', categoria: 'ADUBOS'),
          _item('C'),
        ],
        galpao: const {'A': {10}, 'B': {10}, 'C': {20}},
      );

      expect(r.codigosGalpao, {'A', 'B', 'C'});
      expect(r.galpao[10]!.codigos, {'A', 'B'});
      expect(r.galpao[10]!.itens.length, 2);
      expect(r.totalPosicoesGalpao, 2);
      expect(r.totalProdutosGalpao, 3);
    });
  });

  group('lado da loja continua como era', () {
    test('gôndola e estante recebem os pendentes com endereço', () {
      final r = _montar(
        [_item('X'), _item('Y')],
        gondolas: const {'X': {5}},
        estantes: const {'Y': {13, 14}},
      );

      expect(r.estruturas['gondola:5']!.itens.single.codigo, 'X');
      expect(r.estruturas['estante:13']!.itens.single.codigo, 'Y');
      expect(r.estruturas['estante:14']!.itens.single.codigo, 'Y');
      expect(r.totalEstruturas, 3);
      expect(r.totalProdutos, 2);
      expect(r.vazioHoje, isFalse);
    });

    test('acessório de lubrificação acende a gôndola — não é de depósito', () {
      // O caso real: ENGRAXADEIRA em ACESSORIOS DE LUBRIFICACAO casava com a
      // keyword 'LUBRIFIC' e a gôndola 1 não acendia no Modo Conferência.
      final item = ItemPendente(
        codigo:     '165816',
        produto:    'ENGRAXADEIRA 5KG MAC LUB MAC 35 EXPORT',
        categoria:  'ACESSORIOS DE LUBRIFICAÇÃO',
        qtdEstoque: 1,
      );

      expect(ehCategoriaDeDeposito(item), isFalse);

      final r = _montar([item], gondolas: const {'165816': {1}});
      expect(r.estruturas['gondola:1']!.itens.single.codigo, '165816');
      expect(r.totalProdutos, 1);
      expect(r.totalFiltradosDeposito, 0);
    });

    test('acessório sem endereço nenhum vai pro "sem endereço", não some', () {
      final r = _montar([
        _item('ACESS1', categoria: 'ACESSORIOS DE LUBRIFICACAO'),
      ]);

      expect(r.semEndereco.single.codigo, 'ACESS1');
      expect(r.totalFiltradosDeposito, 0);
    });

    test('endereço na loja vence a categoria de depósito', () {
      // Rede de segurança pras categorias que a keyword pega de propósito:
      // se alguém cadastrou face de gôndola, a gôndola acende do mesmo jeito —
      // a premissa do filtro ("nunca terão endereço de loja") caiu.
      final r = _montar(
        [_item('OLEO2', categoria: 'LUBRIFICANTES')],
        gondolas: const {'OLEO2': {9}},
      );

      expect(r.estruturas['gondola:9']!.itens.single.codigo, 'OLEO2');
      expect(r.totalProdutos, 1);
      expect(r.totalFiltradosDeposito, 0);
    });

    test('óleo mineral é pego pelo nome, não só pela categoria', () {
      // O filtro testa o nome nas keywords de categoria duvidosa: aqui a
      // categoria está "certa" mas o produto é óleo mineral.
      final item = ItemPendente(
        codigo:     'OM20',
        produto:    'OLEO MINERAL AGRICOLA 20L',
        categoria:  'DIVERSOS',
        qtdEstoque: 5,
      );
      final semRack = _montar([item]);
      expect(semRack.totalFiltradosDeposito, 1);

      final comRack = _montar([item], galpao: const {'OM20': {40}});
      expect(comRack.totalFiltradosDeposito, 0);
      expect(comRack.galpao.keys, [40]);
    });
  });
}
