import 'dart:convert';

/// Filtra a cópia completa, não resultados guardados para um termo anterior.
/// Digitar um nome novo não precisa de uma nova consulta ao servidor.
List<Map<String, dynamic>> filtrarBuscaLocal(
  List<Map<String, dynamic>> linhas,
  String termo, {
  int limite = 20,
}) {
  final q = termo.trim().toLowerCase();
  final resultado =
      linhas
          .where(
            (r) =>
                (r['produto_nome'] as String? ?? '').toLowerCase().contains(
                  q,
                ) ||
                (r['produto_codigo'] as String? ?? '').toLowerCase().contains(
                  q,
                ),
          )
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
          ]),
        ),
      )
      .take(limite)
      .toList();
}
