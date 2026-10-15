import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/replica_coordinator.dart';
import 'package:gondola_camda/replica_local.dart' show idBanco;
import 'package:gondola_camda/turso_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Estes testes falam com o TursoService de verdade, mas nunca com a rede: a
/// URL fica vazia de propósito, então o `_init` decide tudo o que interessa
/// aqui (identidade do banco, marca de recuperação) e volta antes de tentar
/// qualquer conexão.
///
/// Contrato anterior substituído: o TursoService é singleton e a trava da
/// recuperação, uma vez de pé, só sai por recuperação explícita — que é
/// justamente o que estes testes afirmam. Por isso os testes de troca de banco
/// vêm antes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const url = 'libsql://camda-teste.turso.io';
  const outraUrl = 'libsql://outro-banco.turso.io';
  final chavePendentes =
      '${TursoService.keyGravacoesPendentes}_${idBanco(url)}';

  group('trocar a URL do banco com gravação pendente', () {
    test('mesma URL nunca é impedimento', () async {
      SharedPreferences.setMockInitialValues({
        TursoService.keyDbUrl: url,
        chavePendentes: 7,
      });

      expect(await TursoService().impedimentoParaTrocarBanco(url), isNull);
      // Barra sobrando no fim é o MESMO banco (ver normalizarIdentidadeBanco).
      expect(await TursoService().impedimentoParaTrocarBanco('$url/'), isNull);
    });

    test('sem pendência a troca passa', () async {
      SharedPreferences.setMockInitialValues({
        TursoService.keyDbUrl: url,
        chavePendentes: 0,
      });

      expect(await TursoService().impedimentoParaTrocarBanco(outraUrl), isNull);
    });

    test('primeira configuração do app passa', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await TursoService().impedimentoParaTrocarBanco(url), isNull);
    });

    test('pendência no banco atual barra a troca ANTES de gravar', () async {
      SharedPreferences.setMockInitialValues({
        TursoService.keyDbUrl: url,
        chavePendentes: 3,
      });

      final impedimento = await TursoService().impedimentoParaTrocarBanco(
        outraUrl,
      );

      expect(impedimento, isNotNull);
      expect(impedimento, contains('3 gravações'));
      // E as credenciais continuam intactas: é isso que mantém o banco
      // anterior alcançável para sincronizar.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TursoService.keyDbUrl), url);
    });

    test('contador legado, sem namespace, também barra', () async {
      SharedPreferences.setMockInitialValues({
        TursoService.keyDbUrl: url,
        TursoService.keyGravacoesPendentes: 1,
      });

      final impedimento = await TursoService().impedimentoParaTrocarBanco(
        outraUrl,
      );

      expect(impedimento, isNotNull);
      expect(impedimento, contains('1 gravação'));
    });
  });

  group('migração para cache de consulta preserva o legado', () {
    final chave = '${TursoService.keyRecuperacaoNecessaria}_${idBanco('')}';
    setUp(() {
      SharedPreferences.setMockInitialValues({
        chave: true,
      });
    });

    test('cache ligado não abre réplica para novas gravações', () async {
      await TursoService().init();
      expect(TursoService().modoLocal, isFalse);
      expect(TursoService().estadoReplica, EstadoReplica.desconectada);
      expect((await SharedPreferences.getInstance()).getBool(chave), isTrue);
    });

    test('reabrir mantém a marca antiga sem ativar a réplica', () async {
      await TursoService().init();
      await TursoService().init();
      expect(TursoService().modoLocal, isFalse);
      expect((await SharedPreferences.getInstance()).getBool(chave), isTrue);
    });

    test('sem conexão não executa escrita nem diz que atualizou', () async {
      await TursoService().init();
      var escreveu = false;
      await expectLater(
        TursoService().garantirReplicaProntaParaEscrita(
          () async => escreveu = true,
        ),
        throwsA(isA<ReplicaNaoProntaParaEscrita>()),
      );
      expect(escreveu, isFalse);
      expect(await TursoService().sincronizar(), isFalse);
      expect((await SharedPreferences.getInstance()).getBool(chave), isTrue);
    });

    test('a chave antiga de cache some e o arquivo antigo segue protegido',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(TursoService.keyCacheLocal, false);
      await prefs.setString('consulta_v1_x_gondola_3', '[]');
      await prefs.setString('consulta_v1_x_gondola_3|em', '');
      await prefs.setString('consulta_v1_x_busca_estantes', '[]');
      await prefs.setString('consulta_v1_x_galpao', '[]');
      await prefs.remove('limpeza_preferencias_v1');
      await TursoService().init();
      expect(TursoService().modoLocal, isFalse);
      expect(prefs.getBool(chave), isTrue);
      expect(prefs.containsKey(TursoService.keyCacheLocal), isFalse);
      expect(prefs.containsKey('consulta_v1_x_gondola_3'), isFalse);
      expect(prefs.containsKey('consulta_v1_x_gondola_3|em'), isFalse);
      expect(prefs.containsKey('consulta_v1_x_busca_estantes'), isFalse);
      expect(prefs.getString('consulta_v1_x_galpao'), '[]');
    });

    test('outro banco não herda a marca antiga', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(TursoService.keyDbUrl, outraUrl);
      await TursoService().init();
      expect(
        TursoService().estadoReplica,
        isNot(EstadoReplica.recuperacaoNecessaria),
      );
      expect(prefs.getBool(chave), isTrue);
    });

    test(
      'voltar ao banco antigo mantém leitura sem reativar offline writes',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(TursoService.keyDbUrl, outraUrl);
        await TursoService().init();
        await prefs.setString(TursoService.keyDbUrl, '');
        await TursoService().init();
        expect(TursoService().modoLocal, isFalse);
        expect(prefs.getBool(chave), isTrue);
      },
    );
  });
}
