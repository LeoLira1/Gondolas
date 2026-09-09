import 'package:libsql_dart/libsql_dart.dart';

import 'barracao_config.dart';

const String migracaoBarracaoLayout2x2 = 'barracao_layout_2x2_v1';

/// Reposiciona somente os endereços padrão. IDs, produtos, quantidades e
/// endereços extras permanecem intactos.
Future<void> migrarBarracaoParaLayout2x2(LibsqlClient client) async {
  try {
    final check = await client.prepare(
      'SELECT 1 FROM app_migrations WHERE nome = ? LIMIT 1',
    );
    final aplicada = await check.query(
        positional: [migracaoBarracaoLayout2x2]) as List<dynamic>;
    if (aplicada.isNotEmpty) return;
    final tx = await client.transaction();
    try {
      for (final p in BarracaoConfig.posicoesPadrao) {
        await tx.execute(
          'UPDATE barracao_enderecos SET pos_x = ?, pos_z = ? WHERE rotulo = ?',
          positional: [p.x, p.z, p.rotulo],
        );
      }
      await tx.execute(
        'INSERT INTO app_migrations (nome, aplicada_em) VALUES (?, ?)',
        positional: [migracaoBarracaoLayout2x2,
          DateTime.now().toIso8601String()],
      );
      await tx.commit();
    } catch (e) {
      await tx.rollback();
      rethrow;
    }
  } catch (_) {
    // Sem marcador a próxima abertura tenta novamente.
  }
}
