// ─────────────────────────────────────────────────────────────────────────────
// Selos das prateleiras: endereço desatualizado (âmbar) e divergente (vermelho
// ou azul escuro), calculados a partir das cópias de leitura.
// ─────────────────────────────────────────────────────────────────────────────
//
// Antes cada selo era uma consulta: o âmbar juntava estoque_localizado com o
// MAX das contagens de inventario_cicli e contagem_itens; o divergente juntava
// estoque_localizado com estoque_mestre. As duas varriam tabelas inteiras — e
// rodavam forçadas a cada dataRevision, a cada linha salva no diálogo, em cada
// tela empilhada. Era o maior consumo de rows read da loja.
//
// Agora o app guarda as três partes como cópias (as quantidades, a última
// contagem de cada produto em cada fonte e os produtos divergentes do ciclo),
// e as funções abaixo fazem o JOIN em Dart, com a MESMA regra do SQL antigo.
// tool/verify_badges_sql.py roda o SQL antigo num SQLite de verdade contra
// elas. Sem Flutter e sem banco, de propósito: é o que deixa conferir assim.

/// Última contagem de cada produto no inventário cíclico.
const String sqlUltimaContagemCiclico =
    'SELECT produto_id AS produto_codigo, MAX(contado_em) AS ultima '
    'FROM inventario_cicli WHERE contado_em IS NOT NULL GROUP BY produto_id';

/// Última contagem CONFIRMADA de cada código no app de contagem, pela coluna
/// de confirmação que existir no banco (`confirmado_em` ou `registrado_em`).
String sqlUltimaContagemItens(String coluna) =>
    'SELECT codigo AS produto_codigo, MAX($coluna) AS ultima '
    'FROM contagem_itens '
    "WHERE status != 'pendente' AND $coluna IS NOT NULL GROUP BY codigo";

/// Produtos com divergência no ciclo.
const String sqlDivergentesCiclo =
    'SELECT codigo, qtd_contada_ciclo, qtd_sistema_na_contagem '
    "FROM estoque_mestre WHERE status_ciclo = 'divergencia'";

/// Um endereço desatualizado: a linha de estoque_localizado e a contagem mais
/// nova que ele perdeu.
typedef EnderecoAtrasado = ({Map<String, dynamic> endereco, String ultima});

/// Os endereços gravados ANTES da última contagem confirmada do produto.
///
/// [enderecos] são linhas de estoque_localizado (`produto_codigo`,
/// `atualizado_em` e o endereço). [ultimasContagens] são as linhas
/// `produto_codigo`, `ultima` das duas fontes juntas (o MAX por produto de
/// inventario_cicli e de contagem_itens).
///
/// Reproduz o SQL de antes, detalhe por detalhe (conferido em SQLite real):
/// - o MAX é de TEXTO (`'2026-10-14T09:00'` vence `'2026-10-14 15:00'`, porque
///   `T` vem depois do espaço) — datas em formatos diferentes no mesmo produto
///   dão o resultado que o SQLite dava;
/// - o código casa pelo texto exato; um `produto_id` guardado como INTEIRO
///   nunca casava (a subconsulta agrupada não converte o tipo), então fica
///   de fora;
/// - as datas são comparadas por [DateTime.tryParse], e data ilegível tira o
///   endereço da conta.
List<EnderecoAtrasado> calcularDesatualizados({
  required Iterable<Map<String, dynamic>> enderecos,
  required Iterable<Map<String, dynamic>> ultimasContagens,
}) {
  // código → maior `ultima`, em texto
  final maximos = <String, String>{};
  for (final r in ultimasContagens) {
    final codigo = r['produto_codigo'];
    final ultima = r['ultima'];
    if (codigo is! String || ultima is! String) continue;
    final atual = maximos[codigo];
    if (atual == null || ultima.compareTo(atual) > 0) maximos[codigo] = ultima;
  }

  final atrasados = <EnderecoAtrasado>[];
  for (final r in enderecos) {
    final codigo = r['produto_codigo'];
    final atualizadoEm = r['atualizado_em'];
    if (codigo is! String || atualizadoEm is! String) continue;
    final ultima = maximos[codigo];
    if (ultima == null) continue;
    final dtAtual = DateTime.tryParse(atualizadoEm);
    final dtUltima = DateTime.tryParse(ultima);
    if (dtAtual == null || dtUltima == null) continue;
    if (dtAtual.isBefore(dtUltima)) {
      atrasados.add((endereco: r, ultima: ultima));
    }
  }
  return atrasados;
}

/// Os endereços de produtos com divergência no ciclo, e o subconjunto em que
/// a divergência é POSITIVA (contou-se mais do que o sistema tinha).
///
/// [divergentesCiclo] são as linhas `codigo`, `qtd_contada_ciclo`,
/// `qtd_sistema_na_contagem` de estoque_mestre com
/// `status_ciclo = 'divergencia'`. Como a divergência é do produto, todos os
/// endereços dele entram — inclusive os de galpão, como antes.
///
/// O código casa como no JOIN antigo (conferido em SQLite real): código em
/// texto, pelo texto exato; código guardado como número (coluna INTEGER),
/// pelo valor numérico do código do endereço (`'00123'` casa com `123`).
({
  List<Map<String, dynamic>> divergentes,
  List<Map<String, dynamic>> positivas,
}) calcularDivergentes({
  required Iterable<Map<String, dynamic>> enderecos,
  required Iterable<Map<String, dynamic>> divergentesCiclo,
}) {
  final porTexto = <String, List<Map<String, dynamic>>>{};
  final porNumero = <double, List<Map<String, dynamic>>>{};
  for (final d in divergentesCiclo) {
    final codigo = d['codigo'];
    if (codigo is String) {
      porTexto.putIfAbsent(codigo, () => []).add(d);
    } else if (codigo is num) {
      porNumero.putIfAbsent(codigo.toDouble(), () => []).add(d);
    }
  }

  final divergentes = <Map<String, dynamic>>[];
  final positivas = <Map<String, dynamic>>[];
  for (final r in enderecos) {
    final codigo = r['produto_codigo'];
    if (codigo is! String) continue;
    final comoNumero = porNumero.isEmpty
        ? null
        : double.tryParse(codigo.trim());
    final linhas = [
      ...?porTexto[codigo],
      if (comoNumero != null) ...?porNumero[comoNumero],
    ];
    if (linhas.isEmpty) continue;
    divergentes.add(r);
    if (linhas.any((d) {
      final contada = (d['qtd_contada_ciclo'] as num?)?.toDouble();
      final sistema = (d['qtd_sistema_na_contagem'] as num?)?.toDouble();
      return contada != null && sistema != null && contada > sistema;
    })) {
      positivas.add(r);
    }
  }
  return (divergentes: divergentes, positivas: positivas);
}
