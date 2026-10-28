// ─────────────────────────────────────────────────────────────────────────────
// Etiquetas dos VENDIDOS que ficam na loja (Zebra ZT410, 203 dpi, rolo 2-up)
// ─────────────────────────────────────────────────────────────────────────────
//
// Porte fiel da ferramenta `etiquetas_vendidos_loja` do MCP do camda-estoque
// (LeoLira1/camda-mcp, src/etiquetas.ts). Se a regra mudar lá, mude aqui
// também — a tela do app e a ferramenta têm que imprimir as MESMAS etiquetas.
//
// Tudo aqui é função pura, sem banco: quem lê as tabelas é o
// EtiquetasVendidosService.
//
// Regras:
//  - Vendas: `vendas_historico` (data_upload = dia da venda, qtd_vendida > 0).
//  - Onde fica: `gondola_layout` e `estante_layout`, com códigos irmãos
//    (gruposDeCodigos) e produto gravado no mapa com outro código mas mesmo
//    nome.
//  - Entra quem tem ao menos um lugar em G1–G12 ou numa estante/expositor que
//    não seja a 6 nem 13–18. Ilha (22), mostruário (23), paletes (101+),
//    estantes removidas e sem posição ficam de fora, com o motivo.
//  - Veterinário (pela categoria) nunca entra, esteja onde estiver.
//  - Um produto por linha; 1 comando ^XA…^XZ = 1 par de etiquetas.

import 'codigos_vinculados.dart';

const int gondolasLoja = 12;
const int etiquetaIlhaNum = 22;
const int etiquetaMostruarioNum = 23;
const int etiquetaPaleteNumMin = 101;
const int etiquetaNelloreNum = 19;

/// Estantes que ficam de fora da impressão: a 6 e as de parede (13–18).
const Set<int> estantesForaEtiqueta = {6, 13, 14, 15, 16, 17, 18};

/// Estantes que saíram da loja: linhas antigas ficam no banco.
const Set<int> estantesRemovidasEtiqueta = {3, 4};

/// Grupos veterinários do BI (bloco "Veterinários / medicamentos" de
/// CATEGORIAS_EXCLUIDAS_REPOSICAO no app_turso.py), sem acento.
const Set<String> categoriasVeterinarias = {
  'MEDICAMENTOS', 'MEDICAMENTOS VETERINARIOS',
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
};

/// Acima disso o texto não cabe nos ~350 pontos da etiqueta nem na menor fonte.
const int nomeEtiquetaMax = 26;

/// Palavras que não contam como "nome" na etiqueta.
const Set<String> _ignorar = {
  'DE', 'DA', 'DO', 'DAS', 'DOS', 'E', 'A', 'O', 'EM', 'COM', 'SEM', 'PARA',
  'P/', 'C/', 'S/',
};

final RegExp _comandoZpl = RegExp(r'[\^~]');
final RegExp _foraAscii = RegExp(r'[^\x20-\x7E]');
final RegExp _espacos = RegExp(r'\s+');
final RegExp _temLetraOuNumero = RegExp(r'[A-Z0-9]');
final RegExp _prefixoBarra = RegExp(r'^[CSP]/.');
final RegExp _numeracao = RegExp(r'^N\d+$');
final RegExp _bico = RegExp(r'(?:^|\s)([CS])/\s*BICO\b');
final RegExp _numero = RegExp(r'(?:^|\s)N\s?(\d+)\b');

/// Texto seguro para ^FD: sem acento, maiúsculo, sem ^ e ~ (comandos ZPL) e
/// só ASCII.
String textoZpl(String s) => chaveNomeProduto(s)
    .replaceAll(_comandoZpl, ' ')
    .replaceAll(_foraAscii, '')
    .replaceAll(_espacos, ' ')
    .trim();

/// Os dois primeiros nomes da descrição, sem DE/DA/DO/C//S/ e afins.
/// Com S/BICO ou C/BICO e/ou numeração (N39), vira primeiro nome + bico +
/// numeração: "BOTINA DE SEGURANCA S/BICO FUJIWARA PRETA N39" →
/// "BOTINA S/BICO N39".
String nomeEtiqueta(String descricao) {
  final texto = textoZpl(descricao);
  final palavras = texto
      .split(' ')
      .where((p) => _temLetraOuNumero.hasMatch(p))
      .where((p) =>
          !_ignorar.contains(p) &&
          !_prefixoBarra.hasMatch(p) &&
          !_numeracao.hasMatch(p))
      .toList();
  final bico = _bico.firstMatch(texto);
  final numero = _numero.firstMatch(texto);
  if (bico != null || numero != null) {
    return [
      if (palavras.isNotEmpty) palavras.first,
      if (bico != null) '${bico.group(1)}/BICO',
      if (numero != null) 'N${numero.group(1)}',
    ].join(' ');
  }
  return palavras.take(2).join(' ');
}

/// Fonte do nome (^A0) pelo nº de caracteres: até 11 = 52, 12–14 = 40,
/// 15–17 = 32, 18–21 = 26, acima = 22.
int fonteNomeVendidos(String nome) {
  final n = nome.length;
  if (n <= 11) return 52;
  if (n <= 14) return 40;
  if (n <= 17) return 32;
  if (n <= 21) return 26;
  return 22;
}

/// Fonte do código: 58, ou 44 com 8 caracteres ou mais.
int fonteCodigoVendidos(String codigo) => codigo.length >= 8 ? 44 : 58;

/// Mesmo produto nas duas etiquetas do par (x = 60 e x = 490). O nome menor
/// desce para ficar encostado no código, como no modelo de fonte 52
/// (y 40 → 92).
String zplVendido(String nome, String codigo) {
  final fn = fonteNomeVendidos(nome);
  final fc = fonteCodigoVendidos(codigo);
  final yn = 92 - fn;
  String um(int x) => '^FO$x,$yn^A0N,$fn,$fn^FD$nome^FS'
      '^FO$x,112^A0N,$fc,$fc^FD$codigo^FS';
  return '^XA^LS0^LH0,0^PW832${um(60)}${um(490)}^XZ';
}

/// Etiqueta do botão "Imprimir teste".
String zplTeste() => zplVendido('TESTE CAMDA', '123456');

bool ehVeterinario(String categoria) =>
    categoriasVeterinarias.contains(textoZpl(categoria));

/// codigoKey do MCP: trim, "nan" vira vazio, "123.0" vira "123", maiúsculo.
String codigoKey(Object? valor) {
  var s = (valor ?? '').toString().trim();
  if (s.isEmpty || s.toLowerCase() == 'nan') return '';
  if (RegExp(r'^\d+\.0+$').hasMatch(s)) s = s.split('.').first;
  return s.toUpperCase();
}

/// Um lugar do layout. [chave] identifica a célula (para não contar o mesmo
/// lugar duas vezes); [aviso] marca endereço antigo, fora do mapa.
class LocalEtiqueta {
  final String tipo; // 'gondola' | 'estante'
  final int num;
  final String chave;
  final String? aviso;

  const LocalEtiqueta(this.tipo, this.num, this.chave, {this.aviso});

  String get rotuloCurto => tipo == 'gondola' ? 'G$num' : 'E$num';

  int get ordem => (tipo == 'gondola' ? 0 : 1000) + num;
}

/// null = vale para impressão; texto = motivo de ficar de fora.
String? motivoFora(LocalEtiqueta l) {
  if (l.tipo == 'gondola') {
    return l.num >= 1 && l.num <= gondolasLoja
        ? null
        : 'gôndola ${l.num} (fora de G1–G$gondolasLoja)';
  }
  if (l.num == etiquetaIlhaNum) return 'ilha';
  if (l.num == etiquetaMostruarioNum) return 'mostruário';
  if (l.num >= etiquetaPaleteNumMin) return 'palete ${l.num}';
  if (estantesForaEtiqueta.contains(l.num)) return 'estante ${l.num}';
  if (l.aviso != null) return 'estante ${l.num} (${l.aviso})';
  return null;
}

class EtiquetaVendido {
  final String codigo;
  final String descricao;
  final int vendido;

  /// Rótulos curtos dos lugares que valem, ex.: "G3, E5".
  final String local;
  final String textoEtiqueta;
  final String zpl;

  const EtiquetaVendido({
    required this.codigo,
    required this.descricao,
    required this.vendido,
    required this.local,
    required this.textoEtiqueta,
    required this.zpl,
  });
}

class ForaDaEtiqueta {
  final String codigo;
  final String descricao;
  final String motivo;

  const ForaDaEtiqueta(this.codigo, this.descricao, this.motivo);
}

class ResultadoEtiquetasVendidos {
  final int produtosVendidos;
  final List<EtiquetaVendido> produtos;
  final List<ForaDaEtiqueta> fora;
  final List<String> avisos;

  const ResultadoEtiquetasVendidos({
    required this.produtosVendidos,
    required this.produtos,
    required this.fora,
    required this.avisos,
  });
}

class _Item {
  final String codigo;
  final String descricao;
  final String categoria;
  int vendido;
  final List<LocalEtiqueta> locais;

  _Item(this.codigo, this.descricao, this.categoria, this.vendido, this.locais);
}

String _s(Object? v) => v == null ? '' : v.toString();
int _i(Object? v) => v is num ? v.toInt() : int.tryParse(_s(v)) ?? 0;
double _d(Object? v) => v is num ? v.toDouble() : double.tryParse(_s(v)) ?? 0;

/// Monta a lista de etiquetas a partir das linhas cruas do banco.
///
/// [vendas]: codigo, produto, grupo, qtd (uma linha por código, já somada e
/// ordenada por código). [produtos]: estoque_mestre (codigo, produto,
/// categoria). [vinculosMapa]: mapa_produtos + mapa_produtos_codigos
/// (codigo, produto_id). [gondolas]: gondola_layout (produto_codigo,
/// produto_nome, gondola_num, andar, pos_x, pos_z). [estantes]: estante_layout
/// (produto_codigo, produto_nome, estante_num, coluna, nivel).
ResultadoEtiquetasVendidos montarEtiquetasVendidos({
  required List<Map<String, dynamic>> vendas,
  required List<Map<String, dynamic>> produtos,
  required List<Map<String, dynamic>> vinculosMapa,
  required List<Map<String, dynamic>> gondolas,
  required List<Map<String, dynamic>> estantes,
}) {
  final porCod = <String, Map<String, dynamic>>{
    for (final p in produtos) codigoKey(p['codigo']): p,
  };

  // ── códigos irmãos (mesma regra do resto do app) ──
  final produtoIdPorCodigo = <String, String>{
    for (final v in vinculosMapa) _s(v['codigo']): _s(v['produto_id']),
  };
  final nomePorCodigo = <String, String>{
    for (final p in produtos) _s(p['codigo']): _s(p['produto']),
  };
  final grupos = gruposDeCodigos(
    codigos: vendas.map((r) => codigoKey(r['codigo'])).where((c) => c.isNotEmpty),
    produtoIdPorCodigo: produtoIdPorCodigo,
    nomePorCodigo: nomePorCodigo,
  );

  // ── layout: código e chave do nome → locais ──
  final locaisPorCodigo = <String, List<LocalEtiqueta>>{};
  final locaisPorNome = <String, List<LocalEtiqueta>>{};
  void add(Object? cod, Object? nome, LocalEtiqueta l) {
    final c = codigoKey(cod);
    if (c.isEmpty || c.startsWith('EST:')) return;
    locaisPorCodigo.putIfAbsent(c, () => []).add(l);
    final k = chaveNomeProduto(_s(nome));
    if (k.isNotEmpty) locaisPorNome.putIfAbsent(k, () => []).add(l);
  }

  for (final r in gondolas) {
    final n = _i(r['gondola_num']);
    add(
      r['produto_codigo'],
      r['produto_nome'],
      LocalEtiqueta('gondola', n,
          'G$n·${_i(r['andar'])}·${_d(r['pos_x'])}·${_d(r['pos_z'])}'),
    );
  }
  for (final r in estantes) {
    final n = _i(r['estante_num']);
    final col = _i(r['coluna']);
    final nivel = _i(r['nivel']);
    String? aviso;
    if (n != etiquetaIlhaNum &&
        n != etiquetaMostruarioNum &&
        n < etiquetaPaleteNumMin) {
      if (estantesRemovidasEtiqueta.contains(n)) {
        aviso = 'estante removida da loja: endereço antigo, recadastrar';
      } else if (n == etiquetaNelloreNum && nivel == 0) {
        aviso = 'base antiga do Nellore, fora do mapa: endereço antigo';
      }
    }
    add(r['produto_codigo'], r['produto_nome'],
        LocalEtiqueta('estante', n, 'E$n·$col·$nivel', aviso: aviso));
  }

  // ── um item por produto (códigos irmãos juntos) ──
  final itens = <_Item>[];
  final itemDoCodigo = <String, _Item>{};
  for (final r in vendas) {
    final cod = codigoKey(r['codigo']);
    if (cod.isEmpty) continue;
    final qtd = _i(r['qtd']);
    final ja = itemDoCodigo[cod];
    if (ja != null) {
      ja.vendido += qtd;
      continue;
    }
    final grupo = grupos[cod] ?? {cod};
    final produtoVenda = _s(r['produto']);
    final nomeMestre = _s(porCod[cod]?['produto']);
    var descricao = (nomeMestre.isNotEmpty ? nomeMestre : produtoVenda).trim();
    if (descricao.isEmpty) descricao = cod;

    final nomes = <String>{
      for (final n in [
        ...grupo.map((c) => _s(porCod[c]?['produto'])),
        produtoVenda,
      ])
        if (n.isNotEmpty) chaveNomeProduto(n),
    }..remove('');

    final vistos = <String>{};
    final locais = <LocalEtiqueta>[];
    for (final l in [
      ...grupo.expand((c) => locaisPorCodigo[c] ?? const <LocalEtiqueta>[]),
      ...nomes.expand((n) => locaisPorNome[n] ?? const <LocalEtiqueta>[]),
    ]) {
      if (vistos.add(l.chave)) locais.add(l);
    }

    // categoria do código vendido; sem cadastro, a de um irmão ou o grupo da venda
    var categoria = _s(porCod[cod]?['categoria']);
    if (categoria.isEmpty) {
      categoria = grupo
          .map((c) => _s(porCod[c]?['categoria']))
          .firstWhere((c) => c.isNotEmpty, orElse: () => _s(r['grupo']));
    }

    final item = _Item(
        _s(r['codigo']).trim(), descricao, categoria.trim(), qtd, locais);
    itens.add(item);
    for (final c in grupo) {
      itemDoCodigo[c] = item;
    }
  }

  final imprimir = <(EtiquetaVendido, int)>[];
  final deFora = <ForaDaEtiqueta>[];
  final avisos = <String>[];
  for (final it in itens) {
    if (ehVeterinario(it.categoria)) {
      deFora.add(ForaDaEtiqueta(it.codigo, it.descricao, 'veterinário'));
      continue;
    }
    final validos = it.locais.where((l) => motivoFora(l) == null).toList()
      ..sort((a, b) {
        final o = a.ordem.compareTo(b.ordem);
        return o != 0 ? o : a.chave.compareTo(b.chave);
      });
    if (validos.isEmpty) {
      final motivos = {for (final l in it.locais) motivoFora(l)!};
      deFora.add(ForaDaEtiqueta(it.codigo, it.descricao,
          motivos.isEmpty ? 'sem posição' : motivos.join(', ')));
      continue;
    }
    final codigo = textoZpl(it.codigo);
    var nome = nomeEtiqueta(it.descricao);
    if (nome.isEmpty) nome = codigo;
    if (nome.length > nomeEtiquetaMax) {
      avisos.add('${it.codigo}: nome da etiqueta cortado em $nomeEtiquetaMax '
          'letras ("$nome") para caber.');
      nome = nome.substring(0, nomeEtiquetaMax).trim();
    }
    imprimir.add((
      EtiquetaVendido(
        codigo: it.codigo,
        descricao: it.descricao,
        vendido: it.vendido,
        local: {for (final l in validos) l.rotuloCurto}.join(', '),
        textoEtiqueta: nome,
        zpl: zplVendido(nome, codigo),
      ),
      validos.first.ordem,
    ));
  }
  imprimir.sort((a, b) {
    final o = a.$2.compareTo(b.$2);
    return o != 0 ? o : a.$1.descricao.compareTo(b.$1.descricao);
  });
  deFora.sort((a, b) {
    final o = a.motivo.compareTo(b.motivo);
    return o != 0 ? o : a.descricao.compareTo(b.descricao);
  });

  final porTexto = <String, List<String>>{};
  for (final (p, _) in imprimir) {
    porTexto.putIfAbsent(p.textoEtiqueta, () => []).add(p.codigo);
  }
  porTexto.forEach((texto, cods) {
    if (cods.length > 1) {
      avisos.add('Etiqueta "$texto" igual em ${cods.length} produtos: '
          '${cods.join(', ')} (o código diferencia).');
    }
  });
  for (final (p, _) in imprimir) {
    if (p.zpl.length > 250) {
      avisos.add('${p.codigo}: comando com ${p.zpl.length} caracteres '
          '(acima de 250).');
    }
  }

  return ResultadoEtiquetasVendidos(
    produtosVendidos: itens.length,
    produtos: [for (final (p, _) in imprimir) p],
    fora: deFora,
    avisos: avisos,
  );
}
