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

    test('três códigos do mesmo nome somam entre si, em qualquer ordem', () {
      final grupos = gruposDeCodigos(
        codigos: const ['US254185', '254185'],
        produtoIdPorCodigo: const {},
        nomePorCodigo: const {
          '254185':    _boral,
          'US254185':  _boral,
          '100254185': _boral,
        },
      );
      expect(grupos['US254185'], {'254185', 'US254185', '100254185'});
      expect(grupos['254185'],   {'254185', 'US254185', '100254185'});
    });
  });

  // O travamento do relato: o app abria o galpão e ficava em "não está
  // respondendo". A busca do irmão comparava CADA código de estoque_localizado
  // com CADA nome do catálogo, recalculando a chave do nome a cada par — com
  // 3000 endereços e 5000 produtos são 15 milhões de chaves, quase um minuto
  // parado na thread da interface. O índice por chave deixa a conta linear.
  //
  // O limite é folgado de propósito (a versão nova roda em dezenas de
  // milissegundos, a antiga passava de um minuto): o que se quer travar aqui é
  // a VOLTA do laço dentro do laço, não a velocidade da máquina do CI.
  group('gruposDeCodigos no tamanho real do catálogo', () {
    test('5000 nomes × 3000 códigos não trava a interface', () {
      const catalogo = 5000, enderecados = 3000;
      final nomes = <String, String>{
        for (var i = 0; i < catalogo; i++)
          'C${100000 + i}': 'PRODUTO ${i % 900} DE 20 LITROS',
      };
      final codigos = [
        for (var i = 0; i < enderecados; i++) 'C${100000 + (i * 7) % catalogo}',
      ];

      final relogio = Stopwatch()..start();
      final grupos = gruposDeCodigos(
        codigos:            codigos,
        produtoIdPorCodigo: const {},
        nomePorCodigo:      nomes,
      );
      relogio.stop();

      expect(grupos, hasLength(codigos.toSet().length));
      // O irmão continua sendo achado: 5000 códigos para 900 nomes distintos.
      expect(grupos['C100000']!.length, greaterThan(1));
      expect(relogio.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });
}
