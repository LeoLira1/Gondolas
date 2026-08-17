import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/embalagem.dart';

void main() {
  group('litragemDoNome', () {
    test('acha a litragem no fim do nome cadastrado', () {
      expect(litragemDoNome('HERBICIDA BORAL 500 SC 20L'), 20);
      expect(litragemDoNome('ADUBO FOLIAR ZOETIS BORO 20L'), 20);
      expect(litragemDoNome('HERBICIDA NORTOX 2,4-D 806 SL 5L'), 5);
    });

    test('a concentração no meio do nome não engana o parse', () {
      // '500 SC' e '806 SL' têm número seguido de letras, mas não de um L
      // colado a dígito — só a litragem do fim casa.
      expect(litragemDoNome('FUNGICIDA AZOX 200 SC 5L'), 5);
      expect(litragemDoNome('INSETICIDA 150 SL 20L'), 20);
    });

    test('aceita espaço antes do L e vírgula no número', () {
      expect(litragemDoNome('OLEO MINERAL 20 L'), 20);
      expect(litragemDoNome('ADJUVANTE 0,5L'), 0.5);
    });

    test('vale a ÚLTIMA ocorrência — a embalagem fecha o nome', () {
      expect(litragemDoNome('KIT PULVERIZACAO 5L + BALDE 20L'), 20);
    });

    test('nome sem litragem devolve null', () {
      expect(litragemDoNome('LUVA NITRILICA PROTECAO PAR'), isNull);
      expect(litragemDoNome('SEMENTE MILHO HIBRIDO SC 60kg'), isNull);
    });
  });

  group('quantidadeEmbalada', () {
    test('produto de 20 L: litros ÷ 20, em baldes', () {
      expect(quantidadeEmbalada('HERBICIDA BORAL 500 SC 20L', 1800),
          '90 baldes');
      expect(quantidadeEmbalada('ADUBO FOLIAR BORO 20L', 20), '1 balde');
    });

    test('produto de 5 L: a caixa fecha 4 × 5 L, então também ÷ 20', () {
      expect(quantidadeEmbalada('HERBICIDA NORTOX 806 SL 5L', 240),
          '12 caixas');
      expect(quantidadeEmbalada('FUNGICIDA AZOX 5L', 20), '1 caixa');
    });

    test('conta que não fecha mostra a fração, não esconde', () {
      expect(quantidadeEmbalada('HERBICIDA BORAL 500 SC 20L', 1810),
          '90.5 baldes');
    });

    test('sem litragem no nome (ou litragem sem regra) não converte', () {
      expect(quantidadeEmbalada('LUVA NITRILICA PAR', 7), isNull);
      // 1 L não tem convenção de caixa/balde definida: número cru.
      expect(quantidadeEmbalada('INSETICIDA LANNATE BR 1L', 12), isNull);
    });
  });

  group('unidade de manuseio (o que se digita ao lançar)', () {
    test('20 L é balde, 5 L é caixa, resto não tem unidade', () {
      expect(unidadeDoNome('HERBICIDA BORAL 500 SC 20L'), 'balde');
      expect(unidadeDoNome('HERBICIDA NORTOX 806 SL 5L'), 'caixa');
      expect(unidadeDoNome('INSETICIDA LANNATE BR 1L'), isNull);
      expect(unidadeDoNome('LUVA NITRILICA PAR'), isNull);
    });

    test('quem conta 45 baldes lança 45, e viram 900 L no banco', () {
      // O caminho de ida: a tela digita unidades, o banco guarda litros.
      expect(litrosDeUnidades(45), 900);
      // E o de volta fecha o ciclo — 900 L exibidos são 45 baldes.
      expect(quantidadeEmbalada('HERBICIDA BORAL 500 SC 20L', 900),
          '45 baldes');
    });

    test('caixa de 5 L também fecha 20 L (4 unidades)', () {
      expect(litrosDeUnidades(12), 240);
      expect(quantidadeEmbalada('FUNGICIDA AZOX 5L', 240), '12 caixas');
    });
  });

  group('formatarNumero', () {
    test('inteiro sai sem casa decimal, fração sai com uma', () {
      expect(formatarNumero(90), '90');
      expect(formatarNumero(90.5), '90.5');
      expect(formatarNumero(90.25), '90.3');
    });
  });
}
