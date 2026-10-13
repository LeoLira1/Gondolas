import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:gondola_camda/estocados_busca.dart' show prefixoEstocado;
import 'package:gondola_camda/gravacao_lote.dart';
import 'package:gondola_camda/models.dart'
    show localTipoBarracao, localTipoGalpao;

OperacaoPendente _op({
  String uuid = 'u1',
  TipoOperacao tipo = TipoOperacao.galpaoLancar,
  double quantidade = 10,
  double? anterior,
}) => OperacaoPendente(
  uuid: uuid,
  tipo: tipo,
  banco: 'b',
  criadaEm: DateTime(2026, 10, 13, 9),
  local: 52,
  rackUuid: tipo == TipoOperacao.galpaoLancar ? null : 'r1',
  produtoCodigo: '100',
  produtoNome: "ÓLEO D'ÁGUA",
  quantidade: quantidade,
  quantidadeAnterior: anterior,
  rotulo: '52 · N1',
);

void main() {
  group('literais do lote', () {
    test('texto: aspas dobradas, NUL fora, null vira NULL', () {
      expect(sqlTexto("D'ÁGUA; 5L"), "'D''ÁGUA; 5L'");
      expect(sqlTexto('a\u0000b'), "'ab'");
      expect(sqlTexto(null), 'NULL');
    });

    test('número: inteiro sem ".0", fração como está, não finito recusado',
        () {
      expect(sqlNumero(20.0), '20');
      expect(sqlNumero(7.5), '7.5');
      expect(sqlNumero(3), '3');
      expect(() => sqlNumero(double.nan), throwsArgumentError);
      expect(() => sqlNumero(double.infinity), throwsArgumentError);
    });

    test('o lote é BEGIN IMMEDIATE … COMMIT', () {
      final texto = textoDoLote(['SELECT 1', 'SELECT 2']);
      expect(texto, startsWith('BEGIN IMMEDIATE;'));
      expect(texto, endsWith('COMMIT'));
    });

    test('valores do esquema batem com os do app', () {
      expect(localTipoGalpaoSql, localTipoGalpao);
      expect(localTipoBarracaoSql, localTipoBarracao);
      expect(prefixoEstocadoSql, prefixoEstocado);
    });

    test('toda escrita é condicionada ao UUID e o carimbo é o último passo',
        () {
      for (final tipo in TipoOperacao.values) {
        final cmds = _op(tipo: tipo).comandos(
          aplicadaEm: '2026-10-13T10:00:00',
          dispositivo: 'android-1',
        );
        expect(cmds.last, startsWith('INSERT OR IGNORE INTO app_mutacoes'));
        for (final c in cmds.take(cmds.length - 1)) {
          expect(
            c,
            contains("uuid = 'u1'"),
            reason: '${tipo.name}: $c',
          );
        }
      }
    });
  });

  group('classificarFalhaGravacao', () {
    test('a guarda de conflito volta com o motivo', () {
      final f = classificarFalhaGravacao(
        Exception(
          'PanicException(called `Result::unwrap()` on an `Err` value: '
          'Hrana(StreamError(Error { message: "SQLite error: bad JSON path: '
          "'GONDOLAS_CONFLITO:pilha_cheia'\", code: \"SQLITE_ERROR\" })))",
        ),
      );
      expect(f.tipo, TipoFalhaGravacao.conflito);
      expect(f.motivo, 'pilha_cheia');
      expect(f.transitoria, isFalse);
    });

    test('prazo estourado e falha de HTTP são de rede (reenvia)', () {
      expect(
        classificarFalhaGravacao(TimeoutException('x')).tipo,
        TipoFalhaGravacao.rede,
      );
      expect(
        classificarFalhaGravacao(
          Exception('Hrana(Http("error trying to connect: dns error"))'),
        ).tipo,
        TipoFalhaGravacao.rede,
      );
      expect(
        classificarFalhaGravacao(
          Exception('Hrana(Api("status=400, body=stream expired"))'),
        ).tipo,
        TipoFalhaGravacao.rede,
      );
    });

    test('trava ocupada é passageira', () {
      expect(
        classificarFalhaGravacao(Exception('code: "SQLITE_BUSY"')).tipo,
        TipoFalhaGravacao.rede,
      );
    });

    test('SQL recusado pelo servidor não é reenviado', () {
      final f = classificarFalhaGravacao(
        Exception(
          'StreamError(Error { message: "UNIQUE constraint failed", '
          'code: "SQLITE_CONSTRAINT" })',
        ),
      );
      expect(f.tipo, TipoFalhaGravacao.recusada);
    });
  });

  group('OperacaoPendente', () {
    test('ida e volta pelo JSON', () {
      final op = _op(
        tipo: TipoOperacao.galpaoAjustar,
        quantidade: 30,
        anterior: 12,
      );
      final volta = OperacaoPendente.decodificarLista(
        OperacaoPendente.codificarLista([op]),
      ).single;
      expect(volta.uuid, op.uuid);
      expect(volta.tipo, op.tipo);
      expect(volta.rackUuid, 'r1');
      expect(volta.produtoNome, "ÓLEO D'ÁGUA");
      expect(volta.quantidade, 30);
      expect(volta.quantidadeAnterior, 12);
      expect(volta.criadaEm, op.criadaEm);
    });

    test('registro ilegível fica de fora, sem derrubar os outros', () {
      final texto =
          '[${OperacaoPendente.codificarLista([_op()]).substring(1, OperacaoPendente.codificarLista([_op()]).length - 1)}, {"tipo": "naoExiste"}]';
      expect(OperacaoPendente.decodificarLista(texto), hasLength(1));
      expect(OperacaoPendente.decodificarLista('lixo'), isEmpty);
      expect(OperacaoPendente.decodificarLista(null), isEmpty);
    });

    test('delta do endereçado por tipo', () {
      expect(_op().deltaEnderecado, 10);
      expect(
        _op(tipo: TipoOperacao.galpaoAjustar, quantidade: 30, anterior: 12)
            .deltaEnderecado,
        18,
      );
      expect(
        _op(tipo: TipoOperacao.galpaoEsvaziar, quantidade: 0, anterior: 12)
            .deltaEnderecado,
        -12,
      );
    });
  });
}
