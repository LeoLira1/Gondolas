// Selos das prateleiras para a verificação em SQLite real
// (tool/verify_badges_sql.py). Sem Flutter e sem rede.
//
// `--sql`: imprime o SQL das cópias novas (o mesmo que o app usa).
// Sem argumento: lê do stdin as linhas que o SQLite devolveu — do SQL ANTIGO
// (o JOIN que os selos usavam) e das cópias novas — e imprime as chaves dos
// endereços desatualizados, divergentes e positivos pelos dois caminhos. O
// caminho antigo é o laço que estoque_localizado_service fazia sobre o JOIN.
import 'dart:convert';
import 'dart:io';

import '../lib/badges_estoque.dart';

String _chave(Map r) =>
    '${r['produto_codigo']}|${r['local_tipo']}|${r['local_num']}|'
    '${r['face_ou_coluna']}|${r['andar_ou_nivel']}';

List<Map<String, dynamic>> _linhas(Object? lista) => [
  for (final r in (lista as List? ?? const [])) Map<String, dynamic>.from(r),
];

Future<void> main(List<String> args) async {
  if (args.contains('--sql')) {
    stdout.write(
      jsonEncode({
        'ciclico': sqlUltimaContagemCiclico,
        'itens_confirmado_em': sqlUltimaContagemItens('confirmado_em'),
        'itens_registrado_em': sqlUltimaContagemItens('registrado_em'),
        'divergentes': sqlDivergentesCiclo,
      }),
    );
    return;
  }
  final e = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;

  // ── Caminho antigo: o laço sobre as linhas do JOIN ──
  final antigoDesatualizados = <String>{};
  for (final r in _linhas(e['antigo_desatualizados'])) {
    final ultima = r['ultima'] as String?;
    final atual = r['atualizado_em'] as String?;
    if (ultima == null || atual == null) continue;
    final dtUltima = DateTime.tryParse(ultima);
    final dtAtual = DateTime.tryParse(atual);
    if (dtUltima == null || dtAtual == null) continue;
    if (!dtAtual.isBefore(dtUltima)) continue;
    antigoDesatualizados.add(_chave(r));
  }
  final antigoDivergentes = <String>{};
  final antigoPositivas = <String>{};
  for (final r in _linhas(e['antigo_divergentes'])) {
    antigoDivergentes.add(_chave(r));
    final contada = (r['qtd_contada_ciclo'] as num?)?.toDouble();
    final sistema = (r['qtd_sistema_na_contagem'] as num?)?.toDouble();
    if (contada != null && sistema != null && contada > sistema) {
      antigoPositivas.add(_chave(r));
    }
  }

  // ── Caminho novo: as cópias e as funções do app ──
  final enderecos = _linhas(e['enderecos']);
  final atrasados = calcularDesatualizados(
    enderecos: enderecos,
    ultimasContagens: [..._linhas(e['ciclico']), ..._linhas(e['itens'])],
  );
  final divergentes = calcularDivergentes(
    enderecos: enderecos,
    divergentesCiclo: _linhas(e['divergentes_ciclo']),
  );

  List<String> ordenadas(Iterable<String> chaves) => chaves.toSet().toList()
    ..sort();
  stdout.write(
    jsonEncode({
      'antigo': {
        'desatualizados': ordenadas(antigoDesatualizados),
        'divergentes': ordenadas(antigoDivergentes),
        'positivas': ordenadas(antigoPositivas),
      },
      'novo': {
        'desatualizados': ordenadas(atrasados.map((a) => _chave(a.endereco))),
        'divergentes': ordenadas(divergentes.divergentes.map(_chave)),
        'positivas': ordenadas(divergentes.positivas.map(_chave)),
      },
    }),
  );
}
