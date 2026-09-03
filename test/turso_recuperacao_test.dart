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
/// A ORDEM IMPORTA na segunda metade: o TursoService é singleton e a trava da
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

      expect(
          await TursoService().impedimentoParaTrocarBanco(outraUrl), isNull);
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

      final impedimento =
          await TursoService().impedimentoParaTrocarBanco(outraUrl);

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

      final impedimento =
          await TursoService().impedimentoParaTrocarBanco(outraUrl);

      expect(impedimento, isNotNull);
      expect(impedimento, contains('1 gravação'));
    });
  });

  group('marca de recuperação sobrevive ao init', () {
    // Banco "vazio": o init lê as chaves desta identidade e volta sem rede.
    final chaveRecuperacao =
        '${TursoService.keyRecuperacaoNecessaria}_${idBanco('')}';

    test('init com a marca em disco tranca o portão de escrita', () async {
      SharedPreferences.setMockInitialValues({chaveRecuperacao: true});

      await TursoService().init();

      expect(TursoService().estadoReplica,
          EstadoReplica.recuperacaoNecessaria);

      var escreveu = false;
      await expectLater(
        TursoService().garantirReplicaProntaParaEscrita(
            () async => escreveu = true),
        throwsA(isA<ReplicaNaoProntaParaEscrita>()),
      );
      expect(escreveu, isFalse,
          reason: 'a réplica divergente não pode receber gravação nova');
    });

    test('reabrir o app não destrava', () async {
      // Segundo init da mesma sessão é o que o app faz a cada tela de
      // configuração; com a marca em disco, é também o que acontece depois de
      // fechar e abrir.
      await TursoService().init();

      expect(TursoService().estadoReplica,
          EstadoReplica.recuperacaoNecessaria);
    });

    test('Sincronizar não roda nem apaga a marca', () async {
      final ok = await TursoService().sincronizar();

      expect(ok, isFalse);
      expect(TursoService().ultimoErroSync, contains('Limpar cache local'));
      expect(TursoService().estadoReplica,
          EstadoReplica.recuperacaoNecessaria);
    });
  });
}
