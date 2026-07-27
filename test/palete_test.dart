import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/loja_scene.dart';
import 'package:gondola_camda/models.dart';
import 'package:gondola_camda/palete_registry.dart';
import 'package:gondola_camda/palete_scene.dart';

/// O PaleteRegistry é singleton (como o TursoService), então cada teste que
/// mexe no catálogo precisa zerá-lo — senão o estado vaza de um teste pro
/// outro e ordemNavegacaoEstantes muda embaixo dos que só leem constantes.
void _zerarRegistry() {
  PaleteRegistry()
    ..modoMemoria = true
    ..substituirEmMemoria(const []);
}

void main() {
  setUp(_zerarRegistry);
  tearDown(() {
    PaleteRegistry()
      ..substituirEmMemoria(const [])
      ..modoMemoria = false;
  });

  // ── Faixa reservada ────────────────────────────────────────────────────────

  test('ehPalete: 100 é estante/expositor, 101 já é palete', () {
    expect(ehPalete(100), isFalse);
    expect(ehPalete(paleteNumMin), isTrue);
    expect(ehPalete(paleteNumMin + 500), isTrue);
  });

  test('a faixa dos paletes não colide com nenhum móvel existente', () {
    for (final n in ordemNavegacaoBase) {
      expect(ehPalete(n), isFalse, reason: 'estante/expositor $n virou palete');
    }
    for (final n in estantesRemovidas) {
      expect(ehPalete(n), isFalse);
    }
  });

  // ── Grade ──────────────────────────────────────────────────────────────────

  test('grade do palete: 5 colunas × 3 fileiras', () {
    expect(numColunasPara(paleteNumMin), colunasPalete);
    expect(numColunasPara(paleteNumMin), 5);
    expect(niveisProdutoPara(paleteNumMin), fileirasPalete);
    expect(niveisProdutoPara(paleteNumMin), 3);
  });

  test('rótulos 1–15 contam da fileira do corredor para o fundo', () {
    // Frente (fileira 0) = 1–5, meio = 6–10, fundo = 11–15 — igual à
    // etiqueta física no chão.
    expect(letraEstanteCelula(paleteNumMin, 0, 0), '1');
    expect(letraEstanteCelula(paleteNumMin, 4, 0), '5');
    expect(letraEstanteCelula(paleteNumMin, 0, 1), '6');
    expect(letraEstanteCelula(paleteNumMin, 4, 1), '10');
    expect(letraEstanteCelula(paleteNumMin, 0, 2), '11');
    expect(letraEstanteCelula(paleteNumMin, 4, 2), '15');
  });

  test('as 15 posições geram rótulos 1–15 sem repetir nem faltar', () {
    final rotulos = <String>[];
    for (var fil = 0; fil < fileirasPalete; fil++) {
      for (var col = 0; col < colunasPalete; col++) {
        rotulos.add(letraEstanteCelula(paleteNumMin, col, fil));
      }
    }
    expect(rotulos.toSet().length, 15);
    expect(rotulos.map(int.parse).toList()..sort(),
        List.generate(15, (i) => i + 1));
  });

  test('o rótulo não depende do número do palete', () {
    // Todo palete tem a mesma grade, então a etiqueta da posição é a mesma
    // no 101 e no 137 — é o número do palete que os distingue.
    expect(letraEstanteCelula(paleteNumMin, 2, 1),
        letraEstanteCelula(paleteNumMin + 36, 2, 1));
  });

  // ── Alocação de número ─────────────────────────────────────────────────────

  test('números começam em paleteNumMin e sobem de um em um', () async {
    final reg = PaleteRegistry();
    expect(await reg.criar(apelido: 'A'), paleteNumMin);
    expect(await reg.criar(apelido: 'B'), paleteNumMin + 1);
    expect(await reg.criar(apelido: 'C'), paleteNumMin + 2);
  });

  test('número de palete desativado NUNCA é reciclado', () async {
    final reg = PaleteRegistry();
    expect(await reg.criar(apelido: 'A'), 101);
    expect(await reg.criar(apelido: 'B'), 102);

    expect(await reg.desativar(102), isTrue);

    // O 102 sai dos ativos mas continua na tabela — é a linha dele que segura
    // o MAX(num) e impede que o número volte. Se voltasse, o palete novo
    // herdaria os endereços velhos do 102 em estoque_localizado.
    expect(reg.ativos.map((p) => p.num), [101]);
    expect(reg.byNum(102), isNotNull);
    expect(reg.byNum(102)!.ativo, isFalse);

    expect(await reg.criar(apelido: 'C'), 103);
  });

  test('desativar o último não libera o número nem para o seguinte', () async {
    final reg = PaleteRegistry();
    await reg.criar(apelido: 'A');   // 101
    await reg.desativar(101);
    expect(reg.ativos, isEmpty);
    // Tabela vazia de ATIVOS não é tabela vazia: o próximo é 102, não 101.
    expect(await reg.criar(apelido: 'B'), 102);
  });

  test('atualizar troca o apelido e preserva o número', () async {
    final reg = PaleteRegistry();
    final num = (await reg.criar(apelido: 'antigo'))!;
    expect(await reg.atualizar(reg.byNum(num)!.copyWith(apelido: 'novo')),
        isTrue);
    expect(reg.byNum(num)!.apelido, 'novo');
    expect(reg.ativos.single.num, num);
  });

  test('byNum devolve null para número nunca cadastrado', () {
    expect(PaleteRegistry().byNum(999), isNull);
  });

  // ── Carrossel ──────────────────────────────────────────────────────────────

  test('sem palete cadastrado o carrossel é só a base fixa', () {
    expect(ordemNavegacaoEstantes, ordemNavegacaoBase);
  });

  test('carrossel cresce com os ativos e ignora os inativos', () async {
    final reg = PaleteRegistry();
    await reg.criar(apelido: 'A');   // 101
    await reg.criar(apelido: 'B');   // 102
    await reg.criar(apelido: 'C');   // 103

    expect(ordemNavegacaoEstantes.length, ordemNavegacaoBase.length + 3);

    await reg.desativar(102);

    final ordem = ordemNavegacaoEstantes;
    expect(ordem.length, ordemNavegacaoBase.length + 2);
    expect(ordem.contains(102), isFalse);
    // Paletes entram no FIM, depois dos expositores 19 e 20, e em ordem de
    // número.
    expect(ordem.sublist(0, ordemNavegacaoBase.length), ordemNavegacaoBase);
    expect(ordem.sublist(ordemNavegacaoBase.length), [101, 103]);
  });

  test('a base fixa do carrossel continua intocada pelos paletes', () async {
    await PaleteRegistry().criar(apelido: 'A');
    expect(ordemNavegacaoEstantes.contains(3), isFalse);
    expect(ordemNavegacaoEstantes.contains(4), isFalse);
    expect(ordemNavegacaoEstantes.sublist(2, 8), [13, 14, 15, 16, 17, 18]);
  });

  // ── Fora do mapa geral ─────────────────────────────────────────────────────

  test('paletes e estante 5 são navegáveis mas não existem no mapa geral',
      () async {
    await PaleteRegistry().criar(apelido: 'A');   // 101

    // O mapa (itensLoja) é uma lista fixa de maquetes; palete e estante 5 não
    // aparecem lá, mas são paradas legítimas do carrossel. É por isso que a
    // busca precisa oferecer "Ver detalhes" sem depender de um item do mapa.
    for (final n in [5, paleteNumMin]) {
      expect(
        itensLoja.any((it) => it.tipo == 'estante' && it.numero == n),
        isFalse,
        reason: 'estante/palete $n passou a ter maquete no mapa',
      );
      expect(ordemNavegacaoEstantes.contains(n), isTrue);
    }
  });

  test('estruturas do mapa continuam achando o próprio item', () {
    // Contraprova do teste acima: quem tem maquete é encontrado normalmente,
    // então o caminho "fora do mapa" só vale para quem realmente não tem.
    for (final n in [1, 2, 6, 7, 8]) {
      final numeroMapa = numeroNoMapaLoja('estante', n);
      expect(
        itensLoja.any((it) => it.tipo == 'estante' && it.numero == numeroMapa),
        isTrue,
        reason: 'estante $n sumiu do mapa',
      );
    }
  });

  test('palete nunca é apresentado como estante ao usuário', () {
    expect(rotuloCurtoEstrutura('estante', paleteNumMin), 'P101');
    expect(nomeEstrutura('estante', paleteNumMin), 'Palete 101');
    expect(rotuloCurtoEstrutura('estante', 5), 'E5');
    expect(nomeEstrutura('estante', 5), 'Estante 5');
    expect(rotuloCurtoEstrutura('gondola', 7), 'G7');
    expect(nomeEstrutura('gondola', 7), 'Gôndola 7');
  });

  // ── Geometria ──────────────────────────────────────────────────────────────

  test('PaleteGeometry: 15 células cobrindo o palete inteiro sem sobrepor', () {
    final celulas = PaleteGeometry.celulas();
    expect(celulas.length, 15);

    // Cada (coluna, fileira) aparece uma única vez.
    expect(celulas.map((c) => '${c.coluna}|${c.nivel}').toSet().length, 15);

    // A grade cobre exatamente 1,20 × 1,00 m.
    expect(celulas.map((c) => c.xMin).reduce((a, b) => a < b ? a : b),
        closeTo(0, 1e-9));
    expect(celulas.map((c) => c.xMax).reduce((a, b) => a > b ? a : b),
        closeTo(PaleteGeometry.largura, 1e-9));
    expect(celulas.map((c) => c.zMin).reduce((a, b) => a < b ? a : b),
        closeTo(0, 1e-9));
    expect(celulas.map((c) => c.zMax).reduce((a, b) => a > b ? a : b),
        closeTo(PaleteGeometry.profundidade, 1e-9));

    // Todas as caixas se apoiam no topo do deck.
    for (final c in celulas) {
      expect(c.yTop, closeTo(PaleteGeometry.alturaTotal, 1e-9));
    }
  });

  test('a caixa padrão cabe na célula da grade', () {
    final wCol = PaleteGeometry.largura / colunasPalete;
    final dFil = PaleteGeometry.profundidade / fileirasPalete;
    expect(PaleteGeometry.wCaixa, lessThan(wCol));
    expect(PaleteGeometry.dCaixa, lessThan(dFil));
  });

  test('o deck fecha a profundidade real com vãos iguais', () {
    // 3 tábuas largas + 2 estreitas + 4 vãos = 1,00 m exatos.
    final madeira =
        PaleteGeometry.largurasDeck.fold(0.0, (s, w) => s + w);
    final vaos =
        PaleteGeometry.vaoDeck * (PaleteGeometry.largurasDeck.length - 1);
    expect(madeira + vaos, closeTo(PaleteGeometry.profundidade, 1e-9));
    expect(PaleteGeometry.vaoDeck, greaterThan(0));
  });

  test('a altura total sai das camadas reais do palete', () {
    // base (2,2 cm) + blocos (10 cm) + deck (2,2 cm) = 14,4 cm.
    expect(
      PaleteGeometry.espTabua + PaleteGeometry.ladoBloco + PaleteGeometry.espTabua,
      closeTo(PaleteGeometry.alturaTotal, 1e-9),
    );
    expect(PaleteGeometry.yDeckTopo, closeTo(0.144, 1e-9));
  });

  test('buildFaces desenha o palete sem faces degeneradas', () {
    final faces = PaleteGeometry.buildFaces();
    expect(faces, isNotEmpty);
    for (final f in faces) {
      expect(f.verts.length, greaterThanOrEqualTo(3));
    }
  });

  // ── Smoke test da cena ─────────────────────────────────────────────────────

  testWidgets('PaleteScene renderiza sem exceções', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: PaleteScene(
        estanteAtual: paleteNumMin,
        caixas: [
          // Uma em cada fileira, incluindo as colunas extremas (3 e 4 estouram
          // a grade de 3 colunas da EstanteScene genérica).
          CaixaColocadaEstante(coluna: 0, nivel: 0, slot: 0, produtoId: 'P1'),
          CaixaColocadaEstante(coluna: 4, nivel: 1, slot: 0, produtoId: 'P2'),
          CaixaColocadaEstante(coluna: 2, nivel: 2, slot: 0, produtoId: 'P3'),
        ],
        corPorProduto: {
          'P1': Colors.green,
          'P2': Colors.amber,
          'P3': Colors.blue,
        },
        destacadoCodigo: 'P2',
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('PaleteScene aguenta caixa fora da grade e palete vazio',
      (tester) async {
    // Endereço antigo/inválido (coluna 9) não pode derrubar a cena — a mesma
    // tolerância das outras cenas.
    await tester.pumpWidget(const MaterialApp(
      home: PaleteScene(
        estanteAtual: paleteNumMin + 7,
        caixas: [
          CaixaColocadaEstante(coluna: 9, nivel: 9, slot: 0, produtoId: 'X'),
        ],
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const MaterialApp(
      home: PaleteScene(estanteAtual: paleteNumMin),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('PaleteScene marca divergência e conferência', (tester) async {
    final chave = chaveEnderecoEstoque(
      produtoCodigo: 'P1',
      localTipo:     'estante',
      localNum:      paleteNumMin,
      faceOuColuna:  0,
      andarOuNivel:  0,
    );
    await tester.pumpWidget(MaterialApp(
      home: PaleteScene(
        estanteAtual: paleteNumMin,
        caixas: const [
          CaixaColocadaEstante(coluna: 0, nivel: 0, slot: 0, produtoId: 'P1'),
          CaixaColocadaEstante(coluna: 1, nivel: 0, slot: 0, produtoId: 'P2'),
        ],
        divergentes:       {chave},
        desatualizados:    {chave},
        destacadosCodigos: const {'P2'},
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
