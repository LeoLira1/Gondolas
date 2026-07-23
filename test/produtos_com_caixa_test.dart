import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/models.dart';

Produto prod(String codigo, {String? nome}) => Produto(
      codigo:    codigo,
      nome:      nome ?? 'Produto $codigo',
      categoria: '',
      corHex:    '#334455',
    );

void main() {
  final catalogo = [prod('OLEO'), prod('THION'), prod('TOPLINE')];

  test('lista os produtos do catálogo com caixa, na ordem do catálogo', () {
    final r = produtosComCaixa(
      idsComCaixa: ['TOPLINE', 'OLEO'],
      catalogo:    catalogo,
    );
    expect(r.map((p) => p.codigo), ['OLEO', 'TOPLINE']);
  });

  test('caixa cujo produto não está no catálogo ainda aparece na lista', () {
    // Cenário do bug: a caixa 253707 continua na prateleira (produto zerado /
    // fora do catálogo carregado) e precisa ter opção de exclusão.
    final r = produtosComCaixa(
      idsComCaixa: ['253707'],
      catalogo:    catalogo,
    );
    expect(r, hasLength(1));
    expect(r.single.codigo, '253707');
    // Sem cadastro, o nome cai para o próprio código.
    expect(r.single.nome, '253707');
  });

  test('mistura catálogo e avulsos: catálogo primeiro, avulsos por código', () {
    final r = produtosComCaixa(
      idsComCaixa: ['999888', 'THION', '253707', 'OLEO'],
      catalogo:    catalogo,
    );
    expect(r.map((p) => p.codigo), ['OLEO', 'THION', '253707', '999888']);
  });

  test('IDs repetidos (várias caixas do mesmo produto) não duplicam a linha',
      () {
    final r = produtosComCaixa(
      idsComCaixa: ['253707', '253707', 'OLEO', 'OLEO'],
      catalogo:    catalogo,
    );
    expect(r.map((p) => p.codigo), ['OLEO', '253707']);
  });

  test('prateleira vazia produz lista vazia', () {
    expect(produtosComCaixa(idsComCaixa: const [], catalogo: catalogo),
        isEmpty);
  });
}
