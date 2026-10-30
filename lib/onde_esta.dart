import 'package:flutter/material.dart';

import 'codigos_vinculados.dart';
import 'models.dart';
import 'turso_service.dart';

/// Abre a estrutura de um endereço achado (gôndola, estante, galpão…), com o
/// produto aceso. Quem chama é o mapa da loja (ver abrirEnderecoNoMapa em
/// main.dart); as telas de Etiquetas e Repor loja recebem por parâmetro para
/// não importar o main.dart.
typedef AbrirEndereco = Future<void> Function(
    BuildContext context, ProdutoEncontrado endereco);

/// Endereços de [resultados] que são do produto: o código gravado é um dos
/// [codigos] (o próprio e os irmãos do mapa de produtos). Sem nenhum, vale o
/// nome igual (sem acento, maiúsculas, espaços juntos) — produto gravado no
/// mapa com outro código.
///
/// A busca global casa PEDAÇO do código ('47279' acha '147279'), por isso o
/// filtro exato aqui.
List<ProdutoEncontrado> enderecosDoProduto(
  Iterable<ProdutoEncontrado> resultados, {
  required Set<String> codigos,
  required String nome,
}) {
  final porCodigo = [
    for (final r in resultados)
      if (codigos.contains(normalizarCodigo(r.produtoCodigo))) r,
  ];
  final chave = chaveNomeProduto(nome);
  final lista = porCodigo.isNotEmpty || chave.isEmpty
      ? porCodigo
      : [
          for (final r in resultados)
            if (chaveNomeProduto(r.nome) == chave) r,
        ];
  // A mesma linha pode vir de duas buscas (um código e um irmão).
  final vistos = <String>{};
  return [
    for (final r in lista)
      if (vistos.add('${r.tipo}|${r.numero}|${r.nivelDescricao}|'
          '${normalizarCodigo(r.produtoCodigo)}'))
        r,
  ];
}

/// Texto do endereço, igual ao das sugestões da busca do mapa:
/// "Gôndola nº 3 · Face 1 · Andar Base", "Galpão nº 52 · …".
String rotuloEndereco(ProdutoEncontrado p) {
  if (p.tipo == localTipoBarracao) return 'Barracão · ${p.nivelDescricao}';
  final nome = p.tipo == 'gondola'
      ? 'Gôndola'
      : p.tipo == localTipoGalpao
          ? 'Galpão'
          : ehPalete(p.numero)
              ? 'Palete'
              : ehIlhaPaletes(p.numero)
                  ? 'Ilha de paletes'
                  : ehMostruario(p.numero)
                      ? 'Mostruário'
                      : 'Estante';
  final numero =
      ehIlhaPaletes(p.numero) || ehMostruario(p.numero) ? '' : ' nº ${p.numero}';
  return '$nome$numero · ${p.nivelDescricao}';
}

/// Loja primeiro (gôndolas, estantes), depois galpão e barracão.
int _ordem(ProdutoEncontrado p) => switch (p.tipo) {
      'gondola' => 0,
      'estante' => 1,
      localTipoGalpao => 2,
      localTipoBarracao => 3,
      _ => 4,
    };

/// Procura o produto em todos os mapas pelo código e pelos códigos irmãos
/// (mapa_produtos), e pelo nome quando nenhum código casa.
Future<List<ProdutoEncontrado>> buscarEnderecosDoProduto({
  required String codigo,
  required String nome,
}) async {
  final turso = TursoService();
  final principal = normalizarCodigo(codigo);
  final codigos = <String>{if (principal != null) principal};
  if (principal != null) {
    final vinculos = await turso.vinculosDoMapa();
    final produtoId = vinculos[principal];
    if (produtoId != null) {
      vinculos.forEach((c, p) {
        if (p == produtoId) codigos.add(c);
      });
    }
  }

  final resultados = <ProdutoEncontrado>[
    for (final c in codigos) ...await turso.buscarProdutoGlobal(c),
  ];
  var achados =
      enderecosDoProduto(resultados, codigos: codigos, nome: nome);
  if (achados.isEmpty && nome.trim().length >= 2) {
    achados = enderecosDoProduto(
      await turso.buscarProdutoGlobal(nome),
      codigos: codigos,
      nome: nome,
    );
  }
  achados.sort((a, b) => _ordem(a).compareTo(_ordem(b)));
  return achados;
}

/// Toque no nome do produto: um endereço abre direto; dois ou mais abrem uma
/// lista para escolher; nenhum avisa.
Future<void> mostrarOndeEsta(
  BuildContext context, {
  required String codigo,
  required String nome,
  required AbrirEndereco abrir,
  Future<List<ProdutoEncontrado>> Function()? buscar,
}) async {
  final mensageiro = ScaffoldMessenger.of(context);
  mensageiro
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text('Procurando $nome…'),
      duration: const Duration(seconds: 20),
    ));
  List<ProdutoEncontrado> enderecos;
  try {
    enderecos = await (buscar ??
        () => buscarEnderecosDoProduto(codigo: codigo, nome: nome))();
  } catch (e) {
    mensageiro
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Não consegui procurar: $e')));
    return;
  }
  mensageiro.hideCurrentSnackBar();
  if (!context.mounted) return;

  if (enderecos.isEmpty) {
    mensageiro.showSnackBar(SnackBar(
      content: Text('$nome ($codigo) não tem endereço no mapa.'),
    ));
    return;
  }
  if (enderecos.length == 1) {
    await abrir(context, enderecos.first);
    return;
  }

  final escolhido = await showModalBottomSheet<ProdutoEncontrado>(
    context: context,
    backgroundColor: const Color(0xFF161a20),
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(nome,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                  '$codigo · ${enderecos.length} endereços — '
                  'toque para ver no mapa',
                  style: const TextStyle(
                      color: Color(0xFF8a9aa8), fontSize: 12)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final e in enderecos)
                    ListTile(
                      leading: Icon(
                        e.tipo == localTipoGalpao ||
                                e.tipo == localTipoBarracao
                            ? Icons.warehouse_outlined
                            : Icons.storefront_outlined,
                        color: const Color(0xFF8a9aa8),
                      ),
                      title: Text(rotuloEndereco(e)),
                      trailing: e.quantidade == null
                          ? null
                          : Text(
                              '${_fmtQtd(e.quantidade!)} un',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                            ),
                      onTap: () => Navigator.pop(ctx, e),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (escolhido != null && context.mounted) await abrir(context, escolhido);
}

String _fmtQtd(double q) =>
    q == q.roundToDouble() ? q.round().toString() : q.toString();
