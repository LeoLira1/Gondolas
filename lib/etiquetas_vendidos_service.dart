import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'etiquetas_vendidos.dart';
import 'turso_service.dart';

/// Lê do Turso o que a tela "Etiquetas – Vendidos" precisa e entrega para
/// [montarEtiquetasVendidos].
///
/// Usa uma conexão DIRETA ao remoto, só de leitura, aberta e fechada a cada
/// busca: as vendas do dia chegam pelo camda-estoque, e a replica local do app
/// pode estar sem o último sync. Nada aqui grava no banco.
class EtiquetasVendidosService {
  const EtiquetasVendidosService();

  /// "AAAA-MM-DD" de [data] (só a parte do calendário).
  static String dataIso(DateTime data) =>
      '${data.year.toString().padLeft(4, '0')}-'
      '${data.month.toString().padLeft(2, '0')}-'
      '${data.day.toString().padLeft(2, '0')}';

  /// Hoje no fuso America/Sao_Paulo (UTC−3, sem horário de verão desde 2019),
  /// independente do fuso configurado no aparelho.
  static DateTime hojeBrasilia([DateTime? agora]) {
    final brt = (agora ?? DateTime.now())
        .toUtc()
        .subtract(const Duration(hours: 3));
    return DateTime(brt.year, brt.month, brt.day);
  }

  Future<ResultadoEtiquetasVendidos> buscar(DateTime dia) async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(TursoService.keyDbUrl) ?? '';
    final token = prefs.getString(TursoService.keyDbToken) ?? '';
    if (url.isEmpty || token.isEmpty) {
      throw StateError(
          'Banco não configurado. Toque em ⚙️ no app e preencha URL e Token.');
    }

    final db = LibsqlClient.remote(url, authToken: token);
    try {
      await db.connect().timeout(const Duration(seconds: 20));

      Future<List<Map<String, dynamic>>> q(String sql,
          [List<Object?> args = const []]) async {
        final stmt = await db.prepare(sql);
        final rows = await stmt
            .query(positional: args)
            .timeout(const Duration(seconds: 40)) as List<dynamic>;
        return rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      }

      final tabelas = {
        for (final r in await q(
            "SELECT name FROM sqlite_master WHERE type = 'table'"))
          r['name'].toString(),
      };
      if (!tabelas.contains('vendas_historico')) {
        throw StateError('Tabela vendas_historico não existe nesse banco.');
      }
      final temGondola = tabelas.contains('gondola_layout');
      final temEstante = tabelas.contains('estante_layout');
      if (!temGondola && !temEstante) {
        throw StateError('Nenhuma tabela de layout (gondola_layout/'
            'estante_layout) nesse banco.');
      }

      final d = dataIso(dia);
      final vendas = await q(
        'SELECT codigo, MAX(produto) AS produto, MAX(grupo) AS grupo, '
        'SUM(qtd_vendida) AS qtd FROM vendas_historico '
        'WHERE date(data_upload) BETWEEN ? AND ? AND qtd_vendida > 0 '
        'GROUP BY codigo ORDER BY codigo',
        [d, d],
      );
      if (vendas.isEmpty) {
        return const ResultadoEtiquetasVendidos(
            produtosVendidos: 0, produtos: [], fora: [], avisos: []);
      }

      final produtos = await q(
          'SELECT codigo, produto, categoria FROM estoque_mestre');

      // Vínculos do mapa, como o resto do app lê (ver codigos_vinculados.dart).
      final vinculos = <Map<String, dynamic>>[];
      if (tabelas.contains('mapa_produtos')) {
        final cols = {
          for (final r in await q(
              "SELECT name FROM pragma_table_info('mapa_produtos')"))
            r['name'].toString(),
        };
        if (cols.contains('codigo')) {
          vinculos.addAll(await q('SELECT codigo, produto_id FROM mapa_produtos '
              'WHERE codigo IS NOT NULL'));
        }
        if (tabelas.contains('mapa_produtos_codigos')) {
          vinculos.addAll(await q(
              'SELECT codigo, produto_id FROM mapa_produtos_codigos'));
        }
      }

      final gondolas = temGondola
          ? await q('SELECT produto_codigo, produto_nome, gondola_num, andar, '
              'pos_x, pos_z FROM gondola_layout')
          : <Map<String, dynamic>>[];
      final estantes = temEstante
          ? await q('SELECT produto_codigo, produto_nome, estante_num, '
              'coluna, nivel FROM estante_layout')
          : <Map<String, dynamic>>[];

      return montarEtiquetasVendidos(
        vendas: vendas,
        produtos: produtos,
        vinculosMapa: vinculos,
        gondolas: gondolas,
        estantes: estantes,
      );
    } finally {
      try {
        await db.dispose();
      } catch (_) {}
    }
  }
}
