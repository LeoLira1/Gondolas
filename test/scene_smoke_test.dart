import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/gondola_scene.dart';
import 'package:gondola_camda/estante_parede_scene.dart';
import 'package:gondola_camda/expositor_magnojet_scene.dart';
import 'package:gondola_camda/expositor_monitor_scene.dart';
import 'package:gondola_camda/expositor_nellore_scene.dart';
import 'package:gondola_camda/loja_scene.dart';
import 'package:gondola_camda/models.dart';

void main() {
  test('faceAngle segue a convenção: face 1 = +90° (entrada), horária', () {
    expect(faceAngle(1), closeTo(math.pi / 2, 1e-9));
    expect(faceAngle(2), closeTo(math.pi / 6, 1e-9));
    expect(faceAngle(4), closeTo(-math.pi / 2, 1e-9));
  });

  test('sectorToFace concorda com faceFromPos no centro de cada setor', () {
    for (var i = 0; i < 6; i++) {
      final a = (30 + i * 60) * math.pi / 180;
      expect(faceFromPos(2 * math.cos(a), 2 * math.sin(a)), sectorToFace(i));
    }
  });

  test('faceFromPos: +Z é a face 1 (entrada), -Z é a face 4 (fundo)', () {
    expect(faceFromPos(0, 3), 1);
    expect(faceFromPos(0, -3), 4);
  });

  test('clampAoAndar traz caixas do octógono antigo para dentro do hexágono', () {
    // Ponto no meio de uma borda do octógono antigo (0.924·r), fora do
    // apótema do hexágono (0.866·r).
    final ang = math.pi / 6;
    final fora = (x: 3.14 * math.cos(ang), z: 3.14 * math.sin(ang));
    final c = GondolaGeometry.clampAoAndar(0, fora.x, fora.z);
    final proj = c.x * math.cos(ang) + c.z * math.sin(ang);
    expect(proj, lessThanOrEqualTo(3.4 * math.cos(math.pi / 6) - 0.2 + 1e-9));
    // A face derivada não muda com o clamp.
    expect(faceFromPos(c.x, c.z), faceFromPos(fora.x, fora.z));
    // Ponto interno permanece intacto.
    final dentro = GondolaGeometry.clampAoAndar(0, 1.0, -1.5);
    expect(dentro.x, 1.0);
    expect(dentro.z, -1.5);
  });

  test('geometria da gôndola é hexagonal (6 pés, prismas de 6 lados)', () {
    final faces = GondolaGeometry.buildFaces();
    // 6 pés + 2 colunas = 8 prismas de coluna; 3 andares × 2 prismas = 6.
    // Cada prisma de 6 lados = 6 laterais + 1 tampa = 7 faces.
    expect(faces.length, (6 + 2 + 6) * 7);
  });

  test('face selecionada recebe tint laranja nos 3 andares', () {
    final semSel = GondolaGeometry.buildFaces();
    final comSel = GondolaGeometry.buildFaces(faceSelecionada: 3);
    final mudadas = <int>[];
    for (var i = 0; i < semSel.length; i++) {
      if (semSel[i].color != comSel[i].color) mudadas.add(i);
    }
    // 1 setor × 2 prismas (corpo + borda) × 3 andares = 6 faces laterais.
    expect(mudadas.length, 6);
  });

  testWidgets('GondolaScene renderiza com face selecionada e labels',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: GondolaScene(
        gondolaAtual: 9,
        faceSelecionada: 3,
        faceParaCamera: 3,
        caixas: [
          CaixaColocada(andar: 0, produtoId: 'p1', x: 2.9, z: 1.6),
          CaixaColocada(andar: 2, produtoId: 'p2', x: 0.2, z: -0.4),
        ],
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('LojaScene renderiza labels de face e referências no chão',
      (tester) async {
    final idxGondola9 =
        itensLoja.indexWhere((it) => it.tipo == 'gondola' && it.numero == 9);
    await tester.pumpWidget(MaterialApp(
      home: LojaScene(
        selecionadoIdx: idxGondola9,
        onSelecionado: (_) {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    // Descarta a cena para encerrar o ticker antes do fim do teste.
    await tester.pumpWidget(const SizedBox());
  });

  test('expositor MagnoJet: grade de ganchos + espaços da base', () {
    const geo = ExpositorMagnojetGeometry();
    expect(geo.cells.length, geo.colunas * geo.linhas + colunasBaseMagnojet);
    // Ganchos não colidem: passo vertical maior que a altura da sacolinha.
    final passoY = geo.linhaY(1) - geo.linhaY(0);
    expect(passoY, greaterThan(ExpositorMagnojetGeometry.hPacote));
    // Espaços da base: linha extra após os ganchos, marcados como base.
    final base = geo.cells.where((c) => c.ehBase).toList();
    expect(base.length, colunasBaseMagnojet);
    expect(base.every((c) => c.linha == geo.linhaBase), isTrue);
  });

  test('expositor MagnoJet: letras seguem a convenção (A = topo-esquerda)', () {
    // Linha do topo (nivel = linhas-1), coluna 0 → 'A'
    expect(
      letraEstanteCelula(expositorMagnojetNum, 0, linhasExpositorMagnojet - 1),
      'A',
    );
    // Linha de baixo, última coluna → última letra da grade
    expect(
      letraEstanteCelula(
          expositorMagnojetNum, colunasExpositorMagnojet - 1, 0),
      letraDoIndice(
          colunasExpositorMagnojet * linhasExpositorMagnojet - 1),
    );
    // Base: números 1–5, sem deslocar as letras dos ganchos.
    expect(letraEstanteCelula(expositorMagnojetNum, 0, nivelBaseMagnojet), '1');
    expect(
      letraEstanteCelula(
          expositorMagnojetNum, colunasBaseMagnojet - 1, nivelBaseMagnojet),
      '5',
    );
    expect(niveisProdutoPara(expositorMagnojetNum), linhasExpositorMagnojet + 1);
    expect(numColunasPara(expositorMagnojetNum), colunasBaseMagnojet);
  });

  test('expositor Nellore: 24 endereços nos níveis 1–5, sem base', () {
    const geo = ExpositorNelloreGeometry();
    // 5+5 (prateleiras) + 4 (cestos) + 5+5 (ganchos) = 24 — a base (nível 0)
    // saiu dos endereços: a estante real não tem essa prateleira.
    expect(geo.cells.length, 24);
    expect(geo.cells.any((c) => c.nivel == 0), isFalse);
    expect(colunasNivelNellore(1), 5);
    expect(colunasNivelNellore(2), 5);
    expect(colunasNivelNellore(3), 4);
    expect(colunasNivelNellore(4), 5);
    expect(colunasNivelNellore(5), 5);
    // Tipos por nível: 2 prateleiras, cestos, 2 fileiras de ganchos.
    expect(ExpositorNelloreGeometry.tipoDoNivel(1), NelloreTipoNivel.prateleira);
    expect(ExpositorNelloreGeometry.tipoDoNivel(2), NelloreTipoNivel.prateleira);
    expect(ExpositorNelloreGeometry.tipoDoNivel(3), NelloreTipoNivel.cesto);
    expect(ExpositorNelloreGeometry.tipoDoNivel(4), NelloreTipoNivel.gancho);
    expect(ExpositorNelloreGeometry.tipoDoNivel(5), NelloreTipoNivel.gancho);
    // Fileiras de gancho não colidem: passo maior que a altura do pacote.
    expect(geo.nivelY(5) - geo.nivelY(4),
        greaterThan(ExpositorNelloreGeometry.hPacote));
  });

  test('expositor Nellore: letras A–E a T–X inalteradas sem a base', () {
    // Letras contínuas de cima pra baixo: ganchos A–E e F–J, cestos K–N,
    // prateleiras O–S e T–X — mesmos endereços de antes da base sair.
    expect(letraEstanteCelula(expositorNelloreNum, 0, 5), 'A');
    expect(letraEstanteCelula(expositorNelloreNum, 4, 5), 'E');
    expect(letraEstanteCelula(expositorNelloreNum, 0, 4), 'F');
    expect(letraEstanteCelula(expositorNelloreNum, 4, 4), 'J');
    expect(letraEstanteCelula(expositorNelloreNum, 0, 3), 'K');
    expect(letraEstanteCelula(expositorNelloreNum, 3, 3), 'N');
    expect(letraEstanteCelula(expositorNelloreNum, 0, 2), 'O');
    expect(letraEstanteCelula(expositorNelloreNum, 4, 2), 'S');
    expect(letraEstanteCelula(expositorNelloreNum, 0, 1), 'T');
    expect(letraEstanteCelula(expositorNelloreNum, 4, 1), 'X');
  });

  test('expositor Monitor: 20 endereços em 4 níveis × 5 colunas', () {
    const geo = ExpositorMonitorGeometry();
    expect(geo.cells.length,
        ExpositorMonitorGeometry.niveis * ExpositorMonitorGeometry.colunas);
    expect(niveisProdutoPara(expositorMonitorNum), 4);
    expect(numColunasPara(expositorMonitorNum), 5);
    // Profundidade crescente de cima pra baixo: a base é a mais funda.
    expect(geo.zFrenteNivel(0), greaterThan(geo.zFrenteNivel(1)));
    expect(geo.zFrenteNivel(1), greaterThan(geo.zFrenteNivel(2)));
    expect(geo.zFrenteNivel(2), greaterThan(geo.zFrenteNivel(3)));
    // Fileiras de produto acompanham a profundidade do nível.
    expect(geo.fileirasNivel(0), 3);
    expect(geo.fileirasNivel(1), 2);
    expect(geo.fileirasNivel(2), 2);
    expect(geo.fileirasNivel(3), 1);
  });

  test('expositor Monitor: base numerada 1–5 e letras A–E a K–O nos demais', () {
    // Nível 0 (base/deck) usa números por coluna, sem letra.
    expect(letraEstanteCelula(expositorMonitorNum, 0, 0), '1');
    expect(letraEstanteCelula(expositorMonitorNum, 4, 0), '5');
    // Letras contínuas de cima pra baixo: superior A–E, média F–J,
    // inferior K–O.
    expect(letraEstanteCelula(expositorMonitorNum, 0, 3), 'A');
    expect(letraEstanteCelula(expositorMonitorNum, 4, 3), 'E');
    expect(letraEstanteCelula(expositorMonitorNum, 0, 2), 'F');
    expect(letraEstanteCelula(expositorMonitorNum, 4, 2), 'J');
    expect(letraEstanteCelula(expositorMonitorNum, 0, 1), 'K');
    expect(letraEstanteCelula(expositorMonitorNum, 4, 1), 'O');
  });

  test('estante parede: grade 2×6 e números contínuos entre as 6 seções', () {
    expect(EstanteParedeGeometry.celulas().length,
        colunasParede * niveisProdutoParede);

    // Endereços numéricos, de cima pra baixo dentro da coluna, coluna
    // esquerda antes da direita: E13 col 0 = 1..6, col 1 = 7..12.
    expect(letraEstanteCelula(13, 0, 5), '1');
    expect(letraEstanteCelula(13, 0, 0), '6');
    expect(letraEstanteCelula(13, 1, 5), '7');
    expect(letraEstanteCelula(13, 1, 0), '12');
    // Cada seção continua de onde a anterior parou, até 72 na E18.
    expect(letraEstanteCelula(14, 0, 5), '13');
    expect(letraEstanteCelula(15, 0, 5), '25');
    expect(letraEstanteCelula(16, 0, 5), '37');
    expect(letraEstanteCelula(17, 0, 5), '49');
    expect(letraEstanteCelula(18, 0, 5), '61');
    expect(letraEstanteCelula(18, 1, 0), '72');
  });

  test('estante parede: posição global P1–P12 derivada de seção + coluna', () {
    expect(posicaoGlobalParede(13, 0), 1);
    expect(posicaoGlobalParede(13, 1), 2);
    expect(posicaoGlobalParede(15, 1), 6);
    expect(posicaoGlobalParede(18, 1), 12);
  });

  test('estantes 3 e 4 continuam com as letras de sempre (A–O / P–AD)', () {
    expect(letraEstanteCelula(3, 0, 4), 'A');
    expect(letraEstanteCelula(3, 2, 0), 'O');
    expect(letraEstanteCelula(4, 0, 4), 'P');
    expect(letraEstanteCelula(4, 2, 0), 'AD');
  });

  test('ordem de navegação: parede no lugar das estantes 3 e 4', () {
    expect(ordemNavegacaoEstantes.contains(3), isFalse);
    expect(ordemNavegacaoEstantes.contains(4), isFalse);
    // Removidas ficam fora da navegação e nunca colidem com a parede.
    expect(ordemNavegacaoEstantes.toSet().intersection(estantesRemovidas),
        isEmpty);
    expect(estantesRemovidas.intersection(estantesParede), isEmpty);
    expect(ordemNavegacaoEstantes.sublist(2, 8), [13, 14, 15, 16, 17, 18]);
    // Mapa: as 6 seções apontam para o retângulo único (numero 13).
    expect(numeroNoMapaLoja('estante', 16), estanteParedeMin);
    expect(numeroNoMapaLoja('estante', 8), 8);
    expect(numeroNoMapaLoja('gondola', 13), 13);
    expect(
      itensLoja.any((it) => it.tipo == 'estante' && it.numero == estanteParedeMin),
      isTrue,
    );
    expect(itensLoja.any((it) => it.tipo == 'estante' && it.numero == 3), isFalse);
    expect(itensLoja.any((it) => it.tipo == 'estante' && it.numero == 4), isFalse);
  });

  testWidgets('EstanteParedeScene renderiza sem exceções', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: EstanteParedeScene(
        estanteAtual: 15,
        caixas: [
          CaixaColocadaEstante(coluna: 0, nivel: 0, slot: 0, produtoId: 'W1'),
          CaixaColocadaEstante(coluna: 1, nivel: 5, slot: 2, produtoId: 'W2'),
        ],
        corPorProduto: {'W1': Colors.green, 'W2': Colors.amber},
        destacadoCodigo: 'W2',
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ExpositorMagnojetScene renderiza sem exceções', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ExpositorMagnojetScene(
        geometry:   ExpositorMagnojetGeometry(showFloor: false),
        autoRotate: false,
        caixas: [
          CaixaColocadaEstante(coluna: 0, nivel: 5, slot: 0, produtoId: 'X1'),
          CaixaColocadaEstante(coluna: 3, nivel: 0, slot: 0, produtoId: 'X2'),
        ],
        corPorProduto: {'X1': Colors.green, 'X2': Colors.amber},
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ExpositorNelloreScene renderiza sem exceções', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ExpositorNelloreScene(
        geometry:   ExpositorNelloreGeometry(showFloor: false),
        autoRotate: false,
        caixas: [
          // Um produto de cada tipo de nível: gancho, cesto, prateleira, base.
          CaixaColocadaEstante(coluna: 4, nivel: 5, slot: 0, produtoId: 'N1'),
          CaixaColocadaEstante(coluna: 1, nivel: 3, slot: 0, produtoId: 'N2'),
          CaixaColocadaEstante(coluna: 2, nivel: 1, slot: 0, produtoId: 'N3'),
          CaixaColocadaEstante(coluna: 3, nivel: 0, slot: 0, produtoId: 'N4'),
        ],
        corPorProduto: {
          'N1': Colors.green,
          'N2': Colors.amber,
          'N3': Colors.blue,
          'N4': Colors.red,
        },
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ExpositorMonitorScene renderiza sem exceções', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ExpositorMonitorScene(
        geometry:   ExpositorMonitorGeometry(showFloor: false),
        autoRotate: false,
        caixas: [
          // Um produto em cada nível: base, prateleiras inferior/média/superior.
          CaixaColocadaEstante(coluna: 0, nivel: 0, slot: 0, produtoId: 'M1'),
          CaixaColocadaEstante(coluna: 2, nivel: 1, slot: 0, produtoId: 'M2'),
          CaixaColocadaEstante(coluna: 3, nivel: 2, slot: 0, produtoId: 'M3'),
          CaixaColocadaEstante(coluna: 4, nivel: 3, slot: 0, produtoId: 'M4'),
        ],
        corPorProduto: {
          'M1': Colors.green,
          'M2': Colors.amber,
          'M3': Colors.blue,
          'M4': Colors.red,
        },
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('GondolaScene pinta de vermelho a caixa com divergência',
      (tester) async {
    // Endereço divergente marcado via chaveEnderecoEstoque (mesmo formato do
    // service). A caixa correspondente deve ficar vermelha em vez da cor do
    // produto, sem badge de canto.
    final chave = chaveEnderecoEstoque(
      produtoCodigo: 'p1',
      localTipo:     'gondola',
      localNum:      9,
      faceOuColuna:  faceFromPos(2.9, 1.6),
      andarOuNivel:  0,
    );
    await tester.pumpWidget(MaterialApp(
      home: GondolaScene(
        gondolaAtual: 9,
        caixas: const [
          CaixaColocada(andar: 0, produtoId: 'p1', x: 2.9, z: 1.6),
        ],
        corPorProduto: const {'p1': Color(0xFF3366cc)},
        divergentes: {chave},
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);

    final painter = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(GondolaScene),
        matching: find.byType(CustomPaint),
      ),
    ).painter as GondolaPainter;
    // A caixa vermelha aparece entre as faces extras da cena.
    expect(
      painter.extraFaces.any((f) => f.color == corEnderecoDivergente),
      isTrue,
    );
  });

  testWidgets('GondolaScene pinta de azul escuro a divergência positiva',
      (tester) async {
    // Endereço com divergência positiva (contado maior que o sistema): a
    // caixa fica azul escuro em vez de vermelho.
    final chave = chaveEnderecoEstoque(
      produtoCodigo: 'p1',
      localTipo:     'gondola',
      localNum:      9,
      faceOuColuna:  faceFromPos(2.9, 1.6),
      andarOuNivel:  0,
    );
    await tester.pumpWidget(MaterialApp(
      home: GondolaScene(
        gondolaAtual: 9,
        caixas: const [
          CaixaColocada(andar: 0, produtoId: 'p1', x: 2.9, z: 1.6),
        ],
        corPorProduto: const {'p1': Color(0xFF3366cc)},
        divergentes: {chave},
        divergentesPositivas: {chave},
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);

    final painter = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(GondolaScene),
        matching: find.byType(CustomPaint),
      ),
    ).painter as GondolaPainter;
    // A caixa azul escuro aparece; nenhuma face vermelha de divergência.
    expect(
      painter.extraFaces.any((f) => f.color == corEnderecoDivergentePositiva),
      isTrue,
    );
    expect(
      painter.extraFaces.any((f) => f.color == corEnderecoDivergente),
      isFalse,
    );
  });
}
