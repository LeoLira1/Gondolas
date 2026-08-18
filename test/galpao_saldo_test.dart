import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_page.dart';
import 'package:gondola_camda/galpao_saldo.dart';
import 'package:gondola_camda/galpao_scene.dart';
import 'package:gondola_camda/gondola_scene.dart'
    show corEnderecoDivergente, corEnderecoDivergentePositiva;
import 'package:gondola_camda/models.dart' show corConferenciaCiano;

/// O herbicida do exemplo: 145 unidades no sistema. Uma unidade só nos dois
/// lados da conta — nada de litros nem de baldes (ver unidades.dart).
const _boral = 'HERBICIDA BORAL 500 SC 20L';

SaldoProduto _saldo(double enderecado) => SaldoProduto(
      codigo:     'BORAL',
      qtdSistema: 145,
      enderecado: enderecado,
    );

final _pilhas = <int, List<RackGalpao>>{
  52: const [
    RackGalpao(
        posicao: 52, ordem: 1, produtoCodigo: 'BORAL',
        produtoNome: _boral, quantidade: 90),
  ],
  1: const [
    RackGalpao(
        posicao: 1, ordem: 1, produtoCodigo: 'LUVA',
        produtoNome: 'LUVA NITRILICA PAR', quantidade: 30),
  ],
};

/// [chave] existe para os testes que reabrem o painel com outro saldo: sem
/// trocar a Key, o State sobrevive ao pump e a tarja continua mostrando o
/// saldo do pump anterior — o painel só substitui o que já sabe por um saldo
/// NOVO (ver didUpdateWidget), nunca por um vazio.
Widget _painel(Map<String, SaldoProduto> saldos, {String chave = 'p'}) =>
    MaterialApp(
      home: Scaffold(
        body: PainelEnderecoGalpao(
          key:      ValueKey(chave),
          toque:    const ToqueGalpao(posicao: 52, ordem: 1, ocupado: true),
          pilhas:   _pilhas,
          saldos:   saldos,
          onFechar: () {},
        ),
      ),
    );

void main() {
  group('SaldoProduto', () {
    test('falta quando o endereçado é menor que o sistema', () {
      final saldo = _saldo(90);
      expect(saldo.falta, isTrue);
      expect(saldo.sobra, isFalse);
      expect(saldo.fecha, isFalse);
      expect(saldo.quantoFalta, 55);
      expect(saldo.quantoSobra, 0);
    });

    test('sobra quando o endereçado passa do sistema', () {
      final saldo = _saldo(150);
      expect(saldo.sobra, isTrue);
      expect(saldo.falta, isFalse);
      expect(saldo.quantoSobra, 5);
    });

    test('fecha na igualdade e dentro da tolerância', () {
      expect(_saldo(145).fecha, isTrue);
      // Soma de várias linhas de estoque_localizado em double não pode pintar
      // o galpão inteiro de vermelho por resto de ponto flutuante.
      expect(_saldo(145 - SaldoProduto.tolerancia / 2).fecha, isTrue);
      expect(_saldo(145 + SaldoProduto.tolerancia / 2).fecha, isTrue);
    });

    test('comDelta soma no endereçado e preserva o sistema', () {
      final depois = _saldo(90).comDelta(20);
      expect(depois.enderecado, 110);
      expect(depois.qtdSistema, 145);
    });

    test('comDelta preserva os códigos somados', () {
      const saldo = SaldoProduto(
        codigo: 'US254185', qtdSistema: 559, enderecado: 512,
        codigosSomados: ['254185', 'US254185'],
      );
      expect(saldo.temCodigosSomados, isTrue);
      expect(saldo.comDelta(45).codigosSomados, ['254185', 'US254185']);
    });
  });

  group('saldosComDelta', () {
    test('devolve um mapa novo, sem mexer no anterior', () {
      final antes = {'BORAL': _saldo(90)};
      final depois =
          saldosComDelta(antes, codigo: 'BORAL', delta: 20);

      expect(identical(antes, depois), isFalse);
      expect(antes['BORAL']!.enderecado, 90);
      expect(depois['BORAL']!.enderecado, 110);
    });

    test('produto sem saldo conhecido não entra no mapa', () {
      final antes = {'BORAL': _saldo(90)};
      final depois = saldosComDelta(antes, codigo: 'NOVO', delta: 20);

      expect(identical(antes, depois), isTrue);
      expect(depois.containsKey('NOVO'), isFalse);
    });
  });

  group('montarSaldos', () {
    // O caso do relato, com os números das telas: o produto tem duas linhas
    // em estoque_mestre (171 + 388 = 559, o que o app do scanner mostra) e o
    // galpão via só 388.
    final grupos = {
      'US254185': {'254185', 'US254185'},
    };

    test('soma sistema e endereçado de todos os códigos do produto', () {
      final saldos = montarSaldos(
        codigos:             const ['US254185'],
        grupos:              grupos,
        sistemaPorCodigo:    const {'254185': 171, 'US254185': 388},
        enderecadoPorCodigo: const {'254185': 100, 'US254185': 412},
      );

      expect(saldos['US254185']!.qtdSistema, 559);
      expect(saldos['US254185']!.enderecado, 512);
      expect(saldos['US254185']!.codigosSomados, ['254185', 'US254185']);
    });

    test('código sem NENHUMA linha em estoque_mestre fica de fora', () {
      final saldos = montarSaldos(
        codigos:             const ['FANTASMA'],
        grupos:              const {},
        sistemaPorCodigo:    const {},
        enderecadoPorCodigo: const {'FANTASMA': 40},
      );
      expect(saldos, isEmpty);
    });

    test('a chave é o código como está em galpao_racks', () {
      // A cena procura a cor do cubo por rack.produtoCodigo — se a chave
      // fosse a forma normalizada, o cubo perderia a cor de saldo.
      final saldos = montarSaldos(
        codigos:             const ['us254185'],
        grupos:              {'US254185': {'254185', 'US254185'}},
        sistemaPorCodigo:    const {'254185': 171, 'US254185': 388},
        enderecadoPorCodigo: const {},
      );
      expect(saldos.keys, ['us254185']);
      expect(saldos['us254185']!.qtdSistema, 559);
    });
  });

  group('resumoSaldos', () {
    test('conta produtos, não racks', () {
      final saldos = {
        'BORAL': _saldo(90),                        // falta
        'OUTRO': SaldoProduto(
            codigo: 'OUTRO', qtdSistema: 100, enderecado: 140), // sobra
        'CERTO': SaldoProduto(
            codigo: 'CERTO', qtdSistema: 100, enderecado: 100), // fecha
      };
      final resumo = resumoSaldos(
          saldos, ['BORAL', 'BORAL', 'BORAL', 'OUTRO', 'CERTO', 'SEM_SALDO']);

      expect(resumo.comFalta, 1);
      expect(resumo.comSobra, 1);
    });
  });

  group('corRackGalpao com saldo', () {
    const cinza = Color(0xFF888888);
    final categorias = {'BORAL': cinza};

    Color cor({
      required Map<String, SaldoProduto> saldos,
      bool mostrarSaldo         = true,
      String? destacadoCodigo,
      bool modoConferencia      = false,
      Set<String> conferencia   = const {},
    }) =>
        corRackGalpao(
          produtoCodigo:      'BORAL',
          corPorProduto:      categorias,
          destacadoCodigo:    destacadoCodigo,
          modoConferencia:    modoConferencia,
          codigosConferencia: conferencia,
          mostrarSaldo:       mostrarSaldo,
          saldos:             saldos,
        );

    test('falta pinta de vermelho e sobra de azul', () {
      expect(cor(saldos: {'BORAL': _saldo(90)}), corEnderecoDivergente);
      expect(cor(saldos: {'BORAL': _saldo(150)}),
          corEnderecoDivergentePositiva);
    });

    test('saldo que fecha, produto sem saldo e leitura desligada mantêm a '
        'cor da categoria', () {
      expect(cor(saldos: {'BORAL': _saldo(145)}), cinza);
      expect(cor(saldos: const {}), cinza);
      expect(cor(saldos: {'BORAL': _saldo(90)}, mostrarSaldo: false), cinza);
    });

    test('conferência e busca têm precedência sobre o saldo', () {
      expect(
        cor(
          saldos:          {'BORAL': _saldo(90)},
          modoConferencia: true,
          conferencia:     const {'BORAL'},
        ),
        corConferenciaCiano,
      );
      expect(
        cor(saldos: {'BORAL': _saldo(90)}, destacadoCodigo: 'BORAL'),
        corCamda,
      );
    });
  });

  group('painel do endereço', () {
    testWidgets('rack de produto com carga por endereçar mostra o que falta',
        (tester) async {
      await tester.pumpWidget(_painel({'BORAL': _saldo(90)}));

      expect(find.text('Faltam 55 unidades por endereçar'), findsOneWidget);
      expect(find.text('Sistema 145 unidades · endereçado 90 unidades'),
          findsOneWidget);
    });

    testWidgets('endereçado acima do sistema mostra a sobra', (tester) async {
      await tester.pumpWidget(_painel({'BORAL': _saldo(150)}));

      expect(find.text('Sobram 5 unidades endereçados'), findsOneWidget);
    });

    testWidgets('saldo de produto com dois códigos diz quais foram somados',
        (tester) async {
      await tester.pumpWidget(_painel(const {
        'BORAL': SaldoProduto(
          codigo:         'BORAL',
          qtdSistema:     559,
          enderecado:     512,
          codigosSomados: ['254185', 'US254185'],
        ),
      }));

      expect(find.text('Sistema 559 unidades · endereçado 512 unidades'),
          findsOneWidget);
      expect(find.text('códigos somados · 254185 + US254185'), findsOneWidget);
    });

    testWidgets('saldo que fecha, e produto sem saldo sem tarja nenhuma',
        (tester) async {
      await tester.pumpWidget(_painel({'BORAL': _saldo(145)}));
      expect(find.text('Tudo endereçado'), findsOneWidget);

      await tester.pumpWidget(_painel(const {}, chave: 'sem-saldo'));
      expect(find.text('Tudo endereçado'), findsNothing);
      expect(find.textContaining('por endereçar'), findsNothing);
    });
  });

  group('galpão com a leitura de saldo', () {
    Widget pagina() => MaterialApp(
          home: GalpaoPage(
            pilhasIniciais:  _pilhas,
            catalogoInicial: const [],
            saldosIniciais:  {'BORAL': _saldo(90)},
          ),
        );

    testWidgets('a faixa resume os produtos por endereçar e o botão desliga '
        'a leitura', (tester) async {
      await tester.pumpWidget(pagina());
      await tester.pump();

      expect(find.text('1 produto por endereçar'), findsOneWidget);

      // Botão da barra superior: sólido com a leitura ligada.
      await tester.tap(find.byIcon(Icons.balance));
      await tester.pump();

      expect(find.text('1 produto por endereçar'), findsNothing);
      expect(find.byIcon(Icons.balance_outlined), findsOneWidget);
    });

    testWidgets('aberta com saldoAoAbrir: false, começa sem a faixa',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          pilhasIniciais:  _pilhas,
          catalogoInicial: const [],
          saldosIniciais:  {'BORAL': _saldo(90)},
          saldoAoAbrir:    false,
        ),
      ));
      await tester.pump();

      expect(find.text('1 produto por endereçar'), findsNothing);
    });
  });
}
