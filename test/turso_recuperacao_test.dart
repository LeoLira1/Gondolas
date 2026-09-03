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


  // A trava é da RÉPLICA marcada, não do app: fora dela não existe frame
  // local para o servidor recusar. Estes testes deixam o singleton
  // destravado, por isso vêm depois do grupo acima.
  group('a trava não vaza para onde não há réplica divergente', () {
    final chaveVazio =
        '${TursoService.keyRecuperacaoNecessaria}_${idBanco('')}';

    test('cache local desligado grava direto no remoto', () async {
      SharedPreferences.setMockInitialValues({chaveVazio: true});
      await TursoService().init();
      expect(TursoService().estadoReplica,
          EstadoReplica.recuperacaoNecessaria,
          reason: 'com cache local ligado, a marca vale');

      // O usuário desliga o cache local: não há mais arquivo de réplica no
      // caminho, e toda gravação vai pela rede. Travar aqui seria recusar
      // escrita que não tem como divergir.
      SharedPreferences.setMockInitialValues({
        chaveVazio: true,
        TursoService.keyCacheLocal: false,
      });
      await TursoService().init();

      expect(TursoService().estadoReplica,
          isNot(EstadoReplica.recuperacaoNecessaria));
    });

    test('outro banco não herda a trava do anterior', () async {
      SharedPreferences.setMockInitialValues({chaveVazio: true});
      await TursoService().init();
      expect(TursoService().estadoReplica,
          EstadoReplica.recuperacaoNecessaria);

      // Troca para um banco que nunca divergiu. Sem token, o init decide tudo
      // o que importa aqui e volta antes de tocar na rede.
      SharedPreferences.setMockInitialValues({
        chaveVazio: true,
        TursoService.keyDbUrl: 'libsql://banco-saudavel.turso.io',
      });
      await TursoService().init();

      expect(TursoService().estadoReplica,
          isNot(EstadoReplica.recuperacaoNecessaria),
          reason: 'a trava do banco anterior ficava presa em memória');
    });

    test('voltar ao banco marcado volta a travar', () async {
      SharedPreferences.setMockInitialValues({
        chaveVazio: true,
        TursoService.keyDbUrl: 'libsql://banco-saudavel.turso.io',
      });
      await TursoService().init();
      expect(TursoService().estadoReplica,
          isNot(EstadoReplica.recuperacaoNecessaria));

      // A marca continua em disco: ela não some por o app ter passado por
      // outro banco no meio do caminho.
      SharedPreferences.setMockInitialValues({chaveVazio: true});
      await TursoService().init();

      expect(TursoService().estadoReplica,
          EstadoReplica.recuperacaoNecessaria);
    });
  });
}
