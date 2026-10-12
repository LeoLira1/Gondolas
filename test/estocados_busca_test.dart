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
}
