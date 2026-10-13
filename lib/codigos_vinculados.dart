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

/// As duas tabelas acima como mapa de code unit, montado uma vez.
/// [chaveNomeProduto] roda uma vez por linha do estoque_mestre a cada leitura
/// de saldo e a cada passada da baixa automática; procurar cada letra com
/// `indexOf` numa string de 48 caracteres custava mais que todo o resto da
/// função somado.
final Map<int, int> _semAcentoPorCodeUnit = {
  for (var i = 0; i < _comAcento.length; i++)
    _comAcento.codeUnitAt(i): _semAcento.codeUnitAt(i),
};

/// Compiladas uma vez, e não a cada chamada: `RegExp(...)` dentro da função
/// recompilava o padrão milhões de vezes por passada.
final RegExp _marcasCombinantes = RegExp('[\\u0300-\\u036F]');
final RegExp _espacosSeguidos   = RegExp(r'\s+');

/// Nome de produto na forma em que dois cadastros são comparados: maiúsculo,
/// sem acento e com os espaços colapsados. Mesma chave do app do scanner.
String chaveNomeProduto(String texto) {
  final cru = texto.trim().toUpperCase();
  final unidades = List<int>.filled(cru.length, 0);
  var temAcento = false;
  for (var i = 0; i < cru.length; i++) {
    final u = cru.codeUnitAt(i);
    final sem = _semAcentoPorCodeUnit[u];
    if (sem == null) {
      unidades[i] = u;
    } else {
      unidades[i] = sem;
      temAcento = true;
    }
  }
  final semAcento = temAcento ? String.fromCharCodes(unidades) : cru;
  // Acento em forma decomposta (letra + marca combinante) não está na tabela
  // acima; a marca sai aqui.
  return semAcento
      .replaceAll(_marcasCombinantes, '')
      .replaceAll(_espacosSeguidos, ' ')
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
///
/// O casamento por nome passa por um ÍNDICE `chave do nome → códigos`, montado
/// numa varredura só do estoque_mestre. A primeira versão comparava cada
/// código com cada nome (`nomes.forEach` dentro do laço dos códigos),
/// recalculando [chaveNomeProduto] a cada par: com os ~5000 nomes do catálogo
/// e os códigos de estoque_localizado isso dava milhões de chamadas, dezenas
/// de segundos travados na thread da interface — o "não está respondendo" ao
/// abrir o galpão. O índice deixa a conta em uma passada por lista.
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

  // Chave do nome → códigos que a têm. Só entra quem NÃO tem vínculo no mapa:
  // o cadastro manda mais que o nome, e quem já está vinculado nunca é irmão
  // por nome de ninguém.
  final chavePorCodigo = <String, String>{};
  final codigosPorChave = <String, Set<String>>{};
  nomes.forEach((codigo, nome) {
    if (porProdutoId.containsKey(codigo)) return;
    final chave = chaveNomeProduto(nome);
    // Nome em branco não junta nada: somaria produtos sem relação nenhuma.
    if (chave.isEmpty) return;
    chavePorCodigo[codigo] = chave;
    codigosPorChave.putIfAbsent(chave, () => <String>{}).add(codigo);
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

    // Fora do mapa: o nome é o que resta.
    final chave = chavePorCodigo[codigo];
    grupos[codigo] = chave == null
        ? {codigo}
        : {codigo, ...?codigosPorChave[chave]};
  }
  return grupos;
}
