import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/models.dart';

void main() {
  group('corDeHex', () {
    test('converte hex com # na cor opaca correspondente', () {
      expect(corDeHex('#2e7d4f'), const Color(0xFF2e7d4f));
    });

    test('aceita hex sem # com o mesmo resultado', () {
      expect(corDeHex('2e7d4f'), corDeHex('#2e7d4f'));
    });

    test('devolve instância idêntica em chamadas repetidas (memo)', () {
      // É o ponto da memoização: montar o mapa de cores da cena deixa de
      // reparsear o hex de cada produto.
      expect(identical(corDeHex('#e87722'), corDeHex('#e87722')), isTrue);
    });

    test('hex malformado devolve o cinza padrão em vez de estourar', () {
      // Antes isto era um int.parse solto dentro de Produto.cor — um cor_hex
      // inválido vindo do banco derrubava o build() da cena.
      expect(corDeHex('#zzzzzz'), corProdutoDesconhecido);
      expect(corDeHex('#zz'), corProdutoDesconhecido);
      // Curtos demais também: 'FF' + '' parseia como 255 e sairia azul
      // transparente se só o int.tryParse fosse conferido.
      expect(corDeHex(''), corProdutoDesconhecido);
      expect(corDeHex('#'), corProdutoDesconhecido);
      expect(corDeHex('#12'), corProdutoDesconhecido);
      // Longo demais (ex.: hex com alfa) idem — o formato gravado é #rrggbb.
      expect(corDeHex('#ff2e7d4f'), corProdutoDesconhecido);
    });

    test('Produto.cor usa corDeHex', () {
      const p = Produto(
          codigo: 'x', nome: 'X', categoria: 'Lonas', corHex: '#e87722');
      expect(p.cor, const Color(0xFFe87722));
    });
  });

  group('mesclarCores', () {
    const lubrificante = Produto(
        codigo: 'A1', nome: 'Óleo', categoria: 'Lubrificantes', corHex: '#2e7d4f');

    test('catálogo vazio devolve as cores do layout intactas', () {
      // É o estado da cena no primeiro frame: o layout já chegou, o catálogo
      // ainda não. As caixas têm de sair coloridas mesmo assim.
      final cores = mesclarCores({'A1': const Color(0xFF111111)}, const []);
      expect(cores, {'A1': const Color(0xFF111111)});
    });

    test('catálogo vence quando o produto existe nele', () {
      // O cor_hex da linha foi gravado A PARTIR do catálogo; se divergem, é
      // porque a categoria mudou desde o último save — e aí vale a de agora.
      final cores =
          mesclarCores({'A1': const Color(0xFF111111)}, [lubrificante]);
      expect(cores['A1'], const Color(0xFF2e7d4f));
    });

    test('código só do layout mantém a cor do layout', () {
      // Produto que saiu do estoque_mestre continua pintado como estava, em
      // vez de virar cinza.
      final cores = mesclarCores(
        {'A1': const Color(0xFF111111), 'ORFAO': const Color(0xFF222222)},
        [lubrificante],
      );
      expect(cores['ORFAO'], const Color(0xFF222222));
      expect(cores['A1'], const Color(0xFF2e7d4f));
    });

    test('produto só do catálogo entra no mapa', () {
      final cores = mesclarCores(const {}, [lubrificante]);
      expect(cores, {'A1': const Color(0xFF2e7d4f)});
    });

    test('não muta o mapa de entrada', () {
      final doLayout = {'A1': const Color(0xFF111111)};
      mesclarCores(doLayout, [lubrificante]);
      expect(doLayout, {'A1': const Color(0xFF111111)});
    });
  });
}
