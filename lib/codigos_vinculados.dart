// ─────────────────────────────────────────────────────────────────────────────
// Códigos que são o MESMO produto
// ─────────────────────────────────────────────────────────────────────────────
//
// O mesmo produto tem mais de um código no estoque_mestre — o do cadastro
// próprio e o da nota do fornecedor ('254185' e 'US254185'), cada um com sua
// linha e seu `qtd_sistema`. Quem lê um só vê metade do saldo: o galpão
// mostrava "sistema 388" para um produto que o app do scanner (LeoLira1/
// scanner, a leitura que o pessoal confere na mão) soma em 559 = 171 + 388.
//
// A regra reproduzida aqui é a do irmão, na mesma ordem:
//
//  1. `mapa_produtos` + `mapa_produtos_codigos` — o CADASTRO. Se o código
//     está vinculado a um produto_id, o grupo é o conjunto de códigos daquele
//     produto_id, e ponto.
//  2. Sem vínculo nenhum, o NOME. Nada de adivinhar o irmão por aritmética de
//     string (o prefixo 'US' não cobre o '100237191' do Ultimato): junta-se
//     quem tem exatamente a mesma [chaveNomeProduto]. Irmão que JÁ tem vínculo
//     no mapa fica de fora — o cadastro manda mais que o nome, e dois produtos
//     distintos podem compartilhar o texto de `produto`.
//
// Tudo aqui é função pura, sem banco: quem lê as tabelas é o GalpaoService.

const _comAcento = 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ';
const _semAcento = 'AAAAAEEEEIIIIOOOOOUUUUCNAAAAAEEEEIIIIOOOOOUUUUCN';

/// Nome de produto na forma em que dois cadastros são comparados: maiúsculo,
/// sem acento e com os espaços colapsados. Mesma chave do app do scanner.
String chaveNomeProduto(String texto) {
  final buffer = StringBuffer();
  for (final c in texto.trim().toUpperCase().split('')) {
    final i = _comAcento.indexOf(c);
    buffer.write(i >= 0 ? _semAcento[i] : c);
  }
  // Acento em forma decomposta (letra + marca combinante) não está na tabela
  // acima; a marca sai aqui.
  return buffer
      .toString()
      .replaceAll(RegExp('[\\u0300-\\u036F]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Código na forma canônica (UPPER(TRIM())), ou null quando não sobra nada.
/// Caixa e espaço não podem criar dois grupos para o mesmo código.
String? normalizarCodigo(String? codigo) {
  if (codigo == null) return null;
  final texto = codigo.trim().toUpperCase();
  return texto.isEmpty ? null : texto;
}

/// Para cada código de [codigos], o conjunto de códigos que somam com ele.
///
/// [produtoIdPorCodigo] é o cadastro do mapa (código → produto_id, já com os
/// secundários dentro); [nomePorCodigo] é o `produto` de cada linha do
/// estoque_mestre. As chaves das duas entram normalizadas ou não — a
/// normalização é feita aqui.
///
/// O grupo SEMPRE contém o próprio código, mesmo sem cadastro e sem irmão:
/// quem chama não precisa tratar caso vazio.
Map<String, Set<String>> gruposDeCodigos({
  required Iterable<String> codigos,
  required Map<String, String> produtoIdPorCodigo,
  required Map<String, String> nomePorCodigo,
}) {
  final porProdutoId = <String, String>{};
  final codigosDoProduto = <String, Set<String>>{};
  produtoIdPorCodigo.forEach((codigo, produtoId) {
    final c = normalizarCodigo(codigo);
    final p = produtoId.trim();
    if (c == null || p.isEmpty) return;
    porProdutoId[c] = p;
    codigosDoProduto.putIfAbsent(p, () => <String>{}).add(c);
  });

  final nomes = <String, String>{};
  nomePorCodigo.forEach((codigo, nome) {
    final c = normalizarCodigo(codigo);
    if (c != null) nomes[c] = nome;
  });

  final grupos = <String, Set<String>>{};
  for (final bruto in codigos) {
    final codigo = normalizarCodigo(bruto);
    if (codigo == null || grupos.containsKey(codigo)) continue;

    final produtoId = porProdutoId[codigo];
    if (produtoId != null) {
      grupos[codigo] = {codigo, ...?codigosDoProduto[produtoId]};
      continue;
    }

    // Fora do mapa: o nome é o que resta. Nome em branco fica sozinho —
    // somaria produtos sem relação nenhuma.
    final chave = chaveNomeProduto(nomes[codigo] ?? '');
    if (chave.isEmpty) {
      grupos[codigo] = {codigo};
      continue;
    }
    final grupo = <String>{codigo};
    nomes.forEach((outro, nome) {
      if (outro == codigo) return;
      if (porProdutoId.containsKey(outro)) return;
      if (chaveNomeProduto(nome) != chave) return;
      grupo.add(outro);
    });
    grupos[codigo] = grupo;
  }
  return grupos;
}
