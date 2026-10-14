import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/estoque_localizado_service.dart';
import 'package:gondola_camda/galpao_service.dart';
import 'package:gondola_camda/models.dart' show localTipoGalpao;
import 'package:gondola_camda/turso_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('endereço do galpão em estoque_localizado', () {
    test('local_tipo é o terceiro tipo, ao lado de gondola e estante', () {
      expect(localTipoGalpao, 'galpao');
    });

    test('o endereço compacto do log traz posição e nível', () {
      const e = EnderecoLocalizado(
        produtoCodigo: 'HB500',
        localTipo:     localTipoGalpao,
        localNum:      52,
        faceOuColuna:  0,
        andarOuNivel:  3,
        quantidade:    900,
      );
      expect(e.ehGalpao, isTrue);
      expect(e.ehGondola, isFalse);
      // O nível aparece porque isto é REGISTRO do que havia ali naquele
      // instante — não uma referência a ser reaberta depois (a ordem muda
      // sozinha quando um rack abaixo sai).
      expect(e.enderecoCompacto, 'GALPAO·52·N3');
    });

    test('gôndola e estante continuam com o formato de sempre', () {
      const g = EnderecoLocalizado(
        produtoCodigo: 'X', localTipo: 'gondola', localNum: 9,
        faceOuColuna: 3, andarOuNivel: 1, quantidade: 0,
      );
      expect(g.enderecoCompacto, 'G9·F3·A2');

      const e = EnderecoLocalizado(
        produtoCodigo: 'X', localTipo: 'estante', localNum: 1,
        faceOuColuna: 0, andarOuNivel: 0, quantidade: 0,
      );
      expect(e.enderecoCompacto.startsWith('E1·'), isTrue);
    });

    test('mesmoEndereco distingue galpão de estante no mesmo número', () {
      // Posição 52 do galpão e estante 52 são endereços diferentes: sem o
      // local_tipo na comparação, o espelho do galpão poderia sobrescrever
      // uma linha de estante.
      const galpao = EnderecoLocalizado(
        produtoCodigo: 'X', localTipo: localTipoGalpao, localNum: 52,
        faceOuColuna: 0, andarOuNivel: 1, quantidade: 0,
      );
      const estante = EnderecoLocalizado(
        produtoCodigo: 'X', localTipo: 'estante', localNum: 52,
        faceOuColuna: 0, andarOuNivel: 1, quantidade: 0,
      );
      expect(galpao.mesmoEndereco(estante), isFalse);
    });
  });

  group('GalpaoService sem banco configurado', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    // O galpão precisa abrir mesmo sem URL/token: quem instala o APK antes de
    // configurar o banco veria a tela crashar em vez de um galpão vazio.
    test('carregarPilhas devolve vazio em vez de estourar', () async {
      expect(await GalpaoService().carregarPilhas(), isEmpty);
    });

    test('garantirSeed devolve false', () async {
      expect(await GalpaoService().garantirSeed(forcar: true), isFalse);
    });

    test('lancar e esvaziar devolvem false (quem chamou sabe que não gravou)',
        () async {
      expect(
        await GalpaoService().lancar(
            posicao: 1, produtoCodigo: 'X', produtoNome: 'X', quantidade: 1),
        isFalse,
      );
      expect(
        await GalpaoService().esvaziar(posicao: 1, ordem: 1, rackUuid: 'r'),
        isFalse,
      );
    });

    // O saldo agora sai das cópias de leitura. Sem banco e sem cópia, a
    // resposta é "não sei" (vazio), nunca endereçado zero — que pintaria de
    // vermelho todo rack do galpão.
    test('saldo sem banco nem cópia devolve vazio', () async {
      expect(
        await GalpaoService().carregarSaldos(codigosComRack: {'BORAL'}),
        isEmpty,
      );
      expect(await GalpaoService().carregarSaldo('BORAL'), isNull);
    });

    test('local anotado pela fila não trava a leitura das quantidades',
        () async {
      TursoService().marcarLocalGravado('galpao', 52);
      expect(await TursoService().consultarQuantidades(), isEmpty);
      // A anotação foi consumida: a próxima leitura não tenta de novo.
      expect(await TursoService().consultarQuantidades(), isEmpty);
    });
  });
}
