import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/estocados_busca.dart';

void main() {
  const itens = [
    ItemEstocado(
      cooperado: 'JOÃO DA SILVA',
      produto: 'HERBICIDA BORAL 500 SC 20L',
      codigo: '254185',
      armazem: '01',
      documento: '1',
      emissao: '2026-10-01',
      saldo: 10,
    ),
    ItemEstocado(
      cooperado: 'MARIA SOUZA',
      produto: 'ADUBO FOLIAR 5L',
      codigo: '300100',
      armazem: '01',
      documento: '2',
      emissao: '2026-10-02',
      saldo: 4,
    ),
  ];

  test('consulta vazia devolve tudo', () {
    expect(buscarEstocados('  ', itens), itens);
  });

  test('acha por cooperado sem acento, por produto e por código', () {
    expect(buscarEstocados('joao', itens).single.codigo, '254185');
    expect(buscarEstocados('adubo', itens).single.cooperado, 'MARIA SOUZA');
    expect(buscarEstocados('300100', itens).single.produto, 'ADUBO FOLIAR 5L');
  });

  test('termos cruzam cooperado e produto', () {
    expect(buscarEstocados('silva boral', itens).length, 1);
    expect(buscarEstocados('maria boral', itens), isEmpty);
  });

  test('deLinha aceita sinônimos de coluna', () {
    final i = ItemEstocado.deLinha({
      'RAZAO_SOCIAL': 'X',
      'descricao': 'Y',
      'cod': '9',
      'saldo': '1,5',
    });
    expect(i.cooperado, 'X');
    expect(i.codigo, '9');
    expect(i.saldo, 1.5);
  });

  test('produtoDeEstocado leva prefixo, cooperado no nome e não casa com a loja', () {
    final p = produtoDeEstocado(itens.first);
    expect(p.codigo, 'EST:254185');
    expect(codigoEhEstocado(p.codigo), isTrue);
    expect(codigoEhEstocado('254185'), isFalse);
    expect(p.nome, 'HERBICIDA BORAL 500 SC 20L · JOÃO DA SILVA');
  });

  test('enderecosDosEstocados liga palete ao item pelo nome e ignora a loja', () {
    final nome = nomeDoPalete(itens.first);
    final mapa = enderecosDosEstocados(
      galpao: [
        (posicao: 40, ordem: 4, codigo: 'EST:254185', nome: nome),
        (posicao: 41, ordem: 1, codigo: '999', nome: 'DA LOJA'),
      ],
      barracao: [
        (rotulo: 'BAR-07', codigo: 'EST:254185', nome: nome),
      ],
    );
    expect(mapa.keys, [nome]);
    expect(mapa[nome], ['Galpão 40 · N4', 'BAR-07']);
  });

  test('somarEstocados junta itens iguais e soma o saldo', () {
    ItemEstocado it(String doc, double saldo, {String cod = '278636'}) =>
        ItemEstocado(
          cooperado: 'ELBIO',
          produto: 'HERBICIDA 2,4-D 20L',
          codigo: cod,
          armazem: '70',
          documento: doc,
          emissao: '',
          saldo: saldo,
        );
    final r = somarEstocados([it('1', 28), it('2', 17), it('3', 5, cod: '9')]);
    expect(r.length, 2);
    expect(r.first.saldo, 45);
    expect(r.first.lancamentos, 2);
    expect(r.first.documento, '');
    expect(r.last.saldo, 5);
    expect(r.last.lancamentos, 1);
  });

  test('resumoOcupacao separa livres, estocados e loja e esconde o zero', () {
    expect(
      resumoOcupacao(
        totalVagas: 10,
        codigos: ['EST:1', 'EST:2', '999'],
      ),
      '7 livres · 2 estocados · 1 loja',
    );
    expect(
      resumoOcupacao(totalVagas: 10, codigos: ['EST:1']),
      '9 livres · 1 estocados',
    );
    expect(resumoOcupacao(totalVagas: 10, codigos: []), '10 livres');
  });
}
