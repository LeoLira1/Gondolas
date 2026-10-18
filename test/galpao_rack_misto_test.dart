import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_config.dart';
import 'package:gondola_camda/galpao_pilhas.dart';
import 'package:gondola_camda/galpao_saldo.dart';
import 'package:gondola_camda/galpao_scene.dart';
import 'package:gondola_camda/gondola_scene.dart' show corEnderecoDivergente;
import 'package:gondola_camda/gravacao_lote.dart';
import 'package:gondola_camda/models.dart' show corConferenciaCiano;

List<RackGalpao> _pilha() => const [
  RackGalpao(
    rackUuid: 'r1',
    posicao: 52,
    ordem: 1,
    produtoCodigo: 'P1',
    produtoNome: 'PRODUTO 1',
    quantidade: 100,
  ),
  RackGalpao(
    rackUuid: 'r2',
    posicao: 52,
    ordem: 2,
    produtoCodigo: 'P2',
    produtoNome: 'PRODUTO 2',
    quantidade: 200,
  ),
];

List<RackGalpao>? _adiciona(
  List<RackGalpao> pilha,
  String codigo, {
  int ordem = 1,
  double quantidade = 5,
}) => pilhaAposAdicionarProduto(
  pilha,
  ordem,
  itemUuid: 'i-$codigo',
  produtoCodigo: codigo,
  produtoNome: 'NOME $codigo',
  quantidade: quantidade,
);

OperacaoPendente _op(
  TipoOperacao tipo, {
  String uuid = 'op',
  String? rackUuid = 'r1',
  String? itemUuid,
  String produtoCodigo = '',
  double quantidade = 0,
}) => OperacaoPendente(
  uuid: uuid,
  tipo: tipo,
  banco: 'b',
  criadaEm: DateTime(2026, 10, 18, 9),
  local: 52,
  rackUuid: rackUuid,
  itemUuid: itemUuid,
  produtoCodigo: produtoCodigo,
  quantidade: quantidade,
);

void main() {
  group('pilhaAposAdicionarProduto', () {
    test('o produto entra no rack sem mexer na pilha', () {
      final nova = _adiciona(_pilha(), 'X')!;
      expect(nova.length, 2);
      expect(nova[0].misto, isTrue);
      expect(nova[0].produtoCodigo, 'P1');
      expect(nova[0].itens.single.produtoCodigo, 'X');
      expect(nova[0].itens.single.itemUuid, 'i-X');
      expect(nova[0].contem('X'), isTrue);
      expect(nova[1].misto, isFalse);
      // A original não muda.
      expect(_pilha()[0].misto, isFalse);
    });

    test('no máximo cinco produtos por rack', () {
      var pilha = _pilha();
      for (final c in ['A', 'B', 'C', 'D']) {
        pilha = _adiciona(pilha, c)!;
      }
      expect(pilha[0].produtos.length, GalpaoConfig.produtosMaxPorRack);
      expect(_adiciona(pilha, 'E'), isNull);
    });

    test('produto que já está no rack, ordem inexistente ou zero: recusa', () {
      final com = _adiciona(_pilha(), 'X')!;
      expect(_adiciona(com, 'X'), isNull);
      expect(_adiciona(com, 'P1'), isNull);
      expect(_adiciona(_pilha(), 'X', ordem: 3), isNull);
      expect(_adiciona(_pilha(), 'X', quantidade: 0), isNull);
    });
  });

  group('pilhaAposRemoverProduto', () {
    test('item sai e o rack fica', () {
      final com = _adiciona(_adiciona(_pilha(), 'X')!, 'Y')!;
      final nova = pilhaAposRemoverProduto(com, 1, 'i-X');
      expect(nova.length, 2);
      expect(nova[0].produtoCodigo, 'P1');
      expect([for (final p in nova[0].itens) p.produtoCodigo], ['Y']);
    });

    test('principal sai e o item mais antigo sobe', () {
      final com = _adiciona(_adiciona(_pilha(), 'X')!, 'Y')!;
      final nova = pilhaAposRemoverProduto(com, 1, null);
      expect(nova[0].produtoCodigo, 'X');
      expect(nova[0].quantidade, 5);
      expect(nova[0].ordem, 1);
      expect(nova[0].rackUuid, 'r1');
      expect([for (final p in nova[0].itens) p.produtoCodigo], ['Y']);
    });

    test('último produto saindo é o rack saindo: a pilha desce', () {
      final nova = pilhaAposRemoverProduto(_pilha(), 1, null);
      expect(nova.length, 1);
      expect(nova.single.produtoCodigo, 'P2');
      expect(nova.single.ordem, 1);
    });

    test('o item acompanha o rack quando a pilha desce', () {
      final com = _adiciona(_pilha(), 'X', ordem: 2)!;
      final nova = pilhaAposEsvaziar(com, 1);
      expect(nova.single.ordem, 1);
      expect(nova.single.itens.single.produtoCodigo, 'X');
    });
  });

  test('pilhaAposAjustarProduto troca só o item apontado', () {
    final com = _adiciona(_adiciona(_pilha(), 'X')!, 'Y')!;
    final nova = pilhaAposAjustarProduto(com, 1, 'i-Y', 42);
    expect(nova[0].quantidade, 100);
    expect([for (final p in nova[0].itens) p.quantidade], [5, 42]);
    // null é o principal.
    expect(pilhaAposAjustarProduto(com, 1, null, 7)[0].quantidade, 7);
  });

  group('aplicarPendentesGalpao com rack misto', () {
    test('adicionar, ajustar e remover em fila, por UUID', () {
      final resultado = aplicarPendentesGalpao({52: _pilha()}, [
        _op(
          TipoOperacao.galpaoAdicionarProduto,
          uuid: 'i1',
          produtoCodigo: 'X',
          quantidade: 3,
        ),
        _op(
          TipoOperacao.galpaoAdicionarProduto,
          uuid: 'i2',
          produtoCodigo: 'Y',
          quantidade: 4,
        ),
        _op(TipoOperacao.galpaoAjustar, itemUuid: 'i2', quantidade: 9),
        _op(TipoOperacao.galpaoRemoverProduto, itemUuid: 'i1'),
      ]);
      final rack = resultado[52]!.first;
      expect(rack.produtoCodigo, 'P1');
      expect(rack.itens.single.produtoCodigo, 'Y');
      expect(rack.itens.single.quantidade, 9);
    });

    test('item que já veio do banco não entra duas vezes', () {
      final doBanco = _adiciona(_pilha(), 'X')!;
      final resultado = aplicarPendentesGalpao({52: doBanco}, [
        _op(
          TipoOperacao.galpaoAdicionarProduto,
          uuid: 'i-X',
          produtoCodigo: 'X',
          quantidade: 5,
        ),
      ]);
      expect(resultado[52]!.first.itens.length, 1);
    });
  });

  group('OperacaoPendente do rack misto', () {
    test('itemUuid vai e volta pelo JSON; registro antigo é o principal', () {
      final op = _op(TipoOperacao.galpaoRemoverProduto, itemUuid: 'i9');
      final volta = OperacaoPendente.decodificarLista(
        OperacaoPendente.codificarLista([op]),
      ).single;
      expect(volta.tipo, TipoOperacao.galpaoRemoverProduto);
      expect(volta.itemUuid, 'i9');
      final antigo = Map<String, Object?>.from(
        _op(TipoOperacao.galpaoAjustar).toJson(),
      )..remove('itemUuid');
      expect(OperacaoPendente.fromJson(antigo)!.itemUuid, isNull);
    });

    test('são do galpão e mexem no endereçado', () {
      expect(TipoOperacao.galpaoAdicionarProduto.doGalpao, isTrue);
      expect(TipoOperacao.galpaoRemoverProduto.doGalpao, isTrue);
      expect(
        _op(
          TipoOperacao.galpaoAdicionarProduto,
          quantidade: 6,
        ).deltaEnderecado,
        6,
      );
    });
  });

  group('corDoRackGalpao', () {
    final misto = _adiciona(_pilha(), 'X')!.first;
    final cores = {'P1': Colors.green, 'X': Colors.purple};

    test('sem alerta, fica na cor do principal', () {
      expect(
        corDoRackGalpao(misto, corPorProduto: cores),
        Colors.green,
      );
    });

    test('um item em falta ou procurado pinta o rack inteiro', () {
      expect(
        corDoRackGalpao(misto, corPorProduto: cores, destacadoCodigo: 'X'),
        corCamda,
      );
      expect(
        corDoRackGalpao(
          misto,
          corPorProduto: cores,
          mostrarSaldo: true,
          saldos: const {
            'X': SaldoProduto(
              codigo: 'X',
              qtdSistema: 10,
              enderecado: 5,
            ),
          },
        ),
        corEnderecoDivergente,
      );
      expect(
        corDoRackGalpao(
          misto,
          modoConferencia: true,
          codigosConferencia: const {'X'},
        ),
        corConferenciaCiano,
      );
    });
  });
}
