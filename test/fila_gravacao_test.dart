import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gondola_camda/barracao_service.dart';
import 'package:gondola_camda/fila_gravacao.dart';
import 'package:gondola_camda/fila_gravacao_ui.dart';
import 'package:gondola_camda/galpao_pilhas.dart';
import 'package:gondola_camda/galpao_scene.dart' show RackGalpao;
import 'package:gondola_camda/gravacao_lote.dart';

OperacaoPendente _lancar(String uuid, {int posicao = 5, double q = 10}) =>
    OperacaoPendente(
      uuid: uuid,
      tipo: TipoOperacao.galpaoLancar,
      banco: 'b',
      criadaEm: DateTime(2026, 10, 13),
      local: posicao,
      produtoCodigo: 'P$uuid',
      produtoNome: 'Produto $uuid',
      quantidade: q,
      rotulo: '$posicao',
    );

OperacaoPendente _sobreRack(
  TipoOperacao tipo,
  String uuid,
  String rack, {
  int posicao = 5,
  double q = 0,
}) => OperacaoPendente(
  uuid: uuid,
  tipo: tipo,
  banco: 'b',
  criadaEm: DateTime(2026, 10, 13),
  local: posicao,
  rackUuid: rack,
  quantidade: q,
);

/// Fila com disco em memória e um "servidor" programável.
class _Banco {
  String? disco;
  final enviados = <String>[];
  final roteiro = <String, List<Object?>>{};

  FilaGravacao fila() => FilaGravacao.para(
    executar: (op) async {
      enviados.add(op.uuid);
      final respostas = roteiro[op.uuid];
      if (respostas != null && respostas.isNotEmpty) {
        final r = respostas.removeAt(0);
        if (r != null) throw r;
      }
    },
    ler: () async => disco,
    gravar: (t) async => disco = t,
    esperar: (_) => Future<void>.delayed(Duration.zero),
  );
}

const _semRede = FalhaGravacao(TipoFalhaGravacao.rede, 'sem rede');
const _pilhaCheia = FalhaGravacao(
  TipoFalhaGravacao.conflito,
  'x',
  motivo: 'pilha_cheia',
);

void main() {
  group('FilaGravacao', () {
    test('envia na ordem, uma por vez, e esvazia o disco', () async {
      final banco = _Banco();
      final fila = banco.fila();
      await fila.carregar();
      final eventos = <EventoFila>[];
      fila.eventos.listen(eventos.add);
      await fila.enfileirar(_lancar('a'));
      await fila.enfileirar(_lancar('b'));
      await fila.esvaziada();
      await Future<void>.delayed(Duration.zero);
      expect(banco.enviados, ['a', 'b']);
      expect(eventos.map((e) => e.operacao.uuid), ['a', 'b']);
      expect(eventos.every((e) => e.gravada), isTrue);
      expect(OperacaoPendente.decodificarLista(banco.disco), isEmpty);
    });

    test('falha de rede: reenvia o MESMO uuid até passar, sem perder nada',
        () async {
      final banco = _Banco()..roteiro['a'] = [_semRede, _semRede, null];
      final fila = banco.fila();
      await fila.carregar();
      await fila.enfileirar(_lancar('a'));
      await fila.enfileirar(_lancar('b'));
      await fila.esvaziada();
      expect(banco.enviados, ['a', 'a', 'a', 'b']);
      expect(fila.tentativas, 0);
    });

    test('enquanto a rede falha, a operação continua guardada no disco',
        () async {
      final banco = _Banco()..roteiro['a'] = List.filled(50, _semRede);
      final fila = FilaGravacao.para(
        executar: (op) async {
          banco.enviados.add(op.uuid);
          throw _semRede;
        },
        ler: () async => banco.disco,
        gravar: (t) async => banco.disco = t,
        // Espera "longa": a fila fica parada entre tentativas.
        esperar: (_) => Completer<void>().future,
      );
      await fila.carregar();
      await fila.enfileirar(_lancar('a'));
      await Future<void>.delayed(Duration.zero);
      expect(fila.tentativas, 1);
      expect(fila.pendentes.single.uuid, 'a');
      expect(
        OperacaoPendente.decodificarLista(banco.disco).single.uuid,
        'a',
      );
      // "Tentar já" interrompe a espera.
      fila.tentarAgora();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(banco.enviados.length, greaterThanOrEqualTo(2));
    });

    test('conflito tira a operação da fila, avisa, e a próxima segue',
        () async {
      final banco = _Banco()..roteiro['a'] = [_pilhaCheia];
      final fila = banco.fila();
      await fila.carregar();
      final eventos = <EventoFila>[];
      fila.eventos.listen(eventos.add);
      await fila.enfileirar(_lancar('a'));
      await fila.enfileirar(_lancar('b'));
      await fila.esvaziada();
      await Future<void>.delayed(Duration.zero);
      expect(banco.enviados, ['a', 'b']);
      expect(eventos.first.gravada, isFalse);
      expect(eventos.first.falha!.motivo, 'pilha_cheia');
      expect(mensagemFalhaFila(eventos.first), contains('cheia'));
      expect(eventos.last.gravada, isTrue);
    });

    test('o que ficou no disco (app fechado) é enviado na abertura', () async {
      final banco = _Banco()
        ..disco = OperacaoPendente.codificarLista([_lancar('velha')]);
      final fila = banco.fila();
      await fila.enfileirar(_lancar('nova'));
      await fila.carregar();
      await fila.esvaziada();
      expect(banco.enviados, ['velha', 'nova']);
    });

    test('descartar todas esvazia a fila e o disco', () async {
      final banco = _Banco();
      final fila = FilaGravacao.para(
        executar: (op) async => throw _semRede,
        ler: () async => banco.disco,
        gravar: (t) async => banco.disco = t,
        esperar: (_) => Completer<void>().future,
      );
      await fila.carregar();
      await fila.enfileirar(_lancar('a'));
      await fila.enfileirar(_lancar('b'));
      final esvaziou = fila.esvaziada();
      final descartadas = await fila.descartarTodas();
      await esvaziou;
      expect(descartadas.map((o) => o.uuid), ['a', 'b']);
      expect(fila.vazia, isTrue);
      expect(OperacaoPendente.decodificarLista(banco.disco), isEmpty);
    });

    test('espera entre tentativas cresce até 20 s', () {
      expect(FilaGravacao.atrasoParaTentativa(1), const Duration(seconds: 1));
      expect(FilaGravacao.atrasoParaTentativa(3), const Duration(seconds: 4));
      expect(FilaGravacao.atrasoParaTentativa(6), const Duration(seconds: 20));
      expect(FilaGravacao.atrasoParaTentativa(40), const Duration(seconds: 20));
    });
  });

  group('aplicarPendentesGalpao (banco + fila por cima)', () {
    RackGalpao rack(String uuid, int ordem, {double q = 1}) => RackGalpao(
      rackUuid: uuid,
      posicao: 5,
      ordem: ordem,
      produtoCodigo: 'X$uuid',
      quantidade: q,
    );

    test('lançamento pendente entra no topo com o próprio uuid', () {
      final r = aplicarPendentesGalpao({
        5: [rack('r1', 1)],
      }, [_lancar('novo')]);
      expect(r[5]!.map((x) => x.rackUuid), ['r1', 'novo']);
      expect(r[5]!.last.ordem, 2);
    });

    test('lançamento que o banco já tem não entra duas vezes', () {
      final r = aplicarPendentesGalpao({
        5: [rack('r1', 1), rack('novo', 2)],
      }, [_lancar('novo')]);
      expect(r[5], hasLength(2));
    });

    test('ajuste acha o rack pelo uuid mesmo com o nível mudado', () {
      final r = aplicarPendentesGalpao(
        {
          5: [rack('r2', 1, q: 3)], // r1 saiu em outro aparelho: r2 desceu
        },
        [_sobreRack(TipoOperacao.galpaoAjustar, 'a', 'r2', q: 9)],
      );
      expect(r[5]!.single.quantidade, 9);
    });

    test('lançar e ajustar offline, em sequência, sobre o rack novo', () {
      final r = aplicarPendentesGalpao({}, [
        _lancar('novo', q: 10),
        _sobreRack(TipoOperacao.galpaoAjustar, 'a', 'novo', q: 12),
      ]);
      expect(r[5]!.single.quantidade, 12);
    });

    test('esvaziar desce a pilha; rack ausente não mexe em nada', () {
      final banco = {
        5: [rack('r1', 1), rack('r2', 2)],
      };
      final r = aplicarPendentesGalpao(banco, [
        _sobreRack(TipoOperacao.galpaoEsvaziar, 'e', 'r1'),
        _sobreRack(TipoOperacao.galpaoEsvaziar, 'e2', 'sumiu'),
      ]);
      expect(r[5]!.single.rackUuid, 'r2');
      expect(r[5]!.single.ordem, 1);
      // O mapa original não é tocado.
      expect(banco[5], hasLength(2));
    });
  });

  test('aplicarPendentesBarracao: atribuir e esvaziar por cima do banco', () {
    const enderecos = [
      EnderecoBarracao(id: 1, rotulo: 'BAR-01', x: 0, z: 0),
      EnderecoBarracao(
        id: 2,
        rotulo: 'BAR-02',
        x: 0,
        z: 0,
        produtoCodigo: 'Y',
        quantidade: 3,
      ),
    ];
    OperacaoPendente op(TipoOperacao t, int id) => OperacaoPendente(
      uuid: '$id',
      tipo: t,
      banco: 'b',
      criadaEm: DateTime(2026),
      local: id,
      produtoCodigo: 'Z',
      produtoNome: 'Zeta',
      quantidade: 40,
    );
    final r = aplicarPendentesBarracao(enderecos, [
      op(TipoOperacao.barracaoAtribuir, 1),
      op(TipoOperacao.barracaoEsvaziar, 2),
      _lancar('galpao'), // de outro prédio: ignorado
    ]);
    expect(r[0].produtoCodigo, 'Z');
    expect(r[0].quantidade, 40);
    expect(r[1].ocupado, isFalse);
  });

  testWidgets('barra mostra "sem resposta" e não some enquanto há pendente',
      (tester) async {
    final fila = FilaGravacao.para(
      executar: (op) async => throw _semRede,
      ler: () async => null,
      gravar: (_) async {},
      esperar: (_) => Completer<void>().future,
    );
    await fila.carregar();
    await fila.enfileirar(_lancar('a'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: ListenableBuilder(
            listenable: fila,
            builder: (_, __) => BarraFilaGravacao(fila: fila),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Sem resposta do banco'), findsOneWidget);
    expect(find.text('Tentar já'), findsOneWidget);
  });
}
