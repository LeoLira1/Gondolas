import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'turso_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Repor na Loja: produtos vendidos que precisam voltar do galpão para a loja
// ─────────────────────────────────────────────────────────────────────────────
//
// A mesma lista da aba 🏪 Repor na Loja do camda-estoque (get_reposicao_pendente
// no app_turso.py) e da ferramenta ver_repor_loja do MCP (LeoLira1/camda-mcp,
// src/abas.ts). Só leitura: marcar como reposto continua lá.

/// Cópia de CATEGORIAS_EXCLUIDAS_REPOSICAO (app_turso.py). Se mudar lá, mude
/// aqui também.
const List<String> categoriasExcluidasReposicao = [
  'HERBICIDAS', 'FUNGICIDAS', 'INSETICIDAS', 'NEMATICIDAS', 'ÓLEOS',
  'ADUBOS FOLIARES', 'ADUBOS QUÍMICOS', 'ADUBOS CORRETIVOS',
  'ADJUVANTES', 'ADJUVANTES/ESPALHANTES ADESIVO', 'SUPLEMENTO MINERAL',
  'SEMENTES',
  'MEDICAMENTOS', 'MEDICAMENTOS VETERINÁRIOS', 'MEDICAMENTOS VETERINARIOS',
  'VACINA AFTOSA', 'VACINAS DIVERSAS/SOROS',
  'ANTIBIOTICOS/ANTI-INFLAMATORIO',
  'ANESTESICO/ANALGESICO/DIURETIC',
  'ANTITOXICOS',
  'VERMIFUGOS',
  'MOSQUICIDA/CARRAPATICIDA/BERNI',
  'UNGUENTOS/POMADAS',
  'HOMEOPATICO',
  'HORMONIOS LEITEIROS',
  'TONICO MINERAL/VITAMINAS',
  'REPRODUCAO ANIMAL',
  'REPRODUTORES',
  'IDENTIFICACAO ANIMAL',
  'INOCULANTES P/ SILAGEM',
  'DIETA ANIMAL',
  'RATICIDAS',
];

class ItemReporLoja {
  final String codigo;
  final String produto;
  final String categoria;

  /// Unidades vendidas desde a última reposição.
  final int repor;
  final double saldoSistema;

  /// criado_em da linha, como veio do banco (null se não der para ler).
  final DateTime? pendenteDesde;

  const ItemReporLoja({
    required this.codigo,
    required this.produto,
    required this.categoria,
    required this.repor,
    required this.saldoSistema,
    this.pendenteDesde,
  });

  /// "hoje", "1d", "5d"… desde [pendenteDesde].
  String idade(DateTime agora) {
    final d = pendenteDesde;
    if (d == null) return '';
    final dias = DateTime(agora.year, agora.month, agora.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    return dias <= 0 ? 'hoje' : '${dias}d atrás';
  }
}

/// Linhas da consulta → itens, na ordem que vieram (mais recentes primeiro).
List<ItemReporLoja> montarReporLoja(List<Map<String, dynamic>> linhas) => [
      for (final r in linhas)
        ItemReporLoja(
          codigo: (r['codigo'] ?? '').toString().trim(),
          produto: (r['produto'] ?? '').toString().trim(),
          categoria: (r['categoria'] ?? '').toString().trim(),
          repor: (r['qtd_vendida'] as num?)?.round() ?? 0,
          saldoSistema: (r['qtd_estoque'] as num?)?.toDouble() ?? 0,
          pendenteDesde:
              DateTime.tryParse((r['criado_em'] ?? '').toString().trim()),
        ),
    ];

/// Lê a lista direto do remoto (como as Etiquetas): a reposição é gravada pelo
/// camda-estoque e a réplica local do app pode estar sem o último sync.
class ReporLojaService {
  const ReporLojaService();

  Future<List<ItemReporLoja>> buscar() async {
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
      final ph = List.filled(categoriasExcluidasReposicao.length, '?').join(',');
      // Mesma consulta de get_reposicao_pendente.
      final stmt = await db.prepare(
        'SELECT r.id, r.codigo, r.produto, r.categoria, r.qtd_vendida, '
        'COALESCE(e.qtd_sistema, 0) AS qtd_estoque, r.criado_em '
        'FROM reposicao_loja r '
        'LEFT JOIN estoque_mestre e ON r.codigo = e.codigo '
        'WHERE r.reposto = 0 AND r.qtd_vendida > 0 '
        'AND UPPER(r.categoria) NOT IN ($ph) '
        'ORDER BY r.criado_em DESC',
      );
      final rows = await stmt
          .query(positional: categoriasExcluidasReposicao)
          .timeout(const Duration(seconds: 40)) as List<dynamic>;
      return montarReporLoja([
        for (final r in rows) Map<String, dynamic>.from(r as Map),
      ]);
    } catch (e) {
      if (TursoService.erroDeTabelaAusente(e)) {
        throw StateError('Tabela reposicao_loja não existe nesse banco.');
      }
      rethrow;
    } finally {
      try {
        await db.dispose();
      } catch (_) {}
    }
  }
}
