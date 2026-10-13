import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_page.dart';
import 'package:gondola_camda/galpao_scene.dart';
import 'package:gondola_camda/modo_conferencia_service.dart';
import 'package:gondola_camda/models.dart' show corConferenciaCiano;

/// O ponto ciano que marca, no chip da rua, que ali há pendente hoje.
final _pontoDeRuaPendente = find.byWidgetPredicate((w) =>
    w is Container &&
    w.decoration is BoxDecoration &&
    (w.decoration as BoxDecoration).shape == BoxShape.circle &&
    (w.decoration as BoxDecoration).color == corConferenciaCiano);

/// Racks de exemplo: a posição 52 guarda o herbicida pendente (o cubo que tem
/// de acender) e a 1 guarda um produto que ninguém vai conferir hoje.
final _pilhas = <int, List<RackGalpao>>{
  52: const [
    RackGalpao(
        posicao: 52, ordem: 1, produtoCodigo: 'BORAL',
        produtoNome: 'HERBICIDA BORAL 500 SC 20L', quantidade: 1800),
    RackGalpao(
        posicao: 52, ordem: 2, produtoCodigo: 'OUTRO',
        produtoNome: 'ADUBO FOLIAR 20L', quantidade: 400),
  ],
  1: const [
    RackGalpao(
        posicao: 1, ordem: 1, produtoCodigo: 'CALMO',
        produtoNome: 'LUVA NITRILICA PAR', quantidade: 30),
  ],
};

const _pendente = ItemPendente(
  codigo:     'BORAL',
  produto:    'HERBICIDA BORAL 500 SC 20L',
  categoria:  'HERBICIDAS',
  qtdEstoque: 90,
);

/// Conferência do dia com um único pendente, na posição 52.
final _conferencia = ModoConferenciaResultado(
  estruturas: const {},
  galpao: {
    52: const PosicaoConferencia(posicao: 52, itens: [_pendente]),
  },
  semEndereco: const [],
  totalProdutos: 0,
  totalFiltradosDeposito: 0,
);

Widget _pagina({bool aoAbrir = true}) => MaterialApp(
      home: GalpaoPage(
        pilhasIniciais:     _pilhas,
        catalogoInicial:    const [],
        conferenciaInicial: _conferencia,
        conferenciaAoAbrir: aoAbrir,
      ),
    );

GalpaoScene _cena(WidgetTester tester) =>
    tester.widget<GalpaoScene>(find.byType(GalpaoScene));

void main() {
  group('GalpaoPage · Modo Conferência', () {
    testWidgets('abrindo em conferência, a cena recebe os códigos e a contagem',
        (tester) async {
      await tester.pumpWidget(_pagina());
      await tester.pump();

      final cena = _cena(tester);
      expect(cena.modoConferencia, isTrue);
      // É o CÓDIGO que acende o cubo — o rack pode descer de nível a qualquer
      // esvaziamento.
      expect(cena.codigosConferencia, {'BORAL'});
      expect(cena.contagemConferencia, {52: 1});
      expect(
        find.textContaining('Conferência do dia: 1 produto em 1 posição'),
        findsOneWidget,
      );
      // A posição 52 é da Rua 5, na parte 1: ganham o ponto ciano o chip
      // dessa rua e o da parte em que ela está — nenhum outro.
      expect(_pontoDeRuaPendente, findsNWidgets(2));
      expect(
        find.descendant(
          of: find
              .ancestor(
                  of: find.text('R5'), matching: find.byType(Container))
              .first,
          matching: _pontoDeRuaPendente,
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find
              .ancestor(
                  of: find.text('Parte 1'), matching: find.byType(Container))
              .first,
          matching: _pontoDeRuaPendente,
        ),
        findsOneWidget,
      );
    });

    testWidgets('desligar o modo devolve a cena às cores de produto',
        (tester) async {
      await tester.pumpWidget(_pagina());
      await tester.pump();

      // Ícone cheio = toggle ligado (o vazado é o desligado).
      await tester.tap(find.byIcon(Icons.fact_check));
      await tester.pump();

      final cena = _cena(tester);
      expect(cena.modoConferencia, isFalse);
      expect(cena.codigosConferencia, isEmpty);
      expect(cena.contagemConferencia, isEmpty);
      expect(find.textContaining('Conferência do dia'), findsNothing);
    });

    testWidgets('o toggle liga a conferência numa tela aberta sem ela',
        (tester) async {
      await tester.pumpWidget(_pagina(aoAbrir: false));
      await tester.pump();
      expect(_cena(tester).modoConferencia, isFalse);

      await tester.tap(find.byIcon(Icons.fact_check_outlined));
      await tester.pump();

      expect(_cena(tester).modoConferencia, isTrue);
      expect(_cena(tester).codigosConferencia, {'BORAL'});
    });

    testWidgets('dia sem pendente no galpão avisa em vez de deixar o banner '
        'com zeros', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          pilhasIniciais:  _pilhas,
          catalogoInicial: const [],
          conferenciaInicial: ModoConferenciaResultado.vazio,
          conferenciaAoAbrir: true,
        ),
      ));
      await tester.pump();

      expect(find.textContaining('Nenhum pendente com rack no galpão hoje'),
          findsOneWidget);
      expect(_cena(tester).codigosConferencia, isEmpty);
    });
  });

  group('PainelEnderecoGalpao · tarja de pendente', () {
    Widget montar(Set<String> codigos) => MaterialApp(
          home: Scaffold(
            body: PainelEnderecoGalpao(
              toque:              const ToqueGalpao(
                  posicao: 52, ordem: 1, ocupado: true),
              pilhas:             _pilhas,
              codigosConferencia: codigos,
              onFechar:           () {},
            ),
          ),
        );

    testWidgets('rack pendente mostra "Conferir hoje"', (tester) async {
      await tester.pumpWidget(montar({'BORAL'}));
      expect(find.text('Conferir hoje'), findsOneWidget);
    });

    testWidgets('rack sem pendência não mostra a tarja', (tester) async {
      await tester.pumpWidget(montar({'OUTRO_QUALQUER'}));
      expect(find.text('Conferir hoje'), findsNothing);
    });
  });

  group('GalpaoPainter · Modo Conferência', () {
    testWidgets('pinta a cena com badges sem estourar', (tester) async {
      const tela = Size(400, 800);
      final camera = GalpaoScene.enquadrar(tela);
      final recorder = ui.PictureRecorder();
      GalpaoPainter(
        camera,
        pilhas:              _pilhas,
        modoConferencia:     true,
        codigosConferencia:  const {'BORAL'},
        contagemConferencia: const {52: 1},
      ).paint(Canvas(recorder), tela);
      expect(recorder.endRecording(), isNotNull);
    });

    testWidgets('badge de posição inexistente é ignorada', (tester) async {
      const tela = Size(400, 800);
      final camera = GalpaoScene.enquadrar(tela);
      final recorder = ui.PictureRecorder();
      GalpaoPainter(
        camera,
        pilhas:              _pilhas,
        modoConferencia:     true,
        codigosConferencia:  const {'BORAL'},
        // 999 não existe na planta (são 129 posições): não pode desenhar nada
        // nem derrubar o frame.
        contagemConferencia: const {999: 3},
      ).paint(Canvas(recorder), tela);
      expect(recorder.endRecording(), isNotNull);
    });

    test('shouldRepaint reage aos campos da conferência', () {
      final camera = GalpaoScene.enquadrar(const Size(400, 800));
      final base = GalpaoPainter(camera, pilhas: _pilhas);
      final ligado = GalpaoPainter(
        camera,
        pilhas:              _pilhas,
        modoConferencia:     true,
        codigosConferencia:  const {'BORAL'},
        contagemConferencia: const {52: 1},
      );

      expect(ligado.shouldRepaint(base), isTrue);
      expect(base.shouldRepaint(ligado), isTrue);
      // Mesmos valores em instâncias diferentes não repintam por si.
      final igual = GalpaoPainter(
        camera,
        pilhas:              _pilhas,
        modoConferencia:     true,
        codigosConferencia:  const {'BORAL'},
        contagemConferencia: const {52: 1},
      );
      expect(igual.shouldRepaint(ligado), isFalse);
    });
  });
}
