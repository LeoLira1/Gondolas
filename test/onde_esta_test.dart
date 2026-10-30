import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/models.dart';
import 'package:gondola_camda/onde_esta.dart';

ProdutoEncontrado _e(String codigo, String nome, String tipo, int numero,
        [String nivel = 'Nível 1', double? qtd]) =>
    ProdutoEncontrado(
      nome: nome,
      tipo: tipo,
      numero: numero,
      nivelDescricao: nivel,
      produtoCodigo: codigo,
      quantidade: qtd,
    );

void main() {
  group('enderecosDoProduto', () {
    test('código exato: pedaço de outro código não entra', () {
      final r = enderecosDoProduto([
        _e('47279', 'ENXADA LARGA', 'gondola', 3),
        _e('147279', 'OUTRO PRODUTO', 'estante', 5),
      ], codigos: {'47279'}, nome: 'ENXADA LARGA');
      expect(r.map((e) => e.produtoCodigo), ['47279']);
    });

    test('código irmão também conta', () {
      final r = enderecosDoProduto([
        _e('100', 'BOTA', 'gondola', 1),
        _e('200', 'BOTA', 'galpao', 52),
      ], codigos: {'100', '200'}, nome: 'BOTA');
      expect(r, hasLength(2));
    });

    test('sem código, cai no nome igual (sem acento e maiúsculas)', () {
      final r = enderecosDoProduto([
        _e('X1', 'Óleo Lub  Texaco', 'estante', 2),
        _e('X2', 'OLEO LUB TEXACO 20L', 'estante', 2),
      ], codigos: {'999'}, nome: 'OLEO LUB TEXACO');
      expect(r.map((e) => e.produtoCodigo), ['X1']);
    });

    test('a mesma linha vinda de duas buscas aparece uma vez', () {
      final linha = _e('100', 'BOTA', 'gondola', 1);
      final r = enderecosDoProduto([linha, linha],
          codigos: {'100'}, nome: 'BOTA');
      expect(r, hasLength(1));
    });
  });

  test('rotuloEndereco segue o texto da busca do mapa', () {
    expect(rotuloEndereco(_e('1', 'A', 'gondola', 3, 'Face 1 · Andar Base')),
        'Gôndola nº 3 · Face 1 · Andar Base');
    expect(rotuloEndereco(_e('1', 'A', localTipoGalpao, 52, 'Rua 2')),
        'Galpão nº 52 · Rua 2');
    expect(rotuloEndereco(_e('1', 'A', localTipoBarracao, 7, 'BAR-07')),
        'Barracão · BAR-07');
    expect(rotuloEndereco(_e('1', 'A', 'estante', ilhaPaletesNum, 'Espaço 3')),
        'Ilha de paletes · Espaço 3');
  });

  group('mostrarOndeEsta', () {
    Future<List<ProdutoEncontrado>> abrirCom(
        WidgetTester t, List<ProdutoEncontrado> enderecos,
        {String? tocar}) async {
      final abertos = <ProdutoEncontrado>[];
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => mostrarOndeEsta(ctx,
                  codigo: '47279',
                  nome: 'ENXADA LARGA',
                  buscar: () async => enderecos,
                  abrir: (_, e) async => abertos.add(e)),
              child: const Text('ir'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('ir'));
      await t.pumpAndSettle();
      if (tocar != null) {
        await t.tap(find.text(tocar));
        await t.pumpAndSettle();
      }
      return abertos;
    }

    testWidgets('um endereço abre direto', (t) async {
      final abertos =
          await abrirCom(t, [_e('47279', 'ENXADA', 'gondola', 3)]);
      expect(abertos.single.numero, 3);
    });

    testWidgets('dois endereços: lista para escolher', (t) async {
      final abertos = await abrirCom(t, [
        _e('47279', 'ENXADA', 'gondola', 3, 'Face 1 · Andar Base', 3),
        _e('47279', 'ENXADA', localTipoGalpao, 52, 'Rua 2'),
      ], tocar: 'Galpão nº 52 · Rua 2');
      expect(abertos.single.tipo, localTipoGalpao);
    });

    testWidgets('nenhum endereço avisa', (t) async {
      final abertos = await abrirCom(t, []);
      expect(abertos, isEmpty);
      expect(find.textContaining('não tem endereço no mapa'), findsOneWidget);
    });
  });
}
