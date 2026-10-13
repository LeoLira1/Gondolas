import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/layout_cache.dart';

void main() {
  group('CacheDeLayout', () {
    test('estrutura nunca lida devolve null (miss), não lista vazia', () {
      final cache = CacheDeLayout<String>();
      expect(cache.ler(5), isNull);
      expect(cache.tamanho, 0);
    });

    test('lista vazia gravada é um HIT, não um miss', () {
      // Distinção que importa: prateleira sem nenhuma caixa é uma resposta
      // legítima do banco. Se ela virasse miss, toda abertura reconsultaria.
      final cache = CacheDeLayout<String>()..gravar(5, []);
      expect(cache.ler(5), isNotNull);
      expect(cache.ler(5), isEmpty);
    });

    test('gravar e ler faz round-trip preservando a ordem', () {
      final cache = CacheDeLayout<String>()..gravar(3, ['a', 'b', 'c']);
      expect(cache.ler(3), ['a', 'b', 'c']);
    });

    test('a lista devolvida é imutável', () {
      // O cache é compartilhado entre as páginas: um chamador que mutasse a
      // lista corromperia o que a próxima abertura fosse ler.
      final cache = CacheDeLayout<String>()..gravar(1, ['a']);
      expect(() => cache.ler(1)!.add('b'), throwsUnsupportedError);
    });

    test('mutar a lista de origem depois de gravar não afeta o cache', () {
      final origem = ['a'];
      final cache = CacheDeLayout<String>()..gravar(1, origem);
      origem.add('b');
      expect(cache.ler(1), ['a']);
    });

    test('gravar de novo substitui o conteúdo anterior', () {
      final cache = CacheDeLayout<String>()
        ..gravar(1, ['a'])
        ..gravar(1, ['x', 'y']);
      expect(cache.ler(1), ['x', 'y']);
      expect(cache.tamanho, 1);
    });

    test('invalidar tira só a estrutura pedida', () {
      final cache = CacheDeLayout<String>()
        ..gravar(1, ['a'])
        ..gravar(2, ['b']);
      cache.invalidar(1);
      expect(cache.ler(1), isNull);
      expect(cache.ler(2), ['b']);
      expect(cache.tamanho, 1);
    });

    test('invalidar estrutura ausente não estoura', () {
      final cache = CacheDeLayout<String>()..gravar(1, ['a']);
      expect(() => cache.invalidar(99), returnsNormally);
      expect(cache.ler(1), ['a']);
    });

    test('invalidarTudo esvazia', () {
      final cache = CacheDeLayout<String>()
        ..gravar(1, ['a'])
        ..gravar(2, ['b'])
        ..invalidarTudo();
      expect(cache.ler(1), isNull);
      expect(cache.ler(2), isNull);
      expect(cache.tamanho, 0);
    });
  });
}
