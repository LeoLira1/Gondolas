import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/models.dart';

Produto p(String codigo, {String? nome, String categoria = 'Defensivos'}) =>
    Produto(
      codigo:    codigo,
      nome:      nome ?? 'Produto $codigo',
      categoria: categoria,
      corHex:    '#8b1a1a',
    );

void main() {
  // catalogosIguais decide se a revalidação em segundo plano avisa as telas.
  // Um falso "mudou" recarrega todas as cenas a cada abertura do app (o ganho
  // da cópia em disco vai embora); um falso "igual" deixa produto novo
  // invisível até o próximo Sincronizar.
  group('comparação do catálogo', () {
    test('listas idênticas são iguais', () {
      expect(catalogosIguais([p('A'), p('B')], [p('A'), p('B')]), isTrue);
    });

    test('a mesma instância é igual a si mesma', () {
      final lista = [p('A')];
      expect(catalogosIguais(lista, lista), isTrue);
    });

    test('duas listas vazias são iguais', () {
      expect(catalogosIguais(const [], const []), isTrue);
    });

    test('produto a mais muda o catálogo', () {
      expect(catalogosIguais([p('A')], [p('A'), p('B')]), isFalse);
    });

    test('nome trocado muda o catálogo', () {
      expect(
        catalogosIguais([p('A', nome: 'Velho')], [p('A', nome: 'Novo')]),
        isFalse,
      );
    });

    test('categoria trocada muda o catálogo', () {
      expect(
        catalogosIguais([p('A')], [p('A', categoria: 'Sementes')]),
        isFalse,
      );
    });

    test('ordem diferente muda o catálogo', () {
      // A ordem é significativa rio abaixo: produtosComCaixa promete manter a
      // ordem do catálogo e o autocomplete corta com .take(8).
      expect(catalogosIguais([p('A'), p('B')], [p('B'), p('A')]), isFalse);
    });

    test('só a cor diferente NÃO conta como mudança', () {
      // corHex é derivada da categoria — comparar as duas seria comparar a
      // mesma informação duas vezes.
      final a = Produto(
          codigo: 'A', nome: 'X', categoria: 'Lonas', corHex: '#e87722');
      final b = Produto(
          codigo: 'A', nome: 'X', categoria: 'Lonas', corHex: '#000000');
      expect(catalogosIguais([a], [b]), isTrue);
    });
  });
}
