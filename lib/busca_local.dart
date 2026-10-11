import 'dart:convert';

/// Filtra a cópia completa, não resultados guardados para um termo anterior.
/// Digitar um nome novo não precisa de uma nova consulta ao servidor.
List<Map<String, dynamic>> filtrarBuscaLocal(
  List<Map<String, dynamic>> linhas,
  String termo, {
  int limite = 20,
}) {
  // Cada palavra precisa aparecer no nome OU no código, em qualquer ordem —
  // a mesma regra da busca do galpão ('boral 20' acha 'BORAL 500 SC 20L').
  // Consulta vazia casa tudo (é como o pré-carregamento aquece o cache).
  final termos = termo
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  final resultado =
      linhas
          .where((r) {
            final nome = (r['produto_nome'] as String? ?? '').toLowerCase();
            final codigo = (r['produto_codigo'] as String? ?? '').toLowerCase();
            return termos.every((t) => nome.contains(t) || codigo.contains(t));
          })
          .toList()
        ..sort(
          (a, b) => (a['produto_nome'] as String? ?? '').compareTo(
            b['produto_nome'] as String? ?? '',
          ),
        );
  final vistos = <String>{};
  return resultado
      .where(
        (r) => vistos.add(
          jsonEncode([
            r['produto_codigo'],
            r['produto_nome'],
            r['gondola_num'],
            r['andar'],
            r['pos_x'],
            r['pos_z'],
            r['estante_num'],
            r['nivel'],
            r['posicao'],
            r['ordem'],
            r['id'],
            r['rotulo'],
          ]),
        ),
      )
      .take(limite)
      .toList();
}
