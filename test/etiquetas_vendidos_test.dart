// Mesmos casos de test/etiquetas.test.ts do LeoLira1/camda-mcp
// (etiquetas_vendidos_loja): a tela do app tem que imprimir exatamente as
// etiquetas que a ferramenta gera.

import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/etiquetas_vendidos.dart';
import 'package:gondola_camda/etiquetas_vendidos_service.dart';

Map<String, dynamic> _p(String codigo, String produto, String categoria) =>
    {'codigo': codigo, 'produto': produto, 'categoria': categoria};

Map<String, dynamic> _g(int num, int andar, String cod, String nome,
        double x, double z) =>
    {
      'gondola_num': num, 'andar': andar, 'produto_codigo': cod,
      'produto_nome': nome, 'pos_x': x, 'pos_z': z,
    };

Map<String, dynamic> _e(int num, int col, int nivel, String cod, String nome) =>
    {
      'estante_num': num, 'coluna': col, 'nivel': nivel,
      'produto_codigo': cod, 'produto_nome': nome,
    };

void main() {
  test('nome da etiqueta: dois primeiros nomes, bico e numeração', () {
    expect(nomeEtiqueta('ÓLEO DE SOJA C/ ADITIVO 4X5L'), 'OLEO SOJA');
    expect(nomeEtiqueta('SERINGA C/50 DESCARTÁVEL'), 'SERINGA DESCARTAVEL');
    expect(nomeEtiqueta('BOTINA DE SEGURANCA S/BICO FUJIWARA PRETA N39'),
        'BOTINA S/BICO N39');
    expect(nomeEtiqueta('BOTINA C/ BICO DE AÇO Nº 42'), 'BOTINA C/BICO N42');
    expect(nomeEtiqueta('BOTA PVC BRANCA N40'), 'BOTA N40');
    expect(nomeEtiqueta('BOTINA S/BICO PRETA'), 'BOTINA S/BICO');
    expect(nomeEtiqueta('NEXIDE NOVO 1L'), 'NEXIDE NOVO');
  });

  test('ZPL dos vendidos: modelo base e fontes por tamanho', () {
    expect(
      zplVendido('NOME', 'CODIGO'),
      '^XA^LS0^LH0,0^PW832^FO60,40^A0N,52,52^FDNOME^FS^FO60,112^A0N,58,58'
      '^FDCODIGO^FS^FO490,40^A0N,52,52^FDNOME^FS^FO490,112^A0N,58,58'
      '^FDCODIGO^FS^XZ',
    );
    expect([11, 12, 14, 15, 17, 18, 21, 22]
        .map((n) => fonteNomeVendidos('A' * n)),
        [52, 40, 40, 32, 32, 26, 26, 22]);
    expect(fonteCodigoVendidos('1234567'), 58);
    expect(fonteCodigoVendidos('12345678'), 44);
    expect(zplVendido('A' * 26, 'US10047813').length, lessThanOrEqualTo(250));
  });

  test('vendidos na loja: só G1–G12 e estantes fora da 6 e 13–18, '
      'sem veterinários, irmãos juntos', () {
    final produtos = [
      _p('2001', 'BICO DE MAMADEIRA HOPPNER', 'VET'),
      _p('2002', 'BAIXEIRO DE FELTRO C/LONA', 'SELARIA'),
      _p('2003', 'LONA PE 6X4M CARGA PESADA LEVE', 'FERRAGEM'),
      _p('2004', 'ÓLEO MINERAL PARA MOTOR 1L', 'OUTROS'),
      _p('2005', 'CORDA DE NYLON 10MM', 'FERRAGEM'),
      _p('2006', 'ARAME FARPADO 500M', 'FERRAGEM'),
      _p('2007', 'CADEADO 30MM', 'FERRAGEM'),
      _p('2008', 'SEMENTE MILHO', 'SEMENTES'),
      _p('47813', 'FUNGICIDA NATIVO 20L', 'FUNGICIDA'),
      _p('US10047813', 'FUNGICIDA  NATIVO 20L', 'FUNGICIDA'),
      _p('12345678', 'ANTIPULGAS INJETAVEL', 'VET'),
      _p('3001', 'IVOMEC GOLD 50ML', 'VERMIFUGOS'),
      _p('3002', 'PENTABIOTICO VETERINARIO', 'MEDICAMENTOS VETERINÁRIOS'),
      _p('3003', 'TORNEIRA PLASTICA 1/2', 'FERRAGEM'),
    ];
    final gondolas = [
      _g(9, 2, '2003', 'LONA PE 6X4M CARGA PESADA LEVE', 0, 1),
      _g(1, 0, '2001', 'BICO DE MAMADEIRA HOPPNER', 0, 1),
      _g(1, 1, '2001', 'BICO DE MAMADEIRA HOPPNER', 0, -1),
      _g(5, 0, 'US10047813', 'FUNGICIDA NATIVO 20L', 0, 1),
      _g(2, 0, '3001', 'IVOMEC GOLD 50ML', 0, 1),
    ];
    final estantes = [
      _e(14, 0, 0, '2002', 'BAIXEIRO DE FELTRO C/LONA'),
      _e(5, 1, 2, '2002', 'BAIXEIRO DE FELTRO C/LONA'),
      _e(13, 0, 0, '2004', 'OLEO MINERAL PARA MOTOR 1L'),
      _e(18, 0, 0, '2004', 'OLEO MINERAL PARA MOTOR 1L'),
      _e(22, 0, 3, '2005', 'CORDA DE NYLON 10MM'),
      _e(101, 0, 0, '2006', 'ARAME FARPADO 500M'),
      _e(23, 0, 1, '2007', 'CADEADO 30MM'),
      _e(24, 0, 0, '12345678', 'ANTIPULGAS INJETAVEL'),
      _e(7, 0, 0, '3002', 'PENTABIOTICO VETERINARIO'),
      _e(6, 1, 1, '3003', 'TORNEIRA PLASTICA 1/2'),
    ];
    // Já agrupado por código e ordenado, como a consulta do serviço devolve.
    final codigos = [
      '12345678', '2001', '2002', '2003', '2004', '2005', '2006', '2007',
      '2008', '3001', '3002', '3003', '47813', 'US10047813',
    ];
    final vendas = [
      for (final c in codigos)
        {'codigo': c, 'produto': c, 'grupo': 'X', 'qtd': c == 'US10047813' ? 2 : 3},
    ];

    final r = montarEtiquetasVendidos(
      vendas: vendas,
      produtos: produtos,
      vinculosMapa: const [],
      gondolas: gondolas,
      estantes: estantes,
    );

    expect(r.produtos.map((p) => [p.codigo, p.local, p.textoEtiqueta]), [
      ['2001', 'G1', 'BICO MAMADEIRA'],
      ['47813', 'G5', 'FUNGICIDA NATIVO'],
      ['2003', 'G9', 'LONA PE'],
      ['2002', 'E5', 'BAIXEIRO FELTRO'], // também está na E14, mas a E5 vale
      ['12345678', 'E24', 'ANTIPULGAS INJETAVEL'],
    ]);
    expect(r.produtos[1].vendido, 5);
    expect({for (final f in r.fora) f.codigo: f.motivo}, {
      '2004': 'estante 13, estante 18',
      '2005': 'ilha',
      '2006': 'palete 101',
      '2007': 'mostruário',
      '2008': 'sem posição',
      '3001': 'veterinário',
      '3002': 'veterinário',
      '3003': 'estante 6',
    });
    for (final p in r.produtos) {
      expect(p.zpl.length, lessThanOrEqualTo(250));
      expect(p.zpl, startsWith('^XA^LS0^LH0,0^PW832'));
      expect(p.zpl, endsWith('^XZ'));
    }
  });

  test('irmão pelo cadastro do mapa e estante removida', () {
    final r = montarEtiquetasVendidos(
      vendas: [
        {'codigo': '276517', 'produto': 'PRIORI XTRA', 'grupo': 'X', 'qtd': 1},
        {'codigo': '9001', 'produto': 'PREGO 17X21', 'grupo': 'X', 'qtd': 1},
      ],
      produtos: [
        _p('276517', 'PRIORI XTRA 1L', 'FUNGICIDA'),
        _p('56189', 'FUNGICIDA PRIORI XTRA', 'FUNGICIDA'),
        _p('9001', 'PREGO 17X21', 'FERRAGEM'),
      ],
      vinculosMapa: [
        {'codigo': '276517', 'produto_id': 'p1'},
        {'codigo': '56189', 'produto_id': 'p1'},
      ],
      gondolas: [_g(3, 1, '56189', 'FUNGICIDA PRIORI XTRA', 1, 0)],
      estantes: [_e(4, 0, 0, '9001', 'PREGO 17X21')],
    );
    expect(r.produtos.map((p) => '${p.codigo} ${p.local}'), ['276517 G3']);
    expect(r.fora.single.motivo, startsWith('estante 4 (estante removida'));
  });

  test('hoje em Brasília independe do fuso do aparelho', () {
    // 02:30 UTC do dia 29 ainda é dia 28 em Brasília.
    expect(
      EtiquetasVendidosService.dataIso(EtiquetasVendidosService.hojeBrasilia(
          DateTime.utc(2026, 10, 29, 2, 30))),
      '2026-10-28',
    );
  });
}
