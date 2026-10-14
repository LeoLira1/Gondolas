import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/badges_estoque.dart';

// Os selos das prateleiras saem das cópias de leitura, com a regra do JOIN que
// as consultas faziam (a paridade com o SQL antigo, em SQLite real, está em
// tool/verify_badges_sql.py). Aqui ficam as regras que a tela depende.

Map<String, dynamic> _endereco(
  String codigo,
  String atualizadoEm, {
  String tipo = 'gondola',
  int num = 1,
}) => {
  'produto_codigo': codigo,
  'local_tipo': tipo,
  'local_num': num,
  'face_ou_coluna': 1,
  'andar_ou_nivel': 0,
  'quantidade': 1,
  'atualizado_em': atualizadoEm,
};

void main() {
  group('desatualizados', () {
    test('endereço gravado antes da última contagem fica âmbar', () {
      final atrasados = calcularDesatualizados(
        enderecos: [
          _endereco('A', '2026-10-14T08:00:00'),
          _endereco('A', '2026-10-14T11:00:00', num: 2),
          _endereco('B', '2026-10-14T08:00:00'),
        ],
        ultimasContagens: [
          {'produto_codigo': 'A', 'ultima': '2026-10-14T10:00:00'},
        ],
      );
      expect(atrasados, hasLength(1));
      expect(atrasados.single.endereco['local_num'], 1);
      expect(atrasados.single.ultima, '2026-10-14T10:00:00');
    });

    test('as duas fontes contam, e vale o maior texto', () {
      final atrasados = calcularDesatualizados(
        enderecos: [_endereco('A', '2026-10-14T12:00:00')],
        ultimasContagens: [
          {'produto_codigo': 'A', 'ultima': '2026-10-14 15:00:00'},
          {'produto_codigo': 'A', 'ultima': '2026-10-14T09:00:00'},
        ],
      );
      // 'T' > ' ': o MAX de texto é o das 9h, e o endereço das 12h está em
      // dia — exatamente o que o SQL antigo dava.
      expect(atrasados, isEmpty);
    });

    test('código inteiro e data ilegível ficam de fora', () {
      final atrasados = calcularDesatualizados(
        enderecos: [
          _endereco('254185', '2026-10-01T00:00:00'),
          _endereco('B', 'ontem'),
        ],
        ultimasContagens: [
          {'produto_codigo': 254185, 'ultima': '2026-10-14T10:00:00'},
          {'produto_codigo': 'B', 'ultima': '2026-10-14T10:00:00'},
        ],
      );
      expect(atrasados, isEmpty);
    });
  });

  group('divergentes', () {
    test('todos os endereços do produto, e o positivo à parte', () {
      final r = calcularDivergentes(
        enderecos: [
          _endereco('MAIS', '2026-10-14T08:00:00'),
          _endereco('MAIS', '2026-10-14T08:00:00', tipo: 'galpao', num: 52),
          _endereco('MENOS', '2026-10-14T08:00:00'),
          _endereco('OK', '2026-10-14T08:00:00'),
        ],
        divergentesCiclo: [
          {'codigo': 'MAIS', 'qtd_contada_ciclo': 12, 'qtd_sistema_na_contagem': 10},
          {'codigo': 'MENOS', 'qtd_contada_ciclo': 8, 'qtd_sistema_na_contagem': 10},
        ],
      );
      expect(r.divergentes, hasLength(3));
      expect(r.positivas.map((e) => e['local_tipo']), ['gondola', 'galpao']);
    });

    test('código guardado como número casa pelo valor', () {
      final r = calcularDivergentes(
        enderecos: [
          _endereco('00123', '2026-10-14T08:00:00'),
          _endereco('123.0', '2026-10-14T08:00:00', num: 2),
          _endereco('124', '2026-10-14T08:00:00', num: 3),
        ],
        divergentesCiclo: [
          {'codigo': 123, 'qtd_contada_ciclo': 1, 'qtd_sistema_na_contagem': 2},
        ],
      );
      expect(r.divergentes.map((e) => e['local_num']), [1, 2]);
      expect(r.positivas, isEmpty);
    });
  });
}
