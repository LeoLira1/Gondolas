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
final _campoQuantidade = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == 'Unidades');

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

    testWidgets('endereço ocupado: produto e quantidade em unidades',
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
                produtoNome: 'HERBICIDA BORAL 500 SC 20L', quantidade: 90),
          ],
        },
      ));

      expect(find.text('52 · N2'), findsOneWidget);
      expect(find.text('Rua 5 · 2 de 4 na pilha'), findsOneWidget);
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
      expect(find.text('90 unidades'), findsOneWidget);
      // A quantidade gravada é a que se conta: nada de litros na tela.
      expect(find.text('1800 L'), findsNothing);
    });

    testWidgets('produto sem litragem no nome conta igual a todo o resto',
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

      expect(find.text('35 unidades'), findsOneWidget);
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

      // Seleciona e digita a quantidade: o que se conta é o que se grava e é
      // o que o sistema mostra — uma unidade só, sem conversão no meio.
      await tester.tap(find.text('HERBICIDA BORAL 500 SC 20L'));
      await tester.pump();
      expect(
        tester.widget<TextField>(_campoQuantidade).decoration?.hintText,
        'Unidades',
      );
      await tester.enterText(_campoQuantidade, '90');
      await tester.pump();
      // Não existe mais conversão ao vivo para litros ao lado do campo.
      expect(find.text('= 1800 L'), findsNothing);

      await tester.tap(find.textContaining('Lançar em 1 · N1'));
      await tester.pump();

      // O painel fecha; tocar o mesmo ponto agora acha o rack, não a vaga —
      // inclusive porque a vaga N2 acima dele não pode roubar o toque.
      expect(find.text('1 · N1'), findsNothing);
      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('1 · N1'), findsOneWidget);
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
      expect(find.text('90 unidades'), findsOneWidget);
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
      // toque no chip já preenche a quantidade do último lançamento.
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
      expect(find.text('90 unidades'), findsOneWidget);
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
      expect(find.text('400 unidades'), findsOneWidget);
    });

    testWidgets('posicaoInicial abre isolando a rua e marcando o endereço',
        (tester) async {
      // É por aqui que a busca do mapa da loja entra quando o produto está
      // no galpão.
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          catalogoInicial: const [],
          posicaoInicial: 52,
          pilhasIniciais: {
            52: const [
              RackGalpao(
                  posicao: 52, ordem: 1, produtoCodigo: 'A',
                  produtoNome: 'PRODUTO A 20L', quantidade: 900),
              RackGalpao(
                  posicao: 52, ordem: 2, produtoCodigo: 'B',
                  produtoNome: 'HERBICIDA BORAL 500 SC 20L', quantidade: 1800),
            ],
          },
        ),
      ));
      await tester.pump();

      // Abre no rack do topo da posição pedida…
      expect(find.text('52 · N2'), findsOneWidget);
      expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
      // …com a Rua 5 isolada: a posição 1 (Rua 1) não responde mais ao toque.
      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('1 · N1'), findsNothing);
    });

    testWidgets('posicaoInicial numa vaga vazia marca o chão', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: GalpaoPage(
          catalogoInicial: [],
          pilhasIniciais: {},
          posicaoInicial: 26,
        ),
      ));
      await tester.pump();
      expect(find.text('26 · N1'), findsOneWidget);
      expect(find.textContaining('carga nova entra como N1'), findsOneWidget);
    });

    testWidgets(
        'busca acende TODAS as posições do produto, em ruas diferentes',
        (tester) async {
      // O caso do galpão cheio de herbicida: a busca da loja devolve uma
      // linha por endereço, mas quem abre o mapa quer ver os oito paletes de
      // uma vez. Com o produto em duas ruas, isolar a rua da posição
      // escolhida esconderia metade deles — então o filtro fica em 'Todas'.
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          catalogoInicial: const [],
          posicaoInicial:  68,   // Rua 7
          codigoDestacado: 'ARTYS',
          pilhasIniciais: {
            68: const [
              RackGalpao(
                  posicao: 68, ordem: 1, produtoCodigo: 'ARTYS',
                  produtoNome: 'HERBICIDA ARTYS 20L', quantidade: 900),
            ],
            1: const [   // Rua 1, do outro lado do galpão
              RackGalpao(
                  posicao: 1, ordem: 1, produtoCodigo: 'ARTYS',
                  produtoNome: 'HERBICIDA ARTYS 20L', quantidade: 900),
            ],
          },
        ),
      ));
      await tester.pump();

      // A faixa diz o que está aceso e em quantos lugares.
      expect(find.textContaining('aceso em 2 posições'), findsOneWidget);
      // E o filtro ficou em 'Todas': nenhuma rua foi isolada, então os dois
      // paletes estão na tela ao mesmo tempo.
      expect(_corDoChip(tester, 'Todas'), corCamda);
      expect(_corDoChip(tester, 'R7'), isNot(corCamda));
      // Os chips das duas ruas com o produto ganham o ponto laranja, para
      // quem isolar uma rua depois saber onde estão as outras posições.
      expect(_pontosLaranja(tester), 2);
    });

    testWidgets('produto todo numa rua só continua isolando a rua',
        (tester) async {
      // Sem posição em outra rua não há o que esconder — vale a mira antiga,
      // que é mais fácil de ler.
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          catalogoInicial: const [],
          posicaoInicial:  68,
          codigoDestacado: 'ARTYS',
          pilhasIniciais: {
            68: const [
              RackGalpao(
                  posicao: 68, ordem: 1, produtoCodigo: 'ARTYS',
                  produtoNome: 'HERBICIDA ARTYS 20L', quantidade: 900),
            ],
            70: const [   // também Rua 7
              RackGalpao(
                  posicao: 70, ordem: 1, produtoCodigo: 'ARTYS',
                  produtoNome: 'HERBICIDA ARTYS 20L', quantidade: 900),
            ],
          },
        ),
      ));
      await tester.pump();

      expect(find.textContaining('aceso em 2 posições'), findsOneWidget);
      expect(_corDoChip(tester, 'R7'), corCamda);
      expect(_corDoChip(tester, 'Todas'), isNot(corCamda));
      // Rua 7 é a única com o produto: um ponto laranja só.
      expect(_pontosLaranja(tester), 1);
      // A rua isolada de fato tira as outras da tela.
      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('1 · N1'), findsNothing);
    });

    testWidgets('fechar a faixa apaga o destaque', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          catalogoInicial: const [],
          codigoDestacado: 'ARTYS',
          pilhasIniciais: {
            68: const [
              RackGalpao(
                  posicao: 68, ordem: 1, produtoCodigo: 'ARTYS',
                  produtoNome: 'HERBICIDA ARTYS 20L', quantidade: 900),
            ],
          },
        ),
      ));
      await tester.pump();

      expect(find.textContaining('aceso em 1 posição'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.textContaining('aceso em'), findsNothing);
    });

    testWidgets('painel do rack acende as outras posições do mesmo produto',
        (tester) async {
      // O mesmo destaque, a partir de um rack que a pessoa já achou no mapa —
      // sem ter de voltar à busca da loja.
      await tester.pumpWidget(MaterialApp(
        home: GalpaoPage(
          catalogoInicial: const [],
          pilhasIniciais: {
            1: const [
              RackGalpao(
                  posicao: 1, ordem: 1, produtoCodigo: 'ARTYS',
                  produtoNome: 'HERBICIDA ARTYS 20L', quantidade: 900),
            ],
            68: const [
              RackGalpao(
                  posicao: 68, ordem: 1, produtoCodigo: 'ARTYS',
                  produtoNome: 'HERBICIDA ARTYS 20L', quantidade: 900),
            ],
          },
        ),
      ));
      await tester.pump();

      await tester.tapAt(centroNaTela(tester, 1, 1));
      await tester.pump();
      expect(find.text('Destacar 2 posições deste produto'), findsOneWidget);

      await tester.tap(find.text('Destacar 2 posições deste produto'));
      await tester.pump();
      expect(find.textContaining('aceso em 2 posições'), findsOneWidget);
      expect(find.text('Apagar destaque · 2 posições'), findsOneWidget);
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

/// Cor do texto de um chip da barra de ruas — é como o filtro ativo se
/// anuncia na tela (laranja CAMDA no chip ligado).
Color? _corDoChip(WidgetTester tester, String texto) =>
    tester.widget<Text>(find.text(texto)).style?.color;

/// Quantos chips de rua estão com o ponto laranja do produto destacado.
int _pontosLaranja(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .where((c) {
      final d = c.decoration;
      return d is BoxDecoration &&
          d.shape == BoxShape.circle &&
          d.color == corCamda;
    })
    .length;

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
