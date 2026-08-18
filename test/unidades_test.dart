import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_migracao_unidades.dart';
import 'package:gondola_camda/unidades.dart';

void main() {
  group('formatarNumero', () {
    test('sem casa decimal inútil', () {
      expect(formatarNumero(45), '45');
      expect(formatarNumero(45.0), '45');
    });

    test('uma casa quando a conta não fecha', () {
      expect(formatarNumero(45.5), '45.5');
    });
  });

  group('quantidadeEmUnidades', () {
    test('plural e singular', () {
      expect(quantidadeEmUnidades(45), '45 unidades');
      expect(quantidadeEmUnidades(1), '1 unidade');
      expect(quantidadeEmUnidades(0), '0 unidades');
    });

    test('o número da tela é o mesmo do sistema — nada de dividir por 20',
        () {
      // O caso do relato: o scanner mostra 559 para o produto e o galpão
      // mostrava 19.4 (388 ÷ 20). Agora o que se lê é o que está gravado.
      expect(quantidadeEmUnidades(559), '559 unidades');
      expect(quantidadeEmUnidades(45), '45 unidades');
    });
  });

  group('migração dos dados antigos (litros → unidades)', () {
    test('produto de 20 L e de 5 L eram gravados em litros', () {
      expect(quantidadeLegadaEmLitros('HERBICIDA BORAL 500 SC 20L'), isTrue);
      expect(quantidadeLegadaEmLitros('HERBICIDA NORTOX 2,4-D 806 SL 5L'),
          isTrue);
      expect(quantidadeLegadaEmLitros('OLEO MINERAL 20 L'), isTrue);
    });

    test('vale a ÚLTIMA litragem do nome — a concentração vem antes', () {
      expect(quantidadeLegadaEmLitros('KIT PULVERIZACAO 5L + BALDE 20L'),
          isTrue);
    });

    test('produto sem litragem conversível ficava como digitado', () {
      // Estes NÃO podem ser divididos por 20: nunca foram multiplicados.
      expect(quantidadeLegadaEmLitros('INSETICIDA LANNATE BR 1L'), isFalse);
      expect(quantidadeLegadaEmLitros('LUVA NITRILICA PROTECAO PAR'), isFalse);
      expect(quantidadeLegadaEmLitros('SEMENTE MILHO HIBRIDO SC 60kg'),
          isFalse);
    });

    test('45 baldes gravados como 900 L voltam a ser 45', () {
      expect(900 / litrosPorUnidadeLegado, 45);
      expect(240 / litrosPorUnidadeLegado, 12);
    });
  });
}
