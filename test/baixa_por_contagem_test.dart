import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/baixa_por_contagem.dart';
import 'package:gondola_camda/estoque_localizado_service.dart';

// A contagem de referência de todos os testes: ontem às 8h. Os endereços
// nascem ANTES dela (é o caso normal — a carga foi lançada, depois contada) e
// quem quiser testar o contrário passa uma data própria.
final contadoEm = DateTime(2026, 8, 17, 8);
final lancadoEm = DateTime(2026, 8, 10, 15);

EnderecoLocalizado _endereco(
  String tipo,
  int num,
  double qtd, {
  int face = 0,
  int nivel = 1,
  DateTime? em,
  String codigo = '10432',
}) =>
    EnderecoLocalizado(
      produtoCodigo: codigo,
      localTipo:     tipo,
      localNum:      num,
      faceOuColuna:  face,
      andarOuNivel:  nivel,
      quantidade:    qtd,
      atualizadoEm:  (em ?? lancadoEm).toIso8601String(),
    );

EnderecoLocalizado rack(int posicao, double qtd,
        {int nivel = 1, DateTime? em, String codigo = '10432'}) =>
    _endereco('galpao', posicao, qtd,
        nivel: nivel, em: em, codigo: codigo);

EnderecoLocalizado gondola(int num, double qtd,
        {int face = 1, int andar = 0, DateTime? em}) =>
    _endereco('gondola', num, qtd, face: face, nivel: andar, em: em);

EnderecoLocalizado estante(int num, double qtd,
        {int coluna = 1, int nivel = 0, DateTime? em}) =>
    _endereco('estante', num, qtd, face: coluna, nivel: nivel, em: em);

ContagemDoProduto contagem({
  double sistema = 70,
  double delta = 0,
  DateTime? confirmadaEm = null,
  bool semContagem = false,
  List<String> codigos = const ['10432'],
}) =>
    ContagemDoProduto(
      codigos:           codigos,
      nome:              'HERBICIDA BORAL 500 SC 20L',
      qtdSistema:        sistema,
      deltaDivergencias: delta,
      confirmadaEm:      semContagem ? null : (confirmadaEm ?? contadoEm),
    );

void main() {
  group('a venda sai dos endereços', () {
    test('vendeu 30: o rack cai de 100 para 70', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 70),
        enderecos: [rack(52, 100)],
      );

      expect(plano.aplicavel, isTrue);
      expect(plano.deduzido, 30);
      expect(plano.enderecadoDepois, 70);
      expect(plano.ajustes, hasLength(1));
      expect(plano.ajustes.single.qtdAnterior, 100);
      expect(plano.ajustes.single.qtdNova, 70);
      expect(plano.ajustes.single.esvazia, isFalse);
    });

    test('a baixa atravessa vários racks quando um não cobre', () {
      // 20 + 30 + 60 endereçados, sistema 40: saem 70, de três paletes.
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 40),
        enderecos: [rack(52, 60), rack(7, 20), rack(88, 30)],
      );

      expect(plano.aplicavel, isTrue);
      expect(plano.deduzido, 70);
      expect(plano.enderecadoDepois, 40);
      // Galpão: o palete ABERTO primeiro. 20 e 30 zeram, e o de 60 perde 20.
      expect(plano.ajustes.map((a) => a.endereco.localNum), [7, 88, 52]);
      expect(plano.ajustes.map((a) => a.qtdNova), [0, 0, 40]);
      expect(plano.ajustes.map((a) => a.esvazia), [true, true, false]);
    });

    test('o rack que zera é marcado para esvaziar, não para virar 0', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 0),
        enderecos: [rack(52, 45)],
      );

      expect(plano.ajustes.single.qtdNova, 0);
      expect(plano.ajustes.single.esvazia, isTrue);
    });
  });

  group('de onde sai primeiro', () {
    test('a loja antes do galpão, e a gôndola antes da estante', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 0),
        enderecos: [rack(52, 5), estante(3, 5), gondola(9, 5)],
      );

      expect(plano.ajustes.map((a) => a.endereco.localTipo),
          ['gondola', 'estante', 'galpao']);
    });

    test('na loja, o mais cheio primeiro', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 12),
        enderecos: [gondola(9, 4, face: 1), gondola(9, 10, face: 3)],
        // 14 endereçados, sistema 12: saem 2, do slot de 10.
      );

      expect(plano.ajustes, hasLength(1));
      expect(plano.ajustes.single.endereco.faceOuColuna, 3);
      expect(plano.ajustes.single.qtdNova, 8);
    });

    test('no galpão, o mais vazio primeiro — o palete aberto termina antes', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 490),
        enderecos: [rack(52, 500), rack(7, 8)],
        // 508 endereçados, sistema 490: saem 18. O palete de 8 acaba, e o
        // fechado de 500 só perde os 10 restantes.
      );

      expect(plano.ajustes.map((a) => a.endereco.localNum), [7, 52]);
      expect(plano.ajustes.map((a) => a.qtdNova), [0, 490]);
    });

    test('empate de quantidade cai numa ordem estável', () {
      final enderecos = [
        rack(52, 10, nivel: 2),
        rack(7, 10, nivel: 1),
        rack(52, 10, nivel: 1),
      ];
      final direto   = ordenarParaBaixa(enderecos);
      final invertido = ordenarParaBaixa(enderecos.reversed);

      expect(direto.map((e) => '${e.localNum}·${e.andarOuNivel}'),
          ['7·1', '52·1', '52·2']);
      expect(invertido.map((e) => '${e.localNum}·${e.andarOuNivel}'),
          direto.map((e) => '${e.localNum}·${e.andarOuNivel}'));
    });
  });

  group('as divergências do cooperado entram na conta', () {
    test('falta lançada para um cooperado abaixa o alvo', () {
      // Sistema 100, 30 lançados como falta de um cooperado: o chão tem 70,
      // e é para 70 que os endereços vão.
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 100, delta: -30),
        enderecos: [rack(52, 100)],
      );

      expect(plano.contagem.alvoEnderecado, 70);
      expect(plano.aplicavel, isTrue);
      expect(plano.enderecadoDepois, 70);
    });

    test('sobra lançada sobe o alvo e a baixa não acontece', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 100, delta: 10),
        enderecos: [rack(52, 100)],
      );

      expect(plano.contagem.alvoEnderecado, 110);
      expect(plano.aplicavel, isFalse);
      expect(plano.motivo, MotivoSemBaixa.semExcesso);
      expect(plano.faltaEnderecar, 10);
    });

    test('sem a divergência, a mesma falta viraria baixa a mais', () {
      // O mesmo produto do primeiro teste do grupo, ignorando a divergência:
      // é o erro que a leitura de `divergencias` evita.
      final semDivergencia = planejarBaixa(
        contagem:  contagem(sistema: 100),
        enderecos: [rack(52, 100)],
      );

      expect(semDivergencia.aplicavel, isFalse);
      expect(semDivergencia.deduzido, 0);
    });

    test('divergência maior que o próprio sistema não é aplicada', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 20, delta: -50),
        enderecos: [rack(52, 100)],
      );

      expect(plano.aplicavel, isFalse);
      expect(plano.motivo, MotivoSemBaixa.alvoNegativo);
      expect(plano.naoCoberto, 30);
      expect(plano.ajustes, isEmpty);
    });
  });

  group('o que a baixa nunca faz', () {
    test('sem contagem confirmada, não mexe em nada', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 70, semContagem: true),
        enderecos: [rack(52, 100)],
      );

      expect(plano.aplicavel, isFalse);
      expect(plano.motivo, MotivoSemBaixa.semContagem);
      expect(plano.deduzido, 0);
    });

    test('endereçado abaixo do contado não vira quantidade nova', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 145),
        enderecos: [rack(52, 90)],
      );

      expect(plano.aplicavel, isFalse);
      expect(plano.motivo, MotivoSemBaixa.semExcesso);
      expect(plano.faltaEnderecar, 55);
      expect(plano.enderecadoDepois, 90);
    });

    test('endereço mexido DEPOIS da contagem tira o produto inteiro', () {
      // Palete novo lançado hoje, contagem de ontem: o sistema ainda não sabe
      // da carga que chegou, e baixar contra ele apagaria o palete novo.
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 70),
        enderecos: [
          rack(52, 100),
          rack(7, 200, em: contadoEm.add(const Duration(hours: 2))),
        ],
      );

      expect(plano.aplicavel, isFalse);
      expect(plano.motivo, MotivoSemBaixa.mexidoDepoisDaContagem);
      expect(plano.ajustes, isEmpty);
    });

    test('endereço sem data fica de fora — não dá para afirmar a ordem', () {
      final plano = planejarBaixa(
        contagem: contagem(sistema: 70),
        enderecos: [
          const EnderecoLocalizado(
            produtoCodigo: '10432',
            localTipo:     'galpao',
            localNum:      52,
            faceOuColuna:  0,
            andarOuNivel:  1,
            quantidade:    100,
          ),
        ],
      );

      expect(plano.motivo, MotivoSemBaixa.mexidoDepoisDaContagem);
    });

    test('produto sem endereço nenhum não é notícia', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 70),
        enderecos: const [],
      );

      expect(plano.motivo, MotivoSemBaixa.semEndereco);
      expect(plano.aplicavel, isFalse);
    });

    test('diferença de arredondamento não vira baixa', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 99.9995),
        enderecos: [rack(52, 100)],
      );

      expect(plano.aplicavel, isFalse);
      expect(plano.motivo, MotivoSemBaixa.semExcesso);
    });
  });

  group('ordem de gravação no galpão', () {
    test('dentro da posição, do nível mais alto para o mais baixo', () {
      // A pilha 52 perde os níveis 1 e 3. Gravado de baixo para cima, o
      // esvaziamento do 1 faria o 3 virar 2 e o ajuste seguinte acertaria o
      // palete errado.
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 0),
        enderecos: [
          rack(52, 10, nivel: 1),
          rack(52, 40, nivel: 3),
          rack(7, 5, nivel: 1),
        ],
      );

      final ordem = ordenarGravacaoGalpao(plano.ajustes)
          .map((a) => '${a.endereco.localNum}·${a.endereco.andarOuNivel}');
      expect(ordem, ['7·1', '52·3', '52·1']);
    });

    test('endereço de loja não entra na fila do galpão', () {
      final plano = planejarBaixa(
        contagem:  contagem(sistema: 0),
        enderecos: [gondola(9, 5), rack(52, 5)],
      );

      expect(ordenarGravacaoGalpao(plano.ajustes), hasLength(1));
      expect(ordenarGravacaoGalpao(plano.ajustes).single.endereco.localTipo,
          'galpao');
    });
  });

  test('uma contagem, uma baixa: aplicada, ela não se repete', () {
    final antes = planejarBaixa(
      contagem:  contagem(sistema: 70),
      enderecos: [rack(52, 100)],
    );
    expect(antes.aplicavel, isTrue);

    // Como fica depois da gravação: a quantidade nova, com a data da
    // gravação — que é necessariamente posterior à contagem.
    final depois = planejarBaixa(
      contagem:  contagem(sistema: 70),
      enderecos: [
        rack(52, antes.ajustes.single.qtdNova,
            em: contadoEm.add(const Duration(minutes: 5))),
      ],
    );

    expect(depois.aplicavel, isFalse);
    expect(depois.motivo, MotivoSemBaixa.mexidoDepoisDaContagem);

    // E uma contagem NOVA, posterior à baixa, volta a valer.
    final recontado = planejarBaixa(
      contagem: contagem(
          sistema: 50, confirmadaEm: contadoEm.add(const Duration(days: 1))),
      enderecos: [
        rack(52, 70, em: contadoEm.add(const Duration(minutes: 5))),
      ],
    );
    expect(recontado.aplicavel, isTrue);
    expect(recontado.deduzido, 20);
  });

  test('a baixa vale para o produto inteiro, somando os códigos irmãos', () {
    // 222534 e US222534 são a mesma pilha: 84 endereçados entre os dois,
    // sistema 11 + 60. A baixa atravessa os dois códigos.
    final plano = planejarBaixa(
      contagem:  contagem(sistema: 71, codigos: ['222534', 'US222534']),
      enderecos: [
        rack(52, 11, codigo: '222534'),
        rack(53, 73, codigo: 'US222534'),
      ],
    );

    expect(plano.enderecadoAntes, 84);
    expect(plano.deduzido, 13);
    expect(plano.enderecadoDepois, 71);
  });

  group('resumo', () {
    test('soma produtos, unidades e endereços tocados', () {
      final um = planejarBaixa(
        contagem:  contagem(sistema: 70),
        enderecos: [rack(52, 100)],
      );
      final dois = planejarBaixa(
        contagem:  contagem(sistema: 0, codigos: ['999']),
        enderecos: [rack(7, 5, codigo: '999'), rack(8, 5, codigo: '999')],
      );
      final resumo = ResumoBaixa(aplicados: [um, dois]);

      expect(resumo.produtos, 2);
      expect(resumo.totalDeduzido, 40);
      expect(resumo.enderecosTocados, 3);
      expect(resumo.semBaixas, isFalse);
    });

    test('o que continua faltando endereço aparece no resumo', () {
      final faltando = planejarBaixa(
        contagem:  contagem(sistema: 145),
        enderecos: [rack(52, 90)],
      );
      final resumo = ResumoBaixa(ignorados: [faltando]);

      expect(resumo.semBaixas, isTrue);
      expect(resumo.comFaltaDeEndereco, hasLength(1));
      expect(resumo.comFaltaDeEndereco.single.faltaEnderecar, 55);
    });
  });
}
