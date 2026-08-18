import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/codigos_vinculados.dart';

// O caso do relato: o mesmo herbicida tem duas linhas em estoque_mestre —
// '254185' (171 no sistema) e 'US254185' (388) —, e o app do scanner soma as
// duas em 559. O galpão lia só uma e mostrava a metade.
const _boral = 'HERBICIDA BORAL 500 SC 20L';

void main() {
  group('chaveNomeProduto', () {
    test('maiúsculo, sem acento e com espaços colapsados', () {
      expect(chaveNomeProduto('  adubo   orquídea 1l '),
          'ADUBO ORQUIDEA 1L');
    });

    test('acento decomposto também sai', () {
      expect(chaveNomeProduto('ORQUÍDEA'), 'ORQUIDEA');
    });
  });

  group('normalizarCodigo', () {
    test('caixa e espaço não criam dois grupos', () {
      expect(normalizarCodigo(' us254185 '), 'US254185');
      expect(normalizarCodigo('  '), isNull);
      expect(normalizarCodigo(null), isNull);
    });
  });

  group('gruposDeCodigos pelo cadastro do mapa', () {
    test('os dois códigos do produto somam, mesmo lendo só um', () {
      final grupos = gruposDeCodigos(
        codigos: const ['US254185'],
        produtoIdPorCodigo: const {
          '254185':   'p1',
          'US254185': 'p1',
          'US227579': 'p2',
        },
        nomePorCodigo: const {},
      );
      expect(grupos['US254185'], {'254185', 'US254185'});
    });

    test('produto de código único fica sozinho', () {
      final grupos = gruposDeCodigos(
        codigos: const ['US227579'],
        produtoIdPorCodigo: const {'US227579': 'p2'},
        nomePorCodigo: const {'US227579': 'HERBICIDA ALION 5L'},
      );
      expect(grupos['US227579'], {'US227579'});
    });

    test('o cadastro manda mais que o nome: mesmo nome, produtos separados',
        () {
      final grupos = gruposDeCodigos(
        codigos: const ['US254185'],
        produtoIdPorCodigo: const {'US254185': 'p1', '254185': 'p9'},
        nomePorCodigo: const {'US254185': _boral, '254185': _boral},
      );
      expect(grupos['US254185'], {'US254185'});
    });
  });

  group('gruposDeCodigos pelo nome, quando não há mapa', () {
    test('irmão de mesmo nome entra na soma', () {
      final grupos = gruposDeCodigos(
        codigos: const ['US254185'],
        produtoIdPorCodigo: const {},
        nomePorCodigo: const {
          '254185':   _boral,
          'US254185': _boral,
          'US227579': 'HERBICIDA ALION 5L',
        },
      );
      expect(grupos['US254185'], {'254185', 'US254185'});
    });

    test('irmão JÁ vinculado a outro produto no mapa fica de fora', () {
      final grupos = gruposDeCodigos(
        codigos: const ['US254185'],
        produtoIdPorCodigo: const {'254185': 'p9'},
        nomePorCodigo: const {'254185': _boral, 'US254185': _boral},
      );
      expect(grupos['US254185'], {'US254185'});
    });

    test('nome em branco não junta produto nenhum', () {
      final grupos = gruposDeCodigos(
        codigos: const ['SEMNOME'],
        produtoIdPorCodigo: const {},
        nomePorCodigo: const {'SEMNOME': '', 'OUTRO': ''},
      );
      expect(grupos['SEMNOME'], {'SEMNOME'});
    });

    test('código sem linha nenhuma no estoque_mestre fica sozinho', () {
      final grupos = gruposDeCodigos(
        codigos: const ['FANTASMA'],
        produtoIdPorCodigo: const {},
        nomePorCodigo: const {'US254185': _boral},
      );
      expect(grupos['FANTASMA'], {'FANTASMA'});
    });
  });
}
