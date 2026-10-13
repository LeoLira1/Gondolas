// Monta os lotes SQL de gravação para a verificação em SQLite real
// (tool/verify_gravacao_sql.py). Sem Flutter e sem rede.
//
// Entrada (stdin): JSON {nome: operação}, cada operação no formato de
// OperacaoPendente.toJson. Saída (stdout): JSON {nome: texto do lote} e, em
// "__migracao_rack", os comandos da identidade do rack.
import 'dart:convert';
import 'dart:io';

import '../lib/gravacao_lote.dart';
import '../lib/rack_identity.dart';

Future<void> main() async {
  final entrada =
      jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  final saida = <String, Object>{
    '__migracao_rack': migracaoRackIdentidade,
    // O lote da abertura (TursoService._criarEsquema) num banco antigo, sem
    // a coluna, e num que já a tem.
    '__lote_rack_novo': textoDoLote([
      'ALTER TABLE galpao_racks ADD COLUMN rack_uuid TEXT',
      ...migracaoRackIdentidade,
    ]),
    '__lote_rack_existente': textoDoLote(migracaoRackIdentidade),
    '__seed_galpao': textoDoLote([comandoSeedGalpao()]),
  };
  for (final e in entrada.entries) {
    final op = OperacaoPendente.fromJson(
      Map<String, Object?>.from(e.value as Map),
    );
    if (op == null) throw StateError('operação ilegível: ${e.key}');
    saida[e.key as String] = textoDoLote(
      op.comandos(aplicadaEm: '2026-10-13T10:00:00', dispositivo: 'teste'),
    );
  }
  stdout.write(jsonEncode(saida));
}
