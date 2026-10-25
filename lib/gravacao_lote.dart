import 'dart:async';
import 'dart:convert';

import 'barracao_config.dart';
import 'galpao_config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Gravação em UMA requisição — o caminho rápido para internet ruim
// ─────────────────────────────────────────────────────────────────────────────
//
// Por que existe. A gravação do galpão era uma transação interativa: BEGIN, e
// cada SELECT/INSERT/UPDATE uma ida ao Turso, esperando a volta para mandar o
// próximo. Pior: o libsql_dart prepara toda consulta com um `describe` antes
// de rodá-la, então cada SELECT custava DUAS idas. Contado no código, um
// lançamento de rack eram ~17 idas e voltas em fila. Na rede da loja, com 1 s
// de latência, isso é ~17 s de "Gravando no banco online…" — e a transação
// aberta no servidor no meio disso tudo expirava, o que era o "às vezes nem
// lança".
//
// Agora a gravação inteira vira um texto SQL só, mandado num pipeline Hrana
// único (`LibsqlClient.batch` → `execute_batch` do libsql): uma ida e uma
// volta. O servidor roda tudo em sequência, dentro de BEGIN IMMEDIATE …
// COMMIT, em milissegundos.
//
// O que isso exige do SQL, e por quê:
//
// - **Sem parâmetros.** O `batch` do libsql_dart não aceita `?`. Os valores
//   entram como literais, sempre por [sqlTexto] / [sqlNumero] — nunca por
//   interpolação crua. Aspas simples são dobradas (é o único escape de string
//   do SQLite) e número não finito é recusado.
//
// - **Atômico mesmo quando falha no meio.** Cada passo do lote só roda se o
//   anterior deu certo (o libsql monta o pipeline assim). Um erro no meio pula
//   o resto, inclusive o COMMIT, e o stream é fechado na mesma requisição — o
//   servidor descarta a transação aberta. Ou grava tudo, ou nada.
//
// - **Idempotente pelo UUID.** Todo comando de escrita leva
//   `NOT EXISTS (… app_mutacoes_aplicadas WHERE uuid = …)`, e o carimbo do
//   UUID é o último passo antes do COMMIT. Se a resposta se perde no caminho
//   (o caso típico da rede da loja: o servidor gravou, o celular não ouviu),
//   reenviar o MESMO lote não faz nada — e é por isso que a fila pode
//   reenviar sozinha, sem perguntar a ninguém.
//
// - **Conflito vira erro com nome.** Fora de trigger o SQLite não tem RAISE.
//   O lote aborta de propósito avaliando `json_extract('{}', '<marcador>')`,
//   cujo erro ("bad JSON path: '<marcador>'") carrega o nosso texto. É o que
//   separa "a pilha encheu enquanto você estava offline" (não adianta
//   reenviar) de "a rede caiu" (reenviar resolve) — ver
//   [classificarFalhaGravacao]. O CASE só avalia o ramo escolhido, então a
//   condição falsa passa calada (conferido em SQLite real, tool/).

/// Onde a fila de gravação (FilaGravacao) guarda as operações pendentes, nas
/// preferências do aparelho.
const String chaveFilaGravacao = 'fila_gravacao_v1';

/// Marca dos erros provocados de propósito pela guarda de conflito.
const String marcadorConflito = 'GONDOLAS_CONFLITO';

/// Literal de texto SQL. Null vira NULL.
///
/// Aspas simples dobradas são o escape completo de string no SQLite (não há
/// barra invertida). O NUL sai porque truncaria o texto no lado C.
String sqlTexto(String? valor) {
  if (valor == null) return 'NULL';
  final limpo = valor.replaceAll('\u0000', '').replaceAll("'", "''");
  return "'$limpo'";
}

/// Literal numérico SQL. NaN e infinito não têm literal — melhor recusar do
/// que gravar lixo num estoque.
String sqlNumero(num valor) {
  if (valor is double && !valor.isFinite) {
    throw ArgumentError.value(valor, 'valor', 'número não finito');
  }
  if (valor is double &&
      valor == valor.truncateToDouble() &&
      valor.abs() < 1e15) {
    return valor.toInt().toString();
  }
  return valor.toString();
}

/// SELECT que aborta o lote quando [condicao] é verdadeira. O [motivo] volta
/// no erro (ver [classificarFalhaGravacao]) e precisa ser uma palavra só.
String guardaConflito(String condicao, String motivo) =>
    "SELECT CASE WHEN $condicao THEN "
    "json_extract('{}', '$marcadorConflito:$motivo') END";

/// O carimbo da gravação em `app_mutacoes_aplicadas` — o último passo antes
/// do COMMIT, e a prova (consultável no servidor) de que o lote entrou.
String comandoCarimbo({
  required String uuid,
  required String operacao,
  required String aplicadaEm,
  required String dispositivo,
}) =>
    'INSERT OR IGNORE INTO app_mutacoes_aplicadas '
    '(uuid, aplicada_em, operacao, dispositivo) VALUES '
    '(${sqlTexto(uuid)}, ${sqlTexto(aplicadaEm)}, ${sqlTexto(operacao)}, '
    '${sqlTexto(dispositivo)})';

/// Os comandos entre BEGIN IMMEDIATE e COMMIT, num texto só para o `batch`.
///
/// IMMEDIATE, e não o DEFERRED padrão: pega a trava de escrita já no começo,
/// então dois aparelhos gravando na mesma pilha são serializados pelo
/// servidor em vez de um deles cair com SQLITE_BUSY no meio do lote.
String textoDoLote(List<String> comandos) =>
    ['BEGIN IMMEDIATE', ...comandos, 'COMMIT'].join(';\n');

// ── Falhas ───────────────────────────────────────────────────────────────────

enum TipoFalhaGravacao {
  /// O servidor recusou porque o mundo mudou (pilha cheia, rack que já não
  /// está lá). Reenviar dá no mesmo: a operação sai da fila e a tela volta ao
  /// que está no banco.
  conflito,

  /// O servidor rodou o SQL e recusou (tabela ausente, restrição violada).
  /// Também não adianta reenviar.
  recusada,

  /// Não deu para falar com o servidor, ou a resposta não chegou. Reenviar
  /// é seguro (o lote é idempotente) e é o que a fila faz sozinha.
  rede,
}

class FalhaGravacao implements Exception {
  final TipoFalhaGravacao tipo;

  /// Para [TipoFalhaGravacao.conflito]: o motivo escrito na guarda
  /// (`pilha_cheia`, `rack_ausente`, …).
  final String? motivo;
  final String detalhe;

  const FalhaGravacao(this.tipo, this.detalhe, {this.motivo});

  bool get transitoria => tipo == TipoFalhaGravacao.rede;

  @override
  String toString() => 'FalhaGravacao(${tipo.name}'
      '${motivo == null ? '' : ': $motivo'}): $detalhe';
}

/// Decide se vale reenviar.
///
/// O libsql_dart transforma todo erro do Rust em pânico, então o que chega
/// aqui é texto: a mensagem do Hrana com o código do SQLite dentro
/// (`SQLITE_CONSTRAINT`, `SQL_PARSE_ERROR`…) quando o servidor executou e
/// recusou, ou erro de HTTP/socket quando não houve conversa. Na dúvida o
/// erro é tratado como de rede — reenviar um lote idempotente custa uma
/// requisição; jogar fora o lançamento de alguém custa a carga sem endereço.
FalhaGravacao classificarFalhaGravacao(Object erro) {
  if (erro is FalhaGravacao) return erro;
  if (erro is TimeoutException) {
    return const FalhaGravacao(
      TipoFalhaGravacao.rede,
      'O banco online não respondeu a tempo.',
    );
  }
  final texto = erro.toString();
  final i = texto.indexOf(marcadorConflito);
  if (i >= 0) {
    final resto = texto.substring(i + marcadorConflito.length);
    final m = RegExp(r'^:([A-Za-z0-9_]+)').firstMatch(resto);
    return FalhaGravacao(
      TipoFalhaGravacao.conflito,
      texto,
      motivo: m?.group(1),
    );
  }
  final maiusculo = texto.toUpperCase();
  // Trava de escrita ocupada é passageira por definição.
  if (maiusculo.contains('SQLITE_BUSY') ||
      maiusculo.contains('SQLITE_LOCKED') ||
      maiusculo.contains('DATABASE IS LOCKED')) {
    return FalhaGravacao(TipoFalhaGravacao.rede, texto);
  }
  if (RegExp(r'\bSQL(ITE)?_[A-Z_]+').hasMatch(maiusculo) ||
      maiusculo.contains('CONSTRAINT FAILED') ||
      maiusculo.contains('NO SUCH TABLE') ||
      maiusculo.contains('NO SUCH COLUMN')) {
    return FalhaGravacao(TipoFalhaGravacao.recusada, texto);
  }
  return FalhaGravacao(TipoFalhaGravacao.rede, texto);
}

// ── Operações ────────────────────────────────────────────────────────────────

/// Valores do esquema compartilhado com os apps irmãos. Repetidos aqui (e
/// conferidos contra os originais em test/gravacao_lote_test.dart) porque
/// este arquivo roda também fora do Flutter, nas verificações em SQLite real.
const String localTipoGalpaoSql = 'galpao';
const String localTipoBarracaoSql = 'barracao';
const String prefixoEstocadoSql = 'EST:';

/// Todos os produtos do galpão, um por linha: o principal de cada rack (a
/// própria linha de `galpao_racks`, `item_uuid` NULL) e os itens dos racks
/// mistos (`galpao_rack_itens`), com a posição e a ordem do rack que os
/// leva. `seq` põe o principal antes dos itens, e os itens na ordem em que
/// entraram — é essa ordem que decide quem sobe a principal quando o
/// principal sai.
///
/// É o que tudo que pergunta "o que tem no galpão" lê (a tela, a busca, a
/// conferência, o espelho em estoque_localizado), para um produto que entrou
/// num rack misto não sumir de nenhum deles.
const String sqlProdutosGalpao =
    '(SELECT rack_uuid, NULL AS item_uuid, posicao, ordem, produto_codigo, '
    'produto_nome, quantidade, 0 AS seq FROM galpao_racks '
    'UNION ALL '
    'SELECT r.rack_uuid, i.item_uuid, r.posicao, r.ordem, i.produto_codigo, '
    'i.produto_nome, i.quantidade, i.id AS seq FROM galpao_rack_itens i '
    'JOIN galpao_racks r ON r.rack_uuid = i.rack_uuid)';

enum TipoOperacao {
  galpaoLancar('galpao.lancar'),
  galpaoAjustar('galpao.ajustarQuantidade'),
  galpaoEsvaziar('galpao.esvaziar'),
  galpaoAdicionarProduto('galpao.adicionarProduto'),
  galpaoRemoverProduto('galpao.removerProduto'),
  barracaoAtribuir('barracao.atribuir'),
  barracaoEsvaziar('barracao.esvaziar'),
  barracaoEmpilhar('barracao.empilhar'),
  barracaoAjustarGaiola('barracao.ajustarGaiola'),
  barracaoEsvaziarGaiola('barracao.esvaziarGaiola');

  /// Nome gravado em `app_mutacoes_aplicadas.operacao` — o mesmo que a
  /// gravação antiga usava, para o histórico continuar legível.
  final String operacao;
  const TipoOperacao(this.operacao);

  bool get doGalpao =>
      this == galpaoLancar ||
      this == galpaoAjustar ||
      this == galpaoEsvaziar ||
      this == galpaoAdicionarProduto ||
      this == galpaoRemoverProduto;

  bool get doBarracao => !doGalpao;
}

/// Uma gravação que a pessoa já fez na tela e que ainda não foi confirmada
/// pelo servidor.
///
/// Guarda o que a pessoa QUIS (o produto, o número, o rack que ela tocou), e
/// não o estado da linha: o SQL que a aplica é montado na hora do envio, com
/// as guardas que conferem se o mundo ainda é o que ela viu.
class OperacaoPendente {
  /// Identidade da gravação. É o UUID carimbado em `app_mutacoes_aplicadas` e,
  /// no lançamento do galpão, também o `rack_uuid` do rack novo — é assim que
  /// um ajuste feito logo depois, ainda offline, acha o rack que nem chegou ao
  /// servidor.
  final String uuid;
  final TipoOperacao tipo;

  /// Banco (ver `idBanco`) em que a gravação foi feita. Uma gravação nunca é
  /// mandada para outro banco.
  final String banco;

  /// Quando a pessoa gravou. Vai para `atualizado_em`/`registrado_em`: o
  /// palete mudou de fato nessa hora, mesmo que a rede só tenha deixado
  /// avisar o servidor depois.
  final DateTime criadaEm;

  /// Posição do galpão (1–138) ou id do endereço do barracão.
  final int local;

  /// Rack alvo de ajuste/esvaziamento no galpão — e, no barracão, a gaiola
  /// empilhada alvo (gaiola_uuid).
  final String? rackUuid;

  /// Produto alvo DENTRO de um rack misto (ajuste e remoção). Null é o
  /// principal do rack — que é também o único produto de um rack comum, e o
  /// que toda gravação anterior ao rack misto quis dizer.
  final String? itemUuid;

  final String produtoCodigo;
  final String produtoNome;

  /// Quantidade nova. Zero ao esvaziar.
  final double quantidade;

  /// Quantidade que o rack/palete tinha na tela quando a pessoa agiu — o
  /// delta do saldo e o texto do aviso se a gravação não passar.
  final double? quantidadeAnterior;

  /// Rótulo do endereço para as mensagens (`52 · N3`, `BAR-07`).
  final String rotulo;

  /// Só para quem não é a tela (baixa automática).
  final String? origem;

  const OperacaoPendente({
    required this.uuid,
    required this.tipo,
    required this.banco,
    required this.criadaEm,
    required this.local,
    this.rackUuid,
    this.itemUuid,
    this.produtoCodigo = '',
    this.produtoNome = '',
    this.quantidade = 0,
    this.quantidadeAnterior,
    this.rotulo = '',
    this.origem,
  });

  Map<String, Object?> toJson() => {
        'uuid': uuid,
        'tipo': tipo.name,
        'banco': banco,
        'criadaEm': criadaEm.toIso8601String(),
        'local': local,
        'rackUuid': rackUuid,
        'itemUuid': itemUuid,
        'produtoCodigo': produtoCodigo,
        'produtoNome': produtoNome,
        'quantidade': quantidade,
        'quantidadeAnterior': quantidadeAnterior,
        'rotulo': rotulo,
        'origem': origem,
      };

  /// Null quando o registro não é legível (versão futura, disco corrompido):
  /// melhor deixar de fora do que mandar ao banco algo mal interpretado.
  static OperacaoPendente? fromJson(Map<String, Object?> json) {
    try {
      final tipo = TipoOperacao.values.byName(json['tipo'] as String);
      return OperacaoPendente(
        uuid: json['uuid'] as String,
        tipo: tipo,
        banco: json['banco'] as String? ?? '',
        criadaEm: DateTime.parse(json['criadaEm'] as String),
        local: (json['local'] as num).toInt(),
        rackUuid: json['rackUuid'] as String?,
        itemUuid: json['itemUuid'] as String?,
        produtoCodigo: json['produtoCodigo'] as String? ?? '',
        produtoNome: json['produtoNome'] as String? ?? '',
        quantidade: (json['quantidade'] as num?)?.toDouble() ?? 0,
        quantidadeAnterior: (json['quantidadeAnterior'] as num?)?.toDouble(),
        rotulo: json['rotulo'] as String? ?? '',
        origem: json['origem'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  static String codificarLista(Iterable<OperacaoPendente> ops) =>
      jsonEncode([for (final o in ops) o.toJson()]);

  static List<OperacaoPendente> decodificarLista(String? texto) {
    if (texto == null || texto.isEmpty) return [];
    try {
      final ops = <OperacaoPendente>[];
      for (final item in jsonDecode(texto) as List) {
        final op = OperacaoPendente.fromJson(
          Map<String, Object?>.from(item as Map),
        );
        if (op != null) ops.add(op);
      }
      return ops;
    } catch (_) {
      return [];
    }
  }

  /// Delta que a gravação causa no endereçado do produto.
  double get deltaEnderecado => switch (tipo) {
        TipoOperacao.galpaoLancar ||
        TipoOperacao.galpaoAdicionarProduto ||
        TipoOperacao.barracaoEmpilhar =>
          quantidade,
        TipoOperacao.galpaoEsvaziar ||
        TipoOperacao.galpaoRemoverProduto ||
        TipoOperacao.barracaoEsvaziar ||
        TipoOperacao.barracaoEsvaziarGaiola =>
          -(quantidadeAnterior ?? 0),
        _ => quantidade - (quantidadeAnterior ?? 0),
      };

  /// Frase curta do que a pessoa fez, para a lista de pendentes e os avisos.
  String get descricao {
    final nome = produtoNome.isNotEmpty ? produtoNome : produtoCodigo;
    final qtd = _qtd(quantidade);
    return switch (tipo) {
      TipoOperacao.galpaoLancar ||
      TipoOperacao.barracaoAtribuir ||
      TipoOperacao.barracaoEmpilhar =>
        '$nome · $qtd em $rotulo',
      TipoOperacao.galpaoAjustar ||
      TipoOperacao.barracaoAjustarGaiola =>
        '$nome · $rotulo → $qtd',
      TipoOperacao.galpaoAdicionarProduto => '+ $nome · $qtd em $rotulo',
      TipoOperacao.galpaoRemoverProduto =>
        'Tirar ${nome.isEmpty ? 'produto' : nome} de $rotulo',
      TipoOperacao.galpaoEsvaziar ||
      TipoOperacao.barracaoEsvaziar ||
      TipoOperacao.barracaoEsvaziarGaiola =>
        'Esvaziar $rotulo${nome.isEmpty ? '' : ' ($nome)'}',
    };
  }

  static String _qtd(double q) =>
      q == q.truncateToDouble() ? q.toInt().toString() : q.toString();

  /// Os comandos SQL do lote (sem BEGIN/COMMIT — ver [textoDoLote]).
  ///
  /// [aplicadaEm] é a hora do envio, para o carimbo; [dispositivo] identifica
  /// o aparelho na revisão de conflitos.
  List<String> comandos({
    required String aplicadaEm,
    required String dispositivo,
  }) {
    final agora = sqlTexto(criadaEm.toIso8601String());
    final u = sqlTexto(uuid);
    final naoAplicada =
        'NOT EXISTS (SELECT 1 FROM app_mutacoes_aplicadas WHERE uuid = $u)';
    final carimbo = comandoCarimbo(
      uuid: uuid,
      operacao: tipo.operacao,
      aplicadaEm: aplicadaEm,
      dispositivo: dispositivo,
    );
    return switch (tipo) {
      TipoOperacao.galpaoLancar => [
          ..._lancarGalpao(agora, u, naoAplicada),
          carimbo,
        ],
      TipoOperacao.galpaoAjustar => [
          ..._ajustarGalpao(agora, naoAplicada),
          carimbo,
        ],
      TipoOperacao.galpaoEsvaziar => [
          ..._esvaziarGalpao(agora, naoAplicada),
          carimbo,
        ],
      TipoOperacao.galpaoAdicionarProduto => [
          ..._adicionarProdutoGalpao(agora, u, naoAplicada),
          carimbo,
        ],
      TipoOperacao.galpaoRemoverProduto => [
          ..._removerProdutoGalpao(agora, naoAplicada),
          carimbo,
        ],
      TipoOperacao.barracaoAtribuir => [
          ..._atribuirBarracao(agora, naoAplicada),
          carimbo,
        ],
      TipoOperacao.barracaoEsvaziar => [
          ..._esvaziarBarracao(agora, naoAplicada),
          carimbo,
        ],
      TipoOperacao.barracaoEmpilhar => [
          ..._empilharBarracao(agora, u, naoAplicada),
          carimbo,
        ],
      TipoOperacao.barracaoAjustarGaiola => [
          ..._ajustarGaiolaBarracao(agora, naoAplicada),
          carimbo,
        ],
      TipoOperacao.barracaoEsvaziarGaiola => [
          ..._esvaziarGaiolaBarracao(agora, naoAplicada),
          carimbo,
        ],
    };
  }

  // ── Galpão ──────────────────────────────────────────────────────────────

  String get _p => sqlNumero(local);

  /// Rack novo no TOPO da pilha. A ordem é calculada no servidor (MAX + 1),
  /// nunca recebida da tela: se outro aparelho empilhou nesta posição
  /// enquanto este estava offline, o rack entra no nível certo mesmo assim.
  List<String> _lancarGalpao(String agora, String u, String naoAplicada) => [
        guardaConflito(
          '$naoAplicada AND (SELECT COALESCE(MAX(ordem), 0) FROM galpao_racks '
              'WHERE posicao = $_p) >= ${GalpaoConfig.niveisMax}',
          'pilha_cheia',
        ),
        'INSERT INTO galpao_racks (posicao, ordem, produto_codigo, produto_nome, '
            'quantidade, atualizado_em, rack_uuid) '
            'SELECT $_p, (SELECT COALESCE(MAX(ordem), 0) + 1 FROM galpao_racks '
            'WHERE posicao = $_p), ${sqlTexto(produtoCodigo)}, '
            '${sqlTexto(produtoNome)}, ${sqlNumero(quantidade)}, $agora, $u '
            'WHERE $naoAplicada',
        ..._espelhoGalpao(agora, naoAplicada),
        'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
            'qtd_nova, origem, registrado_em) '
            "SELECT produto_codigo, 'GALPAO·' || posicao || '·N' || ordem, NULL, "
            'quantidade, ${sqlTexto(origem ?? 'gondolas_app_galpao')}, $agora '
            'FROM galpao_racks WHERE rack_uuid = $u AND $naoAplicada',
      ];

  /// O rack é achado pelo `rack_uuid`, não pela ordem: se um rack de baixo
  /// saiu enquanto este aparelho estava offline, o nível mudou mas o palete
  /// é o mesmo — e é nele que a pessoa tocou.
  String get _rackAlvo => 'rack_uuid = ${sqlTexto(rackUuid)} AND posicao = $_p';

  String _guardaRack(String naoAplicada) => guardaConflito(
        '$naoAplicada AND NOT EXISTS (SELECT 1 FROM galpao_racks '
            'WHERE $_rackAlvo)',
        'rack_ausente',
      );

  List<String> _ajustarGalpao(String agora, String naoAplicada) {
    if (itemUuid != null) return _ajustarItemGalpao(agora, naoAplicada);
    return [
        _guardaRack(naoAplicada),
        // O log antes do UPDATE: é a linha ainda intacta que dá a quantidade
        // anterior.
        'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
            'qtd_nova, origem, registrado_em) '
            "SELECT produto_codigo, 'GALPAO·' || posicao || '·N' || ordem, "
            'quantidade, ${sqlNumero(quantidade)}, '
            '${sqlTexto(origem ?? 'gondolas_app_galpao')}, $agora '
            'FROM galpao_racks WHERE $_rackAlvo AND $naoAplicada',
        'UPDATE galpao_racks SET quantidade = ${sqlNumero(quantidade)}, '
            'atualizado_em = $agora WHERE $_rackAlvo AND $naoAplicada',
        ..._espelhoGalpao(agora, naoAplicada),
      ];
  }

  /// Tira o rack e DESCE a pilha. Renumeração em dois passos pelos negativos,
  /// como sempre foi (ver GalpaoService): um `ordem = ordem - 1` direto
  /// esbarraria no UNIQUE(posicao, ordem) no meio do UPDATE. Os de cima vão
  /// para o negativo ANTES do DELETE porque é o rack ainda presente que diz
  /// a partir de que nível descer.
  List<String> _esvaziarGalpao(String agora, String naoAplicada) => [
        _guardaRack(naoAplicada),
        'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
            'qtd_nova, origem, registrado_em) '
            "SELECT produto_codigo, 'GALPAO·' || posicao || '·N' || ordem, "
            'quantidade, 0, '
            '${sqlTexto(origem ?? 'gondolas_app_galpao_exclusao')}, $agora '
            'FROM galpao_racks WHERE $_rackAlvo AND $naoAplicada',
        // O rack sai com tudo o que leva: num rack misto cada produto ganha
        // a sua linha de log, como se tivesse sido zerado um a um.
        'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
            'qtd_nova, origem, registrado_em) '
            "SELECT i.produto_codigo, 'GALPAO·' || r.posicao || '·N' || "
            'r.ordem, i.quantidade, 0, '
            '${sqlTexto(origem ?? 'gondolas_app_galpao_exclusao')}, $agora '
            'FROM galpao_rack_itens i JOIN galpao_racks r '
            'ON r.rack_uuid = i.rack_uuid WHERE r.$_rackAlvo '
            'AND $naoAplicada ORDER BY i.id',
        ..._tirarRack(agora, naoAplicada),
        'DELETE FROM galpao_rack_itens WHERE rack_uuid = $_rackUuid '
            'AND $naoAplicada',
        ..._espelhoGalpao(agora, naoAplicada),
      ];

  /// O rack sai e a pilha desce — os três passos pelos negativos de
  /// [_esvaziarGalpao]. [condicao] restringe os três de uma vez (é o "só se
  /// não sobrou produto" da remoção do principal).
  List<String> _tirarRack(
    String agora,
    String naoAplicada, {
    String condicao = '',
  }) => [
        'UPDATE galpao_racks SET ordem = -(ordem - 1) WHERE posicao = $_p '
            'AND ordem > (SELECT ordem FROM galpao_racks WHERE $_rackAlvo) '
            'AND $naoAplicada$condicao',
        'DELETE FROM galpao_racks WHERE $_rackAlvo AND $naoAplicada$condicao',
        'UPDATE galpao_racks SET ordem = -ordem, atualizado_em = $agora '
            'WHERE posicao = $_p AND ordem < 0 AND $naoAplicada',
      ];

  // ── Rack misto ──────────────────────────────────────────────────────────

  String get _rackUuid => sqlTexto(rackUuid);

  String get _itensDoRack =>
      'SELECT 1 FROM galpao_rack_itens WHERE rack_uuid = $_rackUuid';

  String _guardaItem(String naoAplicada) => guardaConflito(
        '$naoAplicada AND NOT EXISTS ($_itensDoRack '
            'AND item_uuid = ${sqlTexto(itemUuid)})',
        'item_ausente',
      );

  /// Mexer num item muda o rack: o `atualizado_em` dele acompanha, que é o
  /// que o carimbo da réplica (replica_local.dart) olha em galpao_racks.
  String _tocarRack(String agora, String naoAplicada) =>
      'UPDATE galpao_racks SET atualizado_em = $agora '
      'WHERE $_rackAlvo AND $naoAplicada';

  /// Log de um item do rack, com o endereço do rack que o leva.
  String _logItem(String agora, String naoAplicada, String qtdNova,
          String origemPadrao) =>
      'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
      'qtd_nova, origem, registrado_em) '
      "SELECT i.produto_codigo, 'GALPAO·' || r.posicao || '·N' || r.ordem, "
      'i.quantidade, $qtdNova, ${sqlTexto(origem ?? origemPadrao)}, $agora '
      'FROM galpao_rack_itens i JOIN galpao_racks r '
      'ON r.rack_uuid = i.rack_uuid WHERE i.item_uuid = ${sqlTexto(itemUuid)} '
      'AND r.$_rackAlvo AND $naoAplicada';

  /// Mais um produto no rack. O item nasce com o UUID da gravação, como o
  /// rack no lançamento. Rack cheio e produto que já está no rack são
  /// conflito: outro aparelho pode ter enchido o palete enquanto este estava
  /// offline.
  List<String> _adicionarProdutoGalpao(
    String agora,
    String u,
    String naoAplicada,
  ) {
    final codigo = sqlTexto(produtoCodigo);
    return [
      _guardaRack(naoAplicada),
      guardaConflito(
        '$naoAplicada AND 1 + (SELECT COUNT(*) FROM galpao_rack_itens '
            'WHERE rack_uuid = $_rackUuid) >= '
            '${GalpaoConfig.produtosMaxPorRack}',
        'rack_cheio',
      ),
      guardaConflito(
        '$naoAplicada AND (EXISTS (SELECT 1 FROM galpao_racks WHERE '
            '$_rackAlvo AND produto_codigo = $codigo) OR EXISTS '
            '($_itensDoRack AND produto_codigo = $codigo))',
        'produto_repetido',
      ),
      'INSERT INTO galpao_rack_itens (item_uuid, rack_uuid, produto_codigo, '
          'produto_nome, quantidade, atualizado_em) '
          'SELECT $u, $_rackUuid, $codigo, ${sqlTexto(produtoNome)}, '
          '${sqlNumero(quantidade)}, $agora WHERE $naoAplicada',
      _tocarRack(agora, naoAplicada),
      ..._espelhoGalpao(agora, naoAplicada),
      'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
          'qtd_nova, origem, registrado_em) '
          "SELECT $codigo, 'GALPAO·' || posicao || '·N' || ordem, NULL, "
          '${sqlNumero(quantidade)}, '
          '${sqlTexto(origem ?? 'gondolas_app_galpao')}, $agora '
          'FROM galpao_racks WHERE $_rackAlvo AND $naoAplicada',
    ];
  }

  List<String> _ajustarItemGalpao(String agora, String naoAplicada) => [
        _guardaRack(naoAplicada),
        _guardaItem(naoAplicada),
        _logItem(agora, naoAplicada, sqlNumero(quantidade),
            'gondolas_app_galpao'),
        'UPDATE galpao_rack_itens SET quantidade = ${sqlNumero(quantidade)}, '
            'atualizado_em = $agora WHERE item_uuid = ${sqlTexto(itemUuid)} '
            'AND $naoAplicada',
        _tocarRack(agora, naoAplicada),
        ..._espelhoGalpao(agora, naoAplicada),
      ];

  /// UM produto sai do rack (ver pilhaAposRemoverProduto, que é a mesma regra
  /// na tela):
  /// - item: a linha dele sai, o rack fica;
  /// - principal com itens: o item mais antigo sobe a principal;
  /// - principal sozinho: é o rack saindo, e a pilha desce.
  ///
  /// Quem decide entre os dois últimos é o banco, na hora: se outro aparelho
  /// tirou os itens enquanto este estava offline, o principal saindo esvazia
  /// o rack em vez de deixar um palete sem produto.
  List<String> _removerProdutoGalpao(String agora, String naoAplicada) {
    const origemPadrao = 'gondolas_app_galpao_exclusao';
    if (itemUuid != null) {
      return [
        _guardaRack(naoAplicada),
        _guardaItem(naoAplicada),
        _logItem(agora, naoAplicada, '0', origemPadrao),
        'DELETE FROM galpao_rack_itens WHERE item_uuid = '
            '${sqlTexto(itemUuid)} AND $naoAplicada',
        _tocarRack(agora, naoAplicada),
        ..._espelhoGalpao(agora, naoAplicada),
      ];
    }
    final primeiro = 'SELECT %s FROM galpao_rack_itens WHERE rack_uuid = '
        '$_rackUuid ORDER BY id LIMIT 1';
    return [
      _guardaRack(naoAplicada),
      'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
          'qtd_nova, origem, registrado_em) '
          "SELECT produto_codigo, 'GALPAO·' || posicao || '·N' || ordem, "
          'quantidade, 0, ${sqlTexto(origem ?? origemPadrao)}, $agora '
          'FROM galpao_racks WHERE $_rackAlvo AND $naoAplicada',
      // Sem item nenhum: o rack sai inteiro.
      ..._tirarRack(
        agora,
        naoAplicada,
        condicao: ' AND NOT EXISTS ($_itensDoRack)',
      ),
      // Com itens: o mais antigo sobe a principal e deixa de ser item. O
      // DELETE só acha linha quando houve promoção — sem itens, não há o que
      // apagar.
      'UPDATE galpao_racks SET '
          'produto_codigo = (${primeiro.replaceFirst('%s', 'produto_codigo')}), '
          'produto_nome = (${primeiro.replaceFirst('%s', 'produto_nome')}), '
          'quantidade = (${primeiro.replaceFirst('%s', 'quantidade')}), '
          'atualizado_em = $agora '
          'WHERE $_rackAlvo AND $naoAplicada AND EXISTS ($_itensDoRack)',
      'DELETE FROM galpao_rack_itens WHERE id = (SELECT MIN(id) FROM '
          'galpao_rack_itens WHERE rack_uuid = $_rackUuid) AND $naoAplicada',
      ..._espelhoGalpao(agora, naoAplicada),
    ];
  }

  /// Reescreve o espelho da POSIÇÃO inteira a partir da pilha que ficou no
  /// banco — a mesma regra de sempre (ver GalpaoService), agora dentro do
  /// servidor. Estocado (material de cooperado) não entra: já saiu do sistema.
  ///
  /// Os itens dos racks mistos entram como linhas próprias no mesmo nível —
  /// o UNIQUE de estoque_localizado tem o produto_codigo, então cabem. O
  /// GROUP BY é guarda: o mesmo código duas vezes no mesmo rack não deveria
  /// existir (o lote recusa), mas se existir vira uma linha somada em vez de
  /// derrubar a gravação no UNIQUE.
  List<String> _espelhoGalpao(String agora, String naoAplicada) => [
        'DELETE FROM estoque_localizado WHERE local_tipo = '
            "'$localTipoGalpaoSql' AND local_num = $_p AND $naoAplicada",
        'INSERT INTO estoque_localizado (produto_codigo, local_tipo, local_num, '
            'face_ou_coluna, andar_ou_nivel, quantidade, atualizado_em) '
            "SELECT produto_codigo, '$localTipoGalpaoSql', $_p, 0, ordem, "
            'SUM(quantidade), $agora FROM $sqlProdutosGalpao WHERE posicao = $_p '
            "AND substr(produto_codigo, 1, ${prefixoEstocadoSql.length}) <> "
            "'$prefixoEstocadoSql' AND $naoAplicada "
            'GROUP BY produto_codigo, ordem',
      ];

  // ── Barracão ────────────────────────────────────────────────────────────

  String get _id => sqlNumero(local);

  String _guardaEndereco(String naoAplicada) => guardaConflito(
        '$naoAplicada AND NOT EXISTS (SELECT 1 FROM barracao_enderecos '
            'WHERE id = $_id)',
        'endereco_ausente',
      );

  List<String> _atribuirBarracao(String agora, String naoAplicada) {
    final codigo = sqlTexto(produtoCodigo);
    return [
      _guardaEndereco(naoAplicada),
      // Quantidade anterior só é "anterior" quando o produto é o mesmo:
      // trocar o produto do palete é lançamento novo (mesma regra de antes).
      'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
          'qtd_nova, origem, registrado_em) '
          "SELECT $codigo, 'BARRACAO·' || rotulo, "
          'CASE WHEN produto_codigo = $codigo THEN quantidade END, '
          '${sqlNumero(quantidade)}, '
          '${sqlTexto(origem ?? 'gondolas_app_barracao')}, $agora '
          'FROM barracao_enderecos WHERE id = $_id AND $naoAplicada',
      'UPDATE barracao_enderecos SET produto_codigo = $codigo, '
          'produto_nome = ${sqlTexto(produtoNome)}, '
          'quantidade = ${sqlNumero(quantidade)}, atualizado_em = $agora '
          'WHERE id = $_id AND $naoAplicada',
      ..._espelhoBarracao(agora, naoAplicada),
    ];
  }

  /// Tira a gaiola do CHÃO e a pilha desce: a do nível 2 vira a linha do
  /// endereço (deixa de ser gaiola empilhada) e as outras descem um nível.
  /// Sem nada em cima, o palete fica livre — o esvaziar de sempre.
  List<String> _esvaziarBarracao(String agora, String naoAplicada) {
    final segunda = 'SELECT %s FROM barracao_gaiolas WHERE endereco_id = $_id '
        'AND nivel = 2';
    return [
      _guardaEndereco(naoAplicada),
      'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
          'qtd_nova, origem, registrado_em) '
          "SELECT produto_codigo, 'BARRACAO·' || rotulo, quantidade, 0, "
          '${sqlTexto(origem ?? 'gondolas_app_barracao_exclusao')}, $agora '
          'FROM barracao_enderecos WHERE id = $_id AND $naoAplicada',
      // COALESCE: sem gaiola no nível 2, o chão fica vazio.
      'UPDATE barracao_enderecos SET '
          "produto_codigo = COALESCE((${segunda.replaceFirst('%s', 'produto_codigo')}), ''), "
          "produto_nome = COALESCE((${segunda.replaceFirst('%s', 'produto_nome')}), ''), "
          'quantidade = COALESCE((${segunda.replaceFirst('%s', 'quantidade')}), 0), '
          'atualizado_em = $agora WHERE id = $_id AND $naoAplicada',
      'DELETE FROM barracao_gaiolas WHERE endereco_id = $_id AND nivel = 2 '
          'AND $naoAplicada',
      ..._descerGaiolas(agora, naoAplicada, acimaDe: '1'),
      ..._espelhoBarracao(agora, naoAplicada),
    ];
  }

  /// As gaiolas acima do nível [acimaDe] (expressão SQL) descem um. Em dois
  /// passos pelos negativos, como a pilha do galpão: um `nivel = nivel - 1`
  /// direto esbarraria no UNIQUE(endereco_id, nivel) no meio do UPDATE.
  List<String> _descerGaiolas(
    String agora,
    String naoAplicada, {
    required String acimaDe,
  }) => [
        'UPDATE barracao_gaiolas SET nivel = -(nivel - 1) '
            'WHERE endereco_id = $_id AND nivel > $acimaDe AND $naoAplicada',
        'UPDATE barracao_gaiolas SET nivel = -nivel, atualizado_em = $agora '
            'WHERE endereco_id = $_id AND nivel < 0 AND $naoAplicada',
      ];

  // ── Barracão: gaiolas empilhadas ────────────────────────────────────────

  String get _gaiolaAlvo =>
      'gaiola_uuid = ${sqlTexto(rackUuid)} AND endereco_id = $_id';

  String _guardaGaiola(String naoAplicada) => guardaConflito(
        '$naoAplicada AND NOT EXISTS (SELECT 1 FROM barracao_gaiolas '
            'WHERE $_gaiolaAlvo)',
        'gaiola_ausente',
      );

  /// Quantas gaiolas há na pilha do endereço, a do chão incluída.
  String get _gaiolasNaPilha =>
      "(SELECT CASE WHEN trim(produto_codigo) <> '' THEN 1 ELSE 0 END "
      'FROM barracao_enderecos WHERE id = $_id) + '
      '(SELECT COUNT(*) FROM barracao_gaiolas WHERE endereco_id = $_id)';

  String get _chaoLivre =>
      'EXISTS (SELECT 1 FROM barracao_enderecos WHERE id = $_id '
      "AND trim(produto_codigo) = '')";

  /// Gaiola nova no TOPO da pilha. O nível é calculado no servidor (MAX + 1),
  /// nunca recebido da tela — como o lançamento do galpão. Se outro aparelho
  /// esvaziou o palete enquanto este estava offline, a gaiola vai para o
  /// chão em vez de flutuar no nível 2.
  List<String> _empilharBarracao(String agora, String u, String naoAplicada) {
    final codigo = sqlTexto(produtoCodigo);
    final nome = sqlTexto(produtoNome);
    final qtd = sqlNumero(quantidade);
    return [
      _guardaEndereco(naoAplicada),
      guardaConflito(
        '$naoAplicada AND $_gaiolasNaPilha >= ${BarracaoConfig.gaiolasMax}',
        'pilha_cheia',
      ),
      // Chão ocupado: gaiola nova no topo. Vem ANTES do caso do chão livre
      // de propósito — depois dele o chão já estaria ocupado por esta mesma
      // gravação, e a gaiola entraria duas vezes.
      'INSERT INTO barracao_gaiolas (gaiola_uuid, endereco_id, nivel, '
          'produto_codigo, produto_nome, quantidade, atualizado_em) '
          'SELECT $u, $_id, (SELECT COALESCE(MAX(nivel), 1) + 1 FROM '
          'barracao_gaiolas WHERE endereco_id = $_id), $codigo, $nome, $qtd, '
          '$agora WHERE NOT $_chaoLivre AND $naoAplicada',
      'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
          'qtd_nova, origem, registrado_em) '
          "SELECT g.produto_codigo, 'BARRACAO·' || e.rotulo || '·N' || "
          'g.nivel, NULL, g.quantidade, '
          '${sqlTexto(origem ?? 'gondolas_app_barracao')}, $agora '
          'FROM barracao_gaiolas g JOIN barracao_enderecos e '
          'ON e.id = g.endereco_id WHERE g.gaiola_uuid = $u AND $naoAplicada',
      'UPDATE barracao_enderecos SET atualizado_em = $agora '
          'WHERE id = $_id AND NOT $_chaoLivre AND $naoAplicada',
      // Chão livre (outro aparelho esvaziou o palete): é a gaiola do chão.
      'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
          'qtd_nova, origem, registrado_em) '
          "SELECT $codigo, 'BARRACAO·' || rotulo, NULL, $qtd, "
          '${sqlTexto(origem ?? 'gondolas_app_barracao')}, $agora '
          'FROM barracao_enderecos WHERE id = $_id AND $_chaoLivre '
          'AND $naoAplicada',
      'UPDATE barracao_enderecos SET produto_codigo = $codigo, '
          'produto_nome = $nome, quantidade = $qtd, atualizado_em = $agora '
          'WHERE id = $_id AND $_chaoLivre AND $naoAplicada',
      ..._espelhoBarracao(agora, naoAplicada),
    ];
  }

  List<String> _ajustarGaiolaBarracao(String agora, String naoAplicada) => [
        _guardaEndereco(naoAplicada),
        _guardaGaiola(naoAplicada),
        'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
            'qtd_nova, origem, registrado_em) '
            "SELECT g.produto_codigo, 'BARRACAO·' || e.rotulo || '·N' || "
            'g.nivel, g.quantidade, ${sqlNumero(quantidade)}, '
            '${sqlTexto(origem ?? 'gondolas_app_barracao')}, $agora '
            'FROM barracao_gaiolas g JOIN barracao_enderecos e '
            'ON e.id = g.endereco_id WHERE g.$_gaiolaAlvo AND $naoAplicada',
        'UPDATE barracao_gaiolas SET quantidade = ${sqlNumero(quantidade)}, '
            'atualizado_em = $agora WHERE $_gaiolaAlvo AND $naoAplicada',
        ..._espelhoBarracao(agora, naoAplicada),
      ];

  /// Tira UMA gaiola empilhada e as de cima descem. O nível de partida é
  /// lido da própria gaiola antes de ela sair — por isso o primeiro passo da
  /// descida vem antes do DELETE (mesmo motivo do galpão).
  List<String> _esvaziarGaiolaBarracao(String agora, String naoAplicada) => [
        _guardaEndereco(naoAplicada),
        _guardaGaiola(naoAplicada),
        'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
            'qtd_nova, origem, registrado_em) '
            "SELECT g.produto_codigo, 'BARRACAO·' || e.rotulo || '·N' || "
            'g.nivel, g.quantidade, 0, '
            '${sqlTexto(origem ?? 'gondolas_app_barracao_exclusao')}, $agora '
            'FROM barracao_gaiolas g JOIN barracao_enderecos e '
            'ON e.id = g.endereco_id WHERE g.$_gaiolaAlvo AND $naoAplicada',
        'UPDATE barracao_gaiolas SET nivel = -(nivel - 1) '
            'WHERE endereco_id = $_id AND nivel > (SELECT nivel FROM '
            'barracao_gaiolas WHERE $_gaiolaAlvo) AND $naoAplicada',
        'DELETE FROM barracao_gaiolas WHERE $_gaiolaAlvo AND $naoAplicada',
        'UPDATE barracao_gaiolas SET nivel = -nivel, atualizado_em = $agora '
            'WHERE endereco_id = $_id AND nivel < 0 AND $naoAplicada',
        // O endereço muda junto: é o atualizado_em dele que a cópia e o
        // carimbo da réplica olham.
        'UPDATE barracao_enderecos SET atualizado_em = $agora '
            'WHERE id = $_id AND $naoAplicada',
        ..._espelhoBarracao(agora, naoAplicada),
      ];

  /// Reescreve o espelho do ENDEREÇO inteiro a partir da pilha que ficou no
  /// banco: um produto por linha, com a soma das gaiolas dele — o espelho do
  /// barracão sempre teve andar_ou_nivel 0 (ver localTipoBarracao), e o
  /// UNIQUE de estoque_localizado não deixaria o mesmo produto em duas
  /// gaiolas do mesmo palete virar duas linhas.
  List<String> _espelhoBarracao(String agora, String naoAplicada) => [
        'DELETE FROM estoque_localizado WHERE local_tipo = '
            "'$localTipoBarracaoSql' AND local_num = $_id AND $naoAplicada",
        'INSERT INTO estoque_localizado (produto_codigo, local_tipo, local_num, '
            'face_ou_coluna, andar_ou_nivel, quantidade, atualizado_em) '
            "SELECT produto_codigo, '$localTipoBarracaoSql', $_id, 0, 0, "
            'SUM(quantidade), $agora FROM ('
            'SELECT produto_codigo, quantidade FROM barracao_enderecos '
            'WHERE id = $_id UNION ALL '
            'SELECT produto_codigo, quantidade FROM barracao_gaiolas '
            'WHERE endereco_id = $_id) '
            "WHERE trim(produto_codigo) <> '' AND quantidade > 0 "
            "AND substr(produto_codigo, 1, ${prefixoEstocadoSql.length}) <> "
            "'$prefixoEstocadoSql' AND $naoAplicada "
            'GROUP BY produto_codigo',
      ];
}

/// A planta do galpão inteira num upsert de várias linhas, com os valores do
/// código como literais (ver GalpaoService.garantirSeed).
String comandoSeedGalpao() {
  final linhas = [
    for (final p in GalpaoConfig.posicoes)
      '(${sqlNumero(p.numero)}, ${sqlNumero(p.rua.numero)}, '
          "${sqlTexto(p.rua.eixo == EixoRua.z ? 'z' : 'x')}, "
          '${sqlNumero(p.x)}, ${sqlNumero(p.z)})',
  ];
  return 'INSERT INTO galpao_posicoes (numero, rua, eixo, pos_x, pos_z) '
      'VALUES ${linhas.join(', ')} '
      'ON CONFLICT(numero) DO UPDATE SET '
      'rua = excluded.rua, eixo = excluded.eixo, '
      'pos_x = excluded.pos_x, pos_z = excluded.pos_z';
}

/// Assinatura curta (FNV-1a de 32 bits) de um texto SQL — para lembrar no
/// aparelho que um comando idempotente já rodou naquele banco sem guardar o
/// comando inteiro. `String.hashCode` não serve: não tem garantia de ser o
/// mesmo entre versões do app.
int assinaturaTexto(String texto) {
  var hash = 0x811c9dc5;
  for (final unidade in texto.codeUnits) {
    hash ^= unidade;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}
