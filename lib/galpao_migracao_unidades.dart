import 'package:libsql_dart/libsql_dart.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Migração: o galpão passa a guardar UNIDADES, não litros
// ─────────────────────────────────────────────────────────────────────────────
//
// Até aqui o galpão pedia baldes/caixas na tela e gravava litros no banco
// (unidades × 20, deduzido da litragem no fim do nome do produto). Os racks
// já lançados estão nessa conta antiga; sem converter, o rack de 45 baldes
// passaria a ser lido como 45... e mostrado como 900 unidades.
//
// A conversão roda UMA vez, controlada por app_migrations como as outras, e
// vale para os dois lugares onde a quantidade do galpão vive: galpao_racks e o
// espelho em estoque_localizado (local_tipo 'galpao'). O `atualizado_em` não é
// tocado de propósito — trocar de unidade não é recontar, e mexer na data
// faria os endereços parecerem recém-conferidos para o inventário cíclico.
//
// A dedução de litragem é a MESMA de antes, copiada para cá e só para cá: é
// código legado a serviço de dado legado, e o app novo não fala mais de litro
// em lugar nenhum (ver unidades.dart).

/// Nome do marcador em app_migrations.
const String migracaoGalpaoUnidades = 'galpao_quantidade_em_unidades_v1';

/// Litros de uma unidade de manuseio na convenção antiga — o balde É 20 L e a
/// caixa fechava 4 × 5 L = 20 L, então os dois casos convergiam no mesmo
/// divisor.
const double litrosPorUnidadeLegado = 20;

/// Litragem da embalagem no fim do nome ('HERBICIDA BORAL 500 SC 20L' → 20),
/// ou null quando o nome não a traz. Vale a ÚLTIMA ocorrência: a concentração
/// vem antes ('500 SC') e não termina em L colado a dígito.
double? _litragemDoNome(String nomeProduto) {
  final matches = RegExp(r'(\d+(?:[.,]\d+)?)\s?L\b', caseSensitive: false)
      .allMatches(nomeProduto);
  if (matches.isEmpty) return null;
  return double.tryParse(matches.last.group(1)!.replaceAll(',', '.'));
}

/// True quando a quantidade daquele produto foi gravada em litros — só os
/// produtos de 20 L (balde) e 5 L (caixa) passavam pela conversão; os demais
/// já eram gravados como o número digitado, e converter esses seria dividir
/// por 20 uma quantidade que nunca foi multiplicada.
bool quantidadeLegadaEmLitros(String nomeProduto) {
  final litragem = _litragemDoNome(nomeProduto);
  return litragem == 20 || litragem == 5;
}

/// Converte para unidades as quantidades do galpão gravadas em litros.
///
/// Idempotente pelo marcador em app_migrations: se já rodou, sai na hora. Se
/// falhar no meio, a transação desfaz tudo e o marcador não é gravado — a
/// próxima abertura tenta de novo, e nenhuma linha fica dividida duas vezes.
Future<void> migrarGalpaoParaUnidades(LibsqlClient client) async {
  try {
    final stmtCheck = await client.prepare(
      'SELECT 1 FROM app_migrations WHERE nome = ? LIMIT 1',
    );
    final jaAplicada = (await stmtCheck.query(
        positional: [migracaoGalpaoUnidades])) as List<dynamic>;
    if (jaAplicada.isNotEmpty) return;

    final stmtRacks = await client.prepare(
      'SELECT id, posicao, ordem, produto_codigo, produto_nome, quantidade '
      'FROM galpao_racks',
    );
    final rows = await stmtRacks.query() as List<dynamic>;

    final tx = await client.transaction();
    try {
      for (final dynamic row in rows) {
        final r = row as Map<String, dynamic>;
        final nome = r['produto_nome'] as String? ?? '';
        final litros = (r['quantidade'] as num?)?.toDouble() ?? 0;
        if (litros == 0 || !quantidadeLegadaEmLitros(nome)) continue;
        final unidades = litros / litrosPorUnidadeLegado;

        await tx.execute(
          'UPDATE galpao_racks SET quantidade = ? WHERE id = ?',
          positional: [unidades, r['id']],
        );
        // O espelho é achado pela mesma tripla que _reescreverEspelho grava:
        // posição, nível (= ordem do rack) e código do produto.
        await tx.execute(
          'UPDATE estoque_localizado SET quantidade = ? '
          "WHERE local_tipo = 'galpao' AND local_num = ? "
          'AND andar_ou_nivel = ? AND produto_codigo = ?',
          positional: [
            unidades,
            r['posicao'],
            r['ordem'],
            r['produto_codigo'],
          ],
        );
      }
      await tx.execute(
        'INSERT INTO app_migrations (nome, aplicada_em) VALUES (?, ?)',
        positional: [
          migracaoGalpaoUnidades,
          DateTime.now().toIso8601String(),
        ],
      );
      await tx.commit();
    } catch (e) {
      await tx.rollback();
      rethrow;
    }
  } catch (_) {
    // Migração não derruba a conexão — tenta de novo no próximo init().
  }
}
