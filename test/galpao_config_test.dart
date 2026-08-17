import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_config.dart';

void main() {
  group('estrutura do galpão', () {
    test('são 85 posições em 8 ruas, e 340 endereços', () {
      expect(GalpaoConfig.ruas.length, 8);
      expect(GalpaoConfig.posicoes.length, 85);
      expect(GalpaoConfig.totalPosicoes, 85);
      expect(GalpaoConfig.totalEnderecos, 340);
    });

    test('a numeração é global, contínua de 1 a 85 e sem repetição', () {
      final numeros = GalpaoConfig.posicoes.map((p) => p.numero).toList();
      expect(numeros.toSet().length, 85, reason: 'há número repetido');
      expect(numeros, List.generate(85, (i) => i + 1));
    });

    test('cada rua tem a quantidade e a faixa de números contadas no galpão', () {
      const esperado = {
        1: (14, 1, 14),
        2: (11, 15, 25),
        3: (11, 26, 36),
        4: (10, 37, 46),
        5: (10, 47, 56),
        6: (11, 57, 67),
        7: (11, 68, 78),
        8: (7, 79, 85),
      };
      for (final rua in GalpaoConfig.ruas) {
        final (quantidade, primeiro, ultimo) = esperado[rua.numero]!;
        expect(rua.quantidade, quantidade, reason: 'Rua ${rua.numero}');
        expect(rua.primeiroNumero, primeiro, reason: 'Rua ${rua.numero}');
        expect(rua.ultimoNumero, ultimo, reason: 'Rua ${rua.numero}');

        final daRua = GalpaoConfig.posicoes
            .where((p) => p.rua.numero == rua.numero)
            .map((p) => p.numero)
            .toList();
        expect(daRua.length, quantidade, reason: 'Rua ${rua.numero}');
        expect(daRua.first, primeiro, reason: 'Rua ${rua.numero}');
        expect(daRua.last, ultimo, reason: 'Rua ${rua.numero}');
      }
    });

    test('toda posição pertence a exatamente uma rua', () {
      for (var n = 1; n <= 85; n++) {
        final rua = GalpaoConfig.ruaDe(n);
        expect(rua, isNotNull, reason: 'posição $n sem rua');
        expect(GalpaoConfig.porNumero(n)!.rua.numero, rua!.numero);
        expect(GalpaoConfig.ruas.where((r) => r.contem(n)).length, 1,
            reason: 'posição $n em mais de uma rua');
      }
      expect(GalpaoConfig.ruaDe(0), isNull);
      expect(GalpaoConfig.ruaDe(86), isNull);
      expect(GalpaoConfig.porNumero(86), isNull);
    });
  });

  group('coordenadas', () {
    test('cada rua fica na sua coordenada fixa e no seu eixo', () {
      for (final rua in GalpaoConfig.ruas) {
        for (final p in GalpaoConfig.posicoes
            .where((p) => p.rua.numero == rua.numero)) {
          if (rua.eixo == EixoRua.z) {
            expect(p.x, closeTo(rua.coordFixa, 1e-9), reason: 'pos ${p.numero}');
          } else {
            expect(p.z, closeTo(rua.coordFixa, 1e-9), reason: 'pos ${p.numero}');
          }
        }
      }
    });

    test('posições vizinhas ficam a um passo de 1,34 m', () {
      for (final rua in GalpaoConfig.ruas) {
        final daRua = GalpaoConfig.posicoes
            .where((p) => p.rua.numero == rua.numero)
            .toList();
        for (var i = 1; i < daRua.length; i++) {
          final anterior = daRua[i - 1], atual = daRua[i];
          final passo = rua.eixo == EixoRua.z
              ? (atual.z - anterior.z).abs()
              : (atual.x - anterior.x).abs();
          expect(passo, closeTo(GalpaoConfig.passoPosicao, 1e-9),
              reason: 'entre ${anterior.numero} e ${atual.numero}');
        }
      }
    });

    test('a rua é simétrica em torno do seu centro', () {
      for (final rua in GalpaoConfig.ruas) {
        final coords = GalpaoConfig.posicoes
            .where((p) => p.rua.numero == rua.numero)
            .map((p) => rua.eixo == EixoRua.z ? p.z : p.x)
            .toList();
        final meio = (coords.reduce((a, b) => a < b ? a : b) +
                coords.reduce((a, b) => a > b ? a : b)) /
            2;
        expect(meio, closeTo(rua.centro, 1e-9), reason: 'Rua ${rua.numero}');
      }
    });

    test('a numeração 1 → 36 percorre o perímetro na ordem do croqui', () {
      // Confirmado no galpão: sobe pela direita (Z positivo → Z negativo),
      // atravessa o topo para a esquerda (X positivo → X negativo) e desce
      // pela esquerda (Z negativo → Z positivo).
      expect(GalpaoConfig.porNumero(1)!.z,
          greaterThan(GalpaoConfig.porNumero(14)!.z));
      expect(GalpaoConfig.porNumero(15)!.x,
          greaterThan(GalpaoConfig.porNumero(25)!.x));
      expect(GalpaoConfig.porNumero(26)!.z,
          lessThan(GalpaoConfig.porNumero(36)!.z));
      // A Rua 6 também é numerada de Z positivo para Z negativo.
      expect(GalpaoConfig.porNumero(57)!.z,
          greaterThan(GalpaoConfig.porNumero(67)!.z));
      // A Rua 7, ao contrário da 6, desce.
      expect(GalpaoConfig.porNumero(68)!.z,
          lessThan(GalpaoConfig.porNumero(78)!.z));
    });

    test('a Rua 8 fecha o fundo, espelhando a Rua 2 do outro lado', () {
      final rua2 = GalpaoConfig.ruas.firstWhere((r) => r.numero == 2);
      final rua8 = GalpaoConfig.ruas.firstWhere((r) => r.numero == 8);

      // As duas atravessam o galpão na horizontal, em pontas opostas do Z.
      expect(rua8.eixo, EixoRua.x);
      expect(rua2.coordFixa, lessThan(0));
      expect(rua8.coordFixa, greaterThan(0));

      // Fica DEPOIS da ponta da Rua 1 (o croqui a desenha por fora dela), com
      // a mesma folga que a Rua 2 tem na ponta oposta.
      final naRua1 = GalpaoConfig.posicoes.where((p) => p.rua.numero == 1);
      final zMaisAlto = naRua1.map((p) => p.z).reduce((a, b) => a > b ? a : b);
      final zMaisBaixo = naRua1.map((p) => p.z).reduce((a, b) => a < b ? a : b);
      expect(rua8.coordFixa, greaterThan(zMaisAlto));
      expect(rua8.coordFixa - zMaisAlto,
          closeTo(zMaisBaixo - rua2.coordFixa, 1e-9));

      // Numeração ao contrário da Rua 2: 79 no extremo X negativo (lado da
      // Rua 3), 85 andando para o meio do galpão.
      expect(GalpaoConfig.porNumero(79)!.x,
          lessThan(GalpaoConfig.porNumero(85)!.x));
      // E alinhada pela esquerda com a Rua 2, como no croqui.
      expect(GalpaoConfig.porNumero(79)!.x,
          closeTo(GalpaoConfig.porNumero(25)!.x, 1e-9));
    });

    test('os pares 4/5 e 6/7 estão encostados fundo com fundo', () {
      double eixoDa(int rua) =>
          GalpaoConfig.ruas.firstWhere((r) => r.numero == rua).coordFixa;
      expect((eixoDa(5) - eixoDa(4)).abs(),
          closeTo(GalpaoConfig.distanciaParCostas, 1e-9));
      expect((eixoDa(7) - eixoDa(6)).abs(),
          closeTo(GalpaoConfig.distanciaParCostas, 1e-9));
    });

    test('o rack tem 1,20 m ao longo da rua e 1,00 m atravessado', () {
      final naRua1 = GalpaoConfig.porNumero(1)!;   // eixo Z
      expect(naRua1.tamanhoZ, GalpaoConfig.comprimentoRack);
      expect(naRua1.tamanhoX, GalpaoConfig.larguraRack);
      final naRua2 = GalpaoConfig.porNumero(15)!;  // eixo X
      expect(naRua2.tamanhoX, GalpaoConfig.comprimentoRack);
      expect(naRua2.tamanhoZ, GalpaoConfig.larguraRack);
    });

    test('nenhum par de posições se sobrepõe no chão', () {
      final ps = GalpaoConfig.posicoes;
      for (var i = 0; i < ps.length; i++) {
        for (var j = i + 1; j < ps.length; j++) {
          final a = ps[i], b = ps[j];
          final separadoEmX =
              (a.x - b.x).abs() >= (a.tamanhoX + b.tamanhoX) / 2 - 1e-9;
          final separadoEmZ =
              (a.z - b.z).abs() >= (a.tamanhoZ + b.tamanhoZ) / 2 - 1e-9;
          expect(separadoEmX || separadoEmZ, isTrue,
              reason: 'posições ${a.numero} e ${b.numero} se sobrepõem');
        }
      }
    });

    test('a etiqueta fica do lado do corredor, fora da posição', () {
      for (final p in GalpaoConfig.posicoes) {
        final (ex, ez) = p.pontoEtiqueta;
        if (p.rua.eixo == EixoRua.z) {
          expect(ez, closeTo(p.z, 1e-9), reason: 'pos ${p.numero}');
          expect((ex - p.x) * p.rua.ladoCorredor,
              greaterThan(p.tamanhoX / 2 - 1e-9),
              reason: 'pos ${p.numero}');
        } else {
          expect(ex, closeTo(p.x, 1e-9), reason: 'pos ${p.numero}');
          expect((ez - p.z) * p.rua.ladoCorredor,
              greaterThan(p.tamanhoZ / 2 - 1e-9),
              reason: 'pos ${p.numero}');
        }
      }
    });
  });

  group('pilha', () {
    test('o nível sai da ordem na pilha, com passo de 1,16 m', () {
      expect(GalpaoConfig.yBase(1), 0);
      expect(GalpaoConfig.yTopo(1), closeTo(GalpaoConfig.alturaNivel, 1e-9));
      for (var ordem = 2; ordem <= GalpaoConfig.niveisMax; ordem++) {
        expect(GalpaoConfig.yBase(ordem) - GalpaoConfig.yBase(ordem - 1),
            closeTo(GalpaoConfig.passoNivel, 1e-9));
      }
      // Passo maior que a altura: os racks não se interpenetram.
      expect(GalpaoConfig.passoNivel,
          greaterThanOrEqualTo(GalpaoConfig.alturaNivel));
    });
  });

  group('memoização', () {
    test('posicoes devolve sempre a mesma instância imutável', () {
      expect(identical(GalpaoConfig.posicoes, GalpaoConfig.posicoes), isTrue);
      expect(() => GalpaoConfig.posicoes.add(GalpaoConfig.posicoes.first),
          throwsUnsupportedError);
    });

    test('porNumero devolve a mesma instância da lista', () {
      expect(identical(GalpaoConfig.porNumero(52), GalpaoConfig.posicoes[51]),
          isTrue);
    });
  });
}
