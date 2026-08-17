import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_busca.dart';
import 'package:gondola_camda/models.dart';

const _catalogo = [
  Produto(
      codigo: 'HB500', nome: 'HERBICIDA BORAL 500 SC 20L',
      categoria: 'Defensivos', corHex: '#8b1a1a'),
  Produto(
      codigo: 'HN806', nome: 'HERBICIDA NORTOX 2,4-D 806 SL 5L',
      categoria: 'Defensivos', corHex: '#8b1a1a'),
  Produto(
      codigo: 'FA200', nome: 'FUNGICIDA OUROFINO AZOX 200 1L',
      categoria: 'Defensivos', corHex: '#8b1a1a'),
  Produto(
      codigo: 'LB001', nome: 'OLEO LUBRAX ESSENCIAL 20L',
      categoria: 'Lubrificantes', corHex: '#2e7d4f'),
  Produto(
      codigo: 'LV001', nome: 'LUVA NITRILICA PROTECAO PAR',
      categoria: 'Vestuário', corHex: '#6b4a2b'),
];

void main() {
  group('buscarProdutosGalpao', () {
    test('acha por qualquer parte do nome, não só o começo', () {
      // O caso do enunciado: a categoria vem na frente e a embalagem no fim,
      // então quem lembra 'boral' precisa achar o herbicida.
      final r = buscarProdutosGalpao('boral', _catalogo);
      expect(r.map((p) => p.codigo), ['HB500']);
    });

    test('não diferencia maiúsculas', () {
      expect(buscarProdutosGalpao('BORAL', _catalogo).length, 1);
      expect(buscarProdutosGalpao('Lubrax', _catalogo).length, 1);
    });

    test('acha por código do produto', () {
      expect(buscarProdutosGalpao('hb500', _catalogo).single.nome,
          'HERBICIDA BORAL 500 SC 20L');
    });

    test('dois termos soltos são cruzados — todos precisam casar', () {
      // 'boral 20' → 'boral' no nome e '20' no '20L'.
      expect(buscarProdutosGalpao('boral 20', _catalogo).length, 1);
      // 'herbicida 5l' → só o NORTOX termina em 5L.
      expect(buscarProdutosGalpao('herbicida 5l', _catalogo).single.codigo,
          'HN806');
      // termo que não casa derruba o resultado inteiro.
      expect(buscarProdutosGalpao('boral luva', _catalogo), isEmpty);
    });

    test('um termo pode casar no nome e o outro no código', () {
      expect(buscarProdutosGalpao('herbicida hb', _catalogo).single.codigo,
          'HB500');
    });

    test('menos de 2 caracteres úteis devolve vazio', () {
      expect(buscarProdutosGalpao('b', _catalogo), isEmpty);
      expect(buscarProdutosGalpao('  b  ', _catalogo), isEmpty);
      expect(buscarProdutosGalpao('', _catalogo), isEmpty);
    });

    test('respeita o limite de resultados', () {
      final r = buscarProdutosGalpao('l', [
        for (var i = 0; i < 10; i++)
          Produto(
              codigo: 'C$i', nome: 'PRODUTO LONGO $i',
              categoria: '', corHex: '#888888'),
      ]);
      expect(r, isEmpty); // 1 char

      final r2 = buscarProdutosGalpao('longo', [
        for (var i = 0; i < 10; i++)
          Produto(
              codigo: 'C$i', nome: 'PRODUTO LONGO $i',
              categoria: '', corHex: '#888888'),
      ]);
      expect(r2.length, 4);
    });
  });
}
