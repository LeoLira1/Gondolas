import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/outbox.dart';

void main() {
  // Atalho: a decisão sempre compara as colunas que os dois estados declaram.
  DecisaoReaplicacao decidir({
    Map<String, Object?>? remoto,
    Map<String, Object?>? anterior,
    Map<String, Object?>? estadoFinal,
  }) =>
      decidirReaplicacao(
        remoto:      remoto,
        anterior:    anterior,
        estadoFinal: estadoFinal,
        colunas: {...?anterior?.keys, ...?estadoFinal?.keys},
      );

  group('protocolo anterior → final', () {
    test('remoto onde estava: aplica o final', () {
      expect(
        decidir(
          remoto:      {'quantidade': 14},
          anterior:    {'quantidade': 14},
          estadoFinal: {'quantidade': 57},
        ),
        DecisaoReaplicacao.aplicarFinal,
      );
    });

    test('remoto já no final: nada a fazer', () {
      expect(
        decidir(
          remoto:      {'quantidade': 57},
          anterior:    {'quantidade': 14},
          estadoFinal: {'quantidade': 57},
        ),
        DecisaoReaplicacao.jaAplicada,
      );
    });

    test('remoto em outro lugar: conflito, nunca sobrescreve', () {
      expect(
        decidir(
          remoto:      {'quantidade': 33}, // outra pessoa mexeu no meio
          anterior:    {'quantidade': 14},
          estadoFinal: {'quantidade': 57},
        ),
        DecisaoReaplicacao.conflito,
        reason: 'reaplicar aqui apagaria o trabalho de quem gravou 33',
      );
    });

    test('linha que não existia e continua não existindo: aplica', () {
      expect(
        decidir(
          remoto:      null,
          anterior:    null,
          estadoFinal: {'quantidade': 90},
        ),
        DecisaoReaplicacao.aplicarFinal,
      );
    });

    test('linha que não existia mas alguém criou: conflito', () {
      expect(
        decidir(
          remoto:      {'quantidade': 12},
          anterior:    null,
          estadoFinal: {'quantidade': 90},
        ),
        DecisaoReaplicacao.conflito,
      );
    });

    test('DELETE: some se ainda estiver como estava', () {
      expect(
        decidir(
          remoto:      {'quantidade': 14},
          anterior:    {'quantidade': 14},
          estadoFinal: null,
        ),
        DecisaoReaplicacao.aplicarFinal,
      );
    });

    test('DELETE já feito é jaAplicada, não conflito', () {
      expect(
        decidir(
          remoto:      null,
          anterior:    {'quantidade': 14},
          estadoFinal: null,
        ),
        DecisaoReaplicacao.jaAplicada,
      );
    });

    test('mutação que não mudava nada termina como jaAplicada', () {
      // anterior == final. A pergunta "já está no final?" vem primeiro
      // justamente para não mandar reescrever o que já está lá.
      expect(
        decidir(
          remoto:      {'quantidade': 14},
          anterior:    {'quantidade': 14},
          estadoFinal: {'quantidade': 14},
        ),
        DecisaoReaplicacao.jaAplicada,
      );
    });

    test('operação sem estado declarado não tem o que reaplicar', () {
      // O seed da planta e a limpeza de endereços zerados: registrados para
      // que nenhuma mutação fique de fora, mas se reexecutam sozinhos.
      expect(
        decidirReaplicacao(
          remoto:      {'numero': 1},
          anterior:    null,
          estadoFinal: null,
          colunas:     const {},
        ),
        DecisaoReaplicacao.jaAplicada,
      );
    });
  });

  group('comparação não tropeça em formato', () {
    test('90 e 90.0 são a mesma quantidade de baldes', () {
      expect(
        decidir(
          remoto:      {'quantidade': 90},
          anterior:    {'quantidade': 90.0},
          estadoFinal: {'quantidade': 45},
        ),
        DecisaoReaplicacao.aplicarFinal,
        reason: 'o SQLite devolve int ou double conforme o caminho; '
            'tratar como diferentes acusaria conflito numa linha idêntica',
      );
    });

    test('ordem das colunas não conta', () {
      expect(
        canonico({'b': 2, 'a': 1}),
        canonico({'a': 1, 'b': 2}),
      );
    });

    test('coluna fora do estado declarado é ignorada', () {
      // `atualizado_em` muda a cada gravação. Se entrasse na conta, toda
      // comparação terminaria em conflito.
      expect(
        decidir(
          remoto: {'quantidade': 14, 'atualizado_em': '2026-09-03T10:00:00'},
          anterior:    {'quantidade': 14},
          estadoFinal: {'quantidade': 57},
        ),
        DecisaoReaplicacao.aplicarFinal,
      );
    });

    test('estado ausente não se confunde com estado vazio', () {
      expect(canonico(null), isNot(canonico(const {})));
    });
  });

  group('o que a reconstrução não reaplica sozinha', () {
    test('as três do galpão exigem conferência', () {
      // (posição, ordem) deixa de apontar para o mesmo rack depois de uma
      // renumeração — e ajustarQuantidade entra junto: o VALOR é absoluto,
      // o endereço não é.
      expect(operacaoExigeRevisaoManual('galpao.lancar'), isTrue);
      expect(operacaoExigeRevisaoManual('galpao.esvaziar'), isTrue);
      expect(operacaoExigeRevisaoManual('galpao.ajustarQuantidade'), isTrue);
    });

    test('salvar layout inteiro também', () {
      expect(operacaoExigeRevisaoManual('layout.salvarGondola'), isTrue);
      expect(operacaoExigeRevisaoManual('layout.salvarEstante'), isTrue);
    });

    test('as de chave estável são reaplicáveis', () {
      for (final op in [
        'estoqueLocalizado.upsertQuantidade',
        'estoqueLocalizado.deleteEndereco',
        'estoqueLocalizado.concluirContagem',
        'barracao.atribuir',
        'barracao.esvaziar',
        'palete.criar',
        'palete.atualizar',
        'palete.desativar',
      ]) {
        expect(operacaoExigeRevisaoManual(op), isFalse, reason: op);
      }
    });
  });

  group('colunas comparadas', () {
    MutacaoOutbox mutacao({
      Map<String, Object?>? anterior,
      Map<String, Object?>? estadoFinal,
    }) =>
        MutacaoOutbox(
          uuid: 'u',
          operacao: 'x.y',
          alvo: const AlvoMutacao(tabela: 't', chave: {'id': 1}),
          estadoAnterior: anterior,
          estadoFinal: estadoFinal,
          criadoEm: DateTime(2026, 9, 3),
          dispositivo: 'teste',
        );

    test('é a união dos dois estados', () {
      expect(
        mutacao(
          anterior:    {'a': 1},
          estadoFinal: {'b': 2},
        ).colunasComparadas,
        {'a', 'b'},
      );
    });

    test('DELETE compara pelas colunas do estado anterior', () {
      expect(
        mutacao(anterior: {'quantidade': 5}, estadoFinal: null)
            .colunasComparadas,
        {'quantidade'},
      );
    });
  });

  group('uuid', () {
    test('formato v4 e sem repetir', () {
      final gerados = {for (var i = 0; i < 500; i++) gerarUuidV4()};
      expect(gerados.length, 500);
      final v4 = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      for (final u in gerados) {
        expect(v4.hasMatch(u), isTrue, reason: u);
      }
    });
  });
}
