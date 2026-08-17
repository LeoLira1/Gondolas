import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/models.dart';

/// Reprodução da chave de agrupamento usada por
/// `TursoService._anexarQuantidades` para casar linhas de estoque_localizado
/// com os resultados da busca.
///
/// Vive aqui como espelho porque o método é privado e depende de conexão. O
/// que importa não é o formato da string, e sim a propriedade: endereços de
/// TIPOS diferentes nunca podem colidir.
String chaveDaLinha({
  required String codigo,
  required String tipo,
  required int localNum,
  required int faceOuColuna,
  required int andarOuNivel,
}) =>
    switch (tipo) {
      'gondola' => 'g|$codigo|$localNum|$faceOuColuna|$andarOuNivel',
      localTipoGalpao => 'x|$codigo|$localNum|$andarOuNivel',
      _ => 'e|$codigo|$localNum|'
          '${andarOuNivel.clamp(0, niveisProdutoPara(localNum) - 1)}',
    };

void main() {
  group('quantidade por endereço não mistura tipos', () {
    test('galpão e estante de MESMO número não colidem', () {
      // Este era o defeito: os números de posição do galpão (1–78) se
      // sobrepõem aos de estante (1–21), e a chave antiga só olhava o
      // número — a quantidade do galpão era somada dentro da estante.
      final noGalpao = chaveDaLinha(
        codigo: 'HB500', tipo: localTipoGalpao,
        localNum: 5, faceOuColuna: 0, andarOuNivel: 1,
      );
      final naEstante = chaveDaLinha(
        codigo: 'HB500', tipo: 'estante',
        localNum: 5, faceOuColuna: 0, andarOuNivel: 1,
      );
      expect(noGalpao, isNot(naEstante));
    });

    test('gôndola, estante e galpão têm prefixos distintos', () {
      final chaves = {
        for (final tipo in ['gondola', 'estante', localTipoGalpao])
          chaveDaLinha(
            codigo: 'X', tipo: tipo,
            localNum: 3, faceOuColuna: 0, andarOuNivel: 1,
          ),
      };
      expect(chaves.length, 3);
    });

    test('somar duas linhas do MESMO endereço continua funcionando', () {
      final a = chaveDaLinha(
        codigo: 'X', tipo: localTipoGalpao,
        localNum: 52, faceOuColuna: 0, andarOuNivel: 2,
      );
      final b = chaveDaLinha(
        codigo: 'X', tipo: localTipoGalpao,
        localNum: 52, faceOuColuna: 0, andarOuNivel: 2,
      );
      expect(a, b);
    });

    test('níveis diferentes da mesma posição são endereços diferentes', () {
      final n1 = chaveDaLinha(
        codigo: 'X', tipo: localTipoGalpao,
        localNum: 52, faceOuColuna: 0, andarOuNivel: 1,
      );
      final n2 = chaveDaLinha(
        codigo: 'X', tipo: localTipoGalpao,
        localNum: 52, faceOuColuna: 0, andarOuNivel: 2,
      );
      expect(n1, isNot(n2));
    });
  });

  group('ProdutoEncontrado do galpão', () {
    test('carrega posição, ordem e a rua na descrição', () {
      const p = ProdutoEncontrado(
        nome:           'HERBICIDA BORAL 500 SC 20L',
        tipo:           localTipoGalpao,
        numero:         52,
        nivelDescricao: 'Rua 5 · N2',
        produtoCodigo:  'HB500',
        nivel:          2,
        quantidade:     900,
      );
      expect(p.tipo, localTipoGalpao);
      expect(p.numero, 52);
      expect(p.nivel, 2);
      // A quantidade vem da própria linha do rack, então já chega preenchida
      // (nas outras estruturas ela é anexada depois, de estoque_localizado).
      expect(p.quantidade, 900);
    });
  });
}
