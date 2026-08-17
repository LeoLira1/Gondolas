import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/galpao_config.dart';
import 'package:gondola_camda/galpao_page.dart';
import 'package:gondola_camda/galpao_scene.dart';
import 'package:gondola_camda/gondola_scene.dart'
    show Camera, ProjecaoCamera, Vec3;
import 'package:gondola_camda/models.dart' show Produto;

/// Campos do painel, endereçados pelo hint: desde que a barra superior ganhou
/// o campo "ir para o nº", find.byType(TextField) é ambíguo na página.
final _campoBusca =
    find.widgetWithText(TextField, 'Buscar produto por nome ou código…');
final _campoQuantidade = find.byWidgetPredicate((w) =>
    w is TextField &&
    const ['Baldes', 'Caixas', 'Quantidade']
        .contains(w.decoration?.hintText));

void main() {
  group('PainelEnderecoGalpao', () {
    Widget montar(ToqueGalpao toque, Map<int, List<RackGalpao>> pilhas) =>
        MaterialApp(
          home: Scaffold(
            body: PainelEnderecoGalpao(
              toque:    toque,
              pilhas:   pilhas,
              onFechar: () {},
            ),
          ),
        );

    testWidgets('endereço ocupado: produto e quantidade em baldes',
        (tester) async {
      await tester.pumpWidget(montar(
        const ToqueGalpao(posicao: 52, ordem: 2, ocupado: true),
        {
          52: const [
            RackGalpao(
                posicao: 52, ordem: 1, produtoCodigo: 'X',
                produtoNome: 'ADUBO 20L', quantidade: 400),
            RackGalpao(
                posicao: 52, ordem: 2, produtoCodigo: 'BORAL',
                produtoNome: 'HERBICIDA BORAL 500 SC 20L', quantidade: 1800),
          ],
        },
      ));

      expect(find.text('52 · N2'), findsOneWidget);
      expect(find.text('Rua 5 · 2 de 4 na pilha'), findsOneWidget);
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
      expect(find.text('90 baldes'), findsOneWidget);
      expect(find.text('1800 L'), findsOneWidget);
    });

    testWidgets('produto sem litragem no nome mostra o número cru',
        (tester) async {
      await tester.pumpWidget(montar(
        const ToqueGalpao(posicao: 10, ordem: 1, ocupado: true),
        {
          10: const [
            RackGalpao(
                posicao: 10, ordem: 1, produtoCodigo: 'LUVA001',
                produtoNome: 'LUVA NITRILICA PAR', quantidade: 35),
          ],
        },
      ));

      expect(find.text('35'), findsOneWidget);
      // Sem conversão não há texto secundário de litros.
      expect(find.text('35 L'), findsNothing);
    });

    testWidgets('vaga livre anuncia em qual nível a carga entraria',
        (tester) async {
      await tester.pumpWidget(montar(
        const ToqueGalpao(posicao: 37, ordem: 3, ocupado: false),
        {},
      ));

      expect(find.text('37 · N3'), findsOneWidget);
      expect(
        find.textContaining('carga nova entra como N3'),
        findsOneWidget,
      );
    });
  });

  group('GalpaoPage', () {
    /// Centro do rack/vaga [ordem] da posição [numero] em coordenadas de
    /// tela, pela mesma câmera de enquadramento que a cena usa ao abrir.
    Offset centroNaTela(WidgetTester tester, int numero, int ordem) {
      final tela = tester.getSize(find.byType(GalpaoScene));
      final camera = GalpaoScene.enquadrar(tela);
      final p = GalpaoConfig.porNumero(numero)!;
      final y =
          (GalpaoConfig.yBase(ordem) + GalpaoConfig.yTopo(ordem)) / 2;
      return _projetar(camera, tela, Vec3(p.x, y, p.z))!;
    }

    /// Centro da face FRONTAL (voltada para a câmera, +Z) do rack — é onde se
    /// toca para selecionar um rack que tem outro em cima.
    Offset frenteNaTela(WidgetTester tester, int numero, int ordem) {
      final tela = tester.getSize(find.byType(GalpaoScene));
      final camera = GalpaoScene.enquadrar(tela);
      final p = GalpaoConfig.porNumero(numero)!;
      final y =
          (GalpaoConfig.yBase(ordem) + GalpaoConfig.yTopo(ordem)) / 2;
      return _projetar(camera, tela, Vec3(p.x, y, p.z + p.tamanhoZ / 2))!;
    }

    testWidgets('tocar numa vaga abre o painel; fechar o painel o remove',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: GalpaoPage(catalogoInicial: [])));

      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();

      expect(find.text('1 · N1'), findsOneWidget);
      expect(find.textContaining('carga nova entra como N1'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text('1 · N1'), findsNothing);
    });

    testWidgets('fluxo completo de lançar: busca, quantidade, topo da pilha',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: GalpaoPage(catalogoInicial: _catalogoTeste)));

      // Vaga 1 · N1 → busca por parte do nome.
      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      await tester.enterText(_campoBusca, 'boral');
      await tester.pump();
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);

      // Seleciona e digita a quantidade NA UNIDADE QUE SE CONTA: quem foi ao
      // galpão viu 90 baldes, então digita 90 — os litros são derivados.
      await tester.tap(find.text('HERBICIDA BORAL 500 SC 20L'));
      await tester.pump();
      // O campo pede BALDES (a unidade do produto de 20 L), não litros.
      expect(
        tester.widget<TextField>(_campoQuantidade).decoration?.hintText,
        'Baldes',
      );
      await tester.enterText(_campoQuantidade, '90');
      await tester.pump();
      expect(find.text('= 1800 L'), findsOneWidget);

      await tester.tap(find.textContaining('Lançar em 1 · N1'));
      await tester.pump();

      // O painel fecha; tocar o mesmo ponto agora acha o rack, não a vaga —
      // inclusive porque a vaga N2 acima dele não pode roubar o toque.
      expect(find.text('1 · N1'), findsNothing);
      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('1 · N1'), findsOneWidget);
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
      expect(find.text('90 baldes'), findsOneWidget);
      expect(find.text('Esvaziar'), findsOneWidget);
    });

    testWidgets('últimos lançados aparecem como atalho com a quantidade',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: GalpaoPage(catalogoInicial: _catalogoTeste)));

      // Primeiro lançamento, pelo caminho longo.
      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      await tester.enterText(_campoBusca, 'boral');
      await tester.pump();
      await tester.tap(find.text('HERBICIDA BORAL 500 SC 20L'));
      await tester.pump();
      await tester.enterText(_campoQuantidade, '90');
      await tester.pump();
      await tester.tap(find.textContaining('Lançar em 1 · N1'));
      await tester.pump();

      // Próxima vaga: o produto está nos recentes, sem digitar nada, e o
      // toque no chip já preenche a quantidade do último lançamento — de
      // volta em BALDES, não nos litros que foram gravados.
      await tester.tapAt(centroNaTela(tester, 2, 1));
      await tester.pump();
      expect(find.text('ÚLTIMOS LANÇADOS'), findsOneWidget);
      await tester.tap(find.text('HERBICIDA BORAL 500 SC 20L'));
      await tester.pump();
      expect(find.widgetWithText(TextField, '90'), findsOneWidget);

      await tester.tap(find.textContaining('Lançar em 2 · N1'));
      await tester.pump();
      await tester.tapAt(centroNaTela(tester, 2, 1));
      await tester.pump();
      expect(find.text('90 baldes'), findsOneWidget);
    });

    testWidgets('esvaziar a base: o de cima desce, vira N1 e anima',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          catalogoInicial: _catalogoTeste,
          pilhasIniciais: {
            1: const [
              RackGalpao(
                  posicao: 1, ordem: 1, produtoCodigo: 'A',
                  produtoNome: 'PRODUTO DE BAIXO', quantidade: 100),
              RackGalpao(
                  posicao: 1, ordem: 2, produtoCodigo: 'B',
                  produtoNome: 'PRODUTO DE CIMA', quantidade: 200),
            ],
          },
        ),
      ));

      // A face frontal seleciona o rack de BAIXO mesmo com outro em cima.
      await tester.tapAt(frenteNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('1 · N1'), findsOneWidget);
      expect(find.text('PRODUTO DE BAIXO'), findsOneWidget);

      await tester.tap(find.text('Esvaziar'));
      await tester.pump();
      // Confirmação avisa da renumeração.
      expect(find.textContaining('descem um nível'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Esvaziar'));
      await tester.pump();

      // A descida anima (250 ms) e termina sem exceção.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Quem era N2 agora É N1 — a regra física do galpão, de ponta a ponta.
      await tester.tapAt(frenteNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('1 · N1'), findsOneWidget);
      expect(find.text('PRODUTO DE CIMA'), findsOneWidget);
    });

    testWidgets('painel do rack do topo tem o atalho para a vaga de cima',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          catalogoInicial: _catalogoTeste,
          pilhasIniciais: {
            1: const [
              RackGalpao(
                  posicao: 1, ordem: 1, produtoCodigo: 'A',
                  produtoNome: 'PRODUTO A', quantidade: 100),
            ],
          },
        ),
      ));

      // O topo da pilha responde ao toque como rack (prioridade sobre a
      // vaga), e o painel dá o caminho para lançar na vaga de cima.
      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('PRODUTO A'), findsOneWidget);

      await tester.tap(find.text('Lançar N2'));
      await tester.pump();
      expect(find.text('1 · N2'), findsOneWidget);
      expect(find.textContaining('carga nova entra como N2'), findsOneWidget);
    });
  });

  group('filtro por rua e ir para o número', () {
    /// Centro do rack/vaga [ordem] da posição [numero] em coordenadas de
    /// tela. Duplicado do grupo acima de propósito: um helper compartilhado
    /// entre grupos esconderia qual câmera cada teste assume.
    Offset centroNaTela(WidgetTester tester, int numero, int ordem) {
      final tela = tester.getSize(find.byType(GalpaoScene));
      final camera = GalpaoScene.enquadrar(tela);
      final p = GalpaoConfig.porNumero(numero)!;
      final y =
          (GalpaoConfig.yBase(ordem) + GalpaoConfig.yTopo(ordem)) / 2;
      return _projetar(camera, tela, Vec3(p.x, y, p.z))!;
    }

    testWidgets('isolar uma rua tira as OUTRAS da lista de alvos do toque',
        (tester) async {
      // O cuidado crítico do enunciado: parar de desenhar não basta. Se o
      // hit-test varresse a grade inteira, o toque no ponto da posição 1
      // (Rua 1, escondida) selecionaria a posição 1 mesmo com R3 isolada.
      await tester.pumpWidget(const MaterialApp(
          home: GalpaoPage(catalogoInicial: [])));

      final pontoDaRua1 = centroNaTela(tester, 1, 1);

      // Sem filtro, esse ponto seleciona a posição 1.
      await tester.tapAt(pontoDaRua1);
      await tester.pump();
      expect(find.text('1 · N1'), findsOneWidget);

      // Isola a Rua 3: a seleção da rua escondida se desfaz…
      await tester.tap(find.text('R3'));
      await tester.pump();
      expect(find.text('1 · N1'), findsNothing);

      // …e o mesmo toque não acha mais nada da Rua 1.
      await tester.tapAt(pontoDaRua1);
      await tester.pump();
      expect(find.text('1 · N1'), findsNothing);
      expect(find.textContaining(' · N'), findsNothing);
    });

    testWidgets('a rua isolada continua respondendo ao toque', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: GalpaoPage(catalogoInicial: [])));

      await tester.tap(find.text('R3'));
      await tester.pump();

      // 26 é a primeira posição da Rua 3.
      await tester.tapAt(centroNaTela(tester, 26, 1));
      await tester.pump();
      expect(find.text('26 · N1'), findsOneWidget);
      expect(find.text('Rua 3 · 0 de 4 na pilha'), findsOneWidget);
    });

    testWidgets('Todas devolve os alvos escondidos', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: GalpaoPage(catalogoInicial: [])));
      final pontoDaRua1 = centroNaTela(tester, 1, 1);

      await tester.tap(find.text('R3'));
      await tester.pump();
      await tester.tap(find.text('Todas'));
      await tester.pump();

      await tester.tapAt(pontoDaRua1);
      await tester.pump();
      expect(find.text('1 · N1'), findsOneWidget);
    });

    testWidgets('ir para o número isola a rua e marca a posição',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: GalpaoPage(catalogoInicial: [])));

      await tester.enterText(find.widgetWithText(TextField, 'nº'), '52');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();

      // 52 é da Rua 5: o painel abre no endereço e a rua fica isolada.
      expect(find.text('52 · N1'), findsOneWidget);
      expect(find.text('Rua 5 · 0 de 4 na pilha'), findsOneWidget);

      // Prova de que isolou: o ponto da posição 1 (Rua 1) não responde.
      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('1 · N1'), findsNothing);
    });

    testWidgets('ir para o topo da pilha quando a posição está ocupada',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          catalogoInicial: const [],
          pilhasIniciais: {
            52: const [
              RackGalpao(
                  posicao: 52, ordem: 1, produtoCodigo: 'A',
                  produtoNome: 'PRODUTO A 20L', quantidade: 900),
              RackGalpao(
                  posicao: 52, ordem: 2, produtoCodigo: 'B',
                  produtoNome: 'PRODUTO B 20L', quantidade: 400),
            ],
          },
        ),
      ));

      await tester.enterText(find.widgetWithText(TextField, 'nº'), '52');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();

      expect(find.text('52 · N2'), findsOneWidget);
      expect(find.text('PRODUTO B 20L'), findsOneWidget);
      expect(find.text('20 baldes'), findsOneWidget);
    });

    testWidgets('número fora de 1–78 avisa e não muda nada', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: GalpaoPage(catalogoInicial: [])));

      await tester.enterText(find.widgetWithText(TextField, 'nº'), '99');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();

      expect(find.textContaining('não existe'), findsOneWidget);
      expect(find.textContaining(' · N'), findsNothing);
      // Nenhuma rua foi isolada: 'Todas' continua valendo.
      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('1 · N1'), findsOneWidget);
    });
  });
}

const _catalogoTeste = [
  Produto(
      codigo: 'HB500', nome: 'HERBICIDA BORAL 500 SC 20L',
      categoria: 'Defensivos', corHex: '#8b1a1a'),
  Produto(
      codigo: 'LB001', nome: 'OLEO LUBRAX ESSENCIAL 20L',
      categoria: 'Lubrificantes', corHex: '#2e7d4f'),
];

Offset? _projetar(Camera camera, Size size, Vec3 v) {
  final olho   = camera.position;
  final fwd    = (camera.target - olho).normalized;
  final right  = fwd.cross(const Vec3(0, 1, 0)).normalized;
  final up     = right.cross(fwd).normalized;
  final tanH   = math.tan(ProjecaoCamera.fovY / 2);
  final aspect = size.width / size.height;

  final d  = v - olho;
  final cz = d.dot(fwd);
  if (cz <= ProjecaoCamera.near) return null;
  final cx = d.dot(right) / (cz * tanH * aspect);
  final cy = d.dot(up) / (cz * tanH);
  return Offset((cx + 1) / 2 * size.width, (1 - cy) / 2 * size.height);
}
