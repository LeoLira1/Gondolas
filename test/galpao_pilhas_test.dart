import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_config.dart';
import 'package:gondola_camda/galpao_pilhas.dart';
import 'package:gondola_camda/galpao_scene.dart';

List<RackGalpao> _pilha(int n) => [
      for (var ordem = 1; ordem <= n; ordem++)
        RackGalpao(
          posicao: 52,
          ordem: ordem,
          produtoCodigo: 'P$ordem',
          produtoNome: 'PRODUTO $ordem',
          quantidade: ordem * 100.0,
        ),
    ];

void main() {
  group('pilhaAposLancar', () {
    test('produto novo entra sempre no topo', () {
      final nova = pilhaAposLancar(_pilha(2),
          posicao: 52,
          produtoCodigo: 'NOVO',
          produtoNome: 'PRODUTO NOVO',
          quantidade: 500)!;
      expect(nova.length, 3);
      expect(nova.last.ordem, 3);
      expect(nova.last.produtoCodigo, 'NOVO');
      // Os de baixo não mudam: não existe inserir no meio.
      expect(nova[0].produtoCodigo, 'P1');
      expect(nova[1].produtoCodigo, 'P2');
    });

    test('pilha cheia recusa o lançamento', () {
      expect(
        pilhaAposLancar(_pilha(GalpaoConfig.niveisMax),
            posicao: 52,
            produtoCodigo: 'NOVO',
            produtoNome: '',
            quantidade: 1),
        isNull,
      );
    });

    test('não muta a pilha original', () {
      final original = _pilha(1);
      pilhaAposLancar(original,
          posicao: 52, produtoCodigo: 'N', produtoNome: '', quantidade: 1);
      expect(original.length, 1);
    });
  });

  group('pilhaAposEsvaziar', () {
    test('esvaziar a base faz TODOS os de cima descerem e renumerarem', () {
      // É a regra que define o galpão: o nível não é identidade. Quem era
      // N2 passa a SER N1.
      final nova = pilhaAposEsvaziar(_pilha(3), 1);
      expect(nova.length, 2);
      expect(nova[0].ordem, 1);
      expect(nova[0].produtoCodigo, 'P2');
      expect(nova[1].ordem, 2);
      expect(nova[1].produtoCodigo, 'P3');
    });

    test('esvaziar o meio desce só os de cima', () {
      final nova = pilhaAposEsvaziar(_pilha(4), 2);
      expect(nova.map((r) => r.produtoCodigo), ['P1', 'P3', 'P4']);
      expect(nova.map((r) => r.ordem), [1, 2, 3]);
    });

    test('esvaziar o topo não mexe nos de baixo', () {
      final nova = pilhaAposEsvaziar(_pilha(3), 3);
      expect(nova.map((r) => r.produtoCodigo), ['P1', 'P2']);
      expect(nova.map((r) => r.ordem), [1, 2]);
    });

    test('a quantidade acompanha o rack que desceu, não o nível', () {
      final nova = pilhaAposEsvaziar(_pilha(3), 1);
      // P2 tinha 200 e continua com 200 ao virar N1.
      expect(nova[0].quantidade, 200);
    });

    test('ordem inexistente devolve a pilha como está', () {
      final original = _pilha(2);
      expect(pilhaAposEsvaziar(original, 4), same(original));
      expect(pilhaAposEsvaziar(const [], 1), isEmpty);
    });

    test('a ordem resultante é sempre contínua de 1 a n', () {
      for (var tirar = 1; tirar <= 4; tirar++) {
        final nova = pilhaAposEsvaziar(_pilha(4), tirar);
        expect(nova.map((r) => r.ordem), [1, 2, 3],
            reason: 'esvaziando N$tirar');
      }
    });
  });
}
