import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'turso_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Fila de etiquetas: a lista do app Etiquetas CAMDA (LeoLira1/etiquetaszebra)
// ─────────────────────────────────────────────────────────────────────────────
//
// Mesma tabela fila_etiquetas do app de etiquetas e das ferramentas
// ver_fila_etiquetas/adicionar_etiqueta do MCP (LeoLira1/camda-mcp,
// src/fila_etiquetas.ts). Aqui é só leitura: imprimir e apagar continuam no
// app de etiquetas. A marca "coloquei na prateleira" fica só neste celular.

class ItemFilaEtiqueta {
  final String id;
  final String codigo;
  final String nome;

  /// Cliques no app de etiquetas: cada clique imprime um par.
  final int pares;
  final bool impresso;

  /// "AAAA-MM-DD HH:MM:SS" em horário de Brasília, como o app grava.
  final String criadoEm;
  final String? impressoEm;

  const ItemFilaEtiqueta({
    required this.id,
    required this.codigo,
    required this.nome,
    this.pares = 1,
    this.impresso = false,
    this.criadoEm = '',
    this.impressoEm,
  });

  /// "17:37" da impressão (ou da criação, se ainda pendente).
  String get hora {
    final s = (impresso ? impressoEm : criadoEm) ?? '';
    return s.length >= 16 ? s.substring(11, 16) : '';
  }
}

/// Linhas da consulta → itens: impressos primeiro (mais recentes em cima),
/// depois os pendentes (mais antigos em cima, como no app de etiquetas).
List<ItemFilaEtiqueta> montarFilaEtiquetas(List<Map<String, dynamic>> linhas) {
  String texto(Object? v) => (v ?? '').toString().trim();
  final itens = [
    for (final r in linhas)
      ItemFilaEtiqueta(
        id: texto(r['id']),
        codigo: texto(r['codigo']),
        nome: texto(r['nome']),
        pares: (r['pares'] as num?)?.round() ?? 1,
        impresso: texto(r['status']) == 'impresso',
        criadoEm: texto(r['criado_em']),
        impressoEm: texto(r['impresso_em']).isEmpty
            ? null
            : texto(r['impresso_em']),
      ),
  ];
  final impressos = itens.where((i) => i.impresso).toList()
    ..sort((a, b) => (b.impressoEm ?? '').compareTo(a.impressoEm ?? ''));
  final pendentes = itens.where((i) => !i.impresso).toList()
    ..sort((a, b) => a.criadoEm.compareTo(b.criadoEm));
  return [...impressos, ...pendentes];
}

/// "AAAA-MM-DD" de hoje em Brasília (UTC-3 fixo, sem horário de verão).
String hojeBrt([DateTime? agora]) {
  final d =
      (agora ?? DateTime.now()).toUtc().subtract(const Duration(hours: 3));
  String dois(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${dois(d.month)}-${dois(d.day)}';
}

/// Só os ids que ainda estão na fila: o resto é marca velha.
Set<String> marcasValidas(Set<String> marcas, Iterable<ItemFilaEtiqueta> itens) {
  final ids = {for (final i in itens) i.id};
  return marcas.where(ids.contains).toSet();
}

class FilaEtiquetasService {
  static const keyColocadas = 'etiquetas_colocadas_v1';

  const FilaEtiquetasService();

  /// Pendentes + impressos hoje, direto do remoto: quem grava é o app de
  /// etiquetas, e a réplica local deste app pode estar sem o último sync.
  Future<List<ItemFilaEtiqueta>> buscar() async {
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
      final stmt = await db.prepare(
        'SELECT id, codigo, nome, pares, status, criado_em, impresso_em '
        'FROM fila_etiquetas '
        "WHERE status = 'pendente' "
        "OR (status = 'impresso' AND substr(impresso_em, 1, 10) = ?)",
      );
      final rows = await stmt
          .query(positional: [hojeBrt()])
          .timeout(const Duration(seconds: 40)) as List<dynamic>;
      return montarFilaEtiquetas([
        for (final r in rows) Map<String, dynamic>.from(r as Map),
      ]);
    } catch (e) {
      // A tabela nasce no primeiro sync do app de etiquetas.
      if (TursoService.erroDeTabelaAusente(e)) return const [];
      rethrow;
    } finally {
      try {
        await db.dispose();
      } catch (_) {}
    }
  }

  static Future<Set<String>> lerColocadas() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(keyColocadas) ?? const <String>[]).toSet();
  }

  static Future<void> gravarColocadas(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(keyColocadas, ids.toList()..sort());
  }
}
