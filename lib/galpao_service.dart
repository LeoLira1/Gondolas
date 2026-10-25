import 'dart:convert';

import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'codigos_vinculados.dart';
import 'fila_gravacao.dart' show executarOperacao;
import 'galpao_config.dart';
import 'galpao_saldo.dart';
import 'galpao_scene.dart' show ProdutoNoRack, RackGalpao;
import 'gravacao_lote.dart';
import 'turso_service.dart';
import 'outbox.dart' show gerarUuidV4;

/// Persistência do galpão: as 138 posições das duas partes (estrutura) e os
/// racks empilhados (ocupação).
///
/// Duas tabelas próprias — galpao_posicoes e galpao_racks — porque a pilha
/// precisa de renumeração transacional, coisa que o modelo destrutivo de
/// estante_layout (DELETE + INSERT da estrutura inteira) não comporta. Cada
/// rack é TAMBÉM espelhado em estoque_localizado com local_tipo 'galpao',
/// que é o contrato com os apps irmãos: sem o espelho, o estoque do galpão
/// ficaria fora do inventário cíclico e do Modo Conferência.
///
/// O espelho é reescrito por POSIÇÃO inteira (apaga as linhas da posição e
/// insere as da pilha resultante) em vez de atualizado linha a linha. Parece
/// desperdício — são no máximo 4 linhas —, mas é o que torna a renumeração
/// segura: decrementar `andar_ou_nivel` em cima de um UNIQUE, com dois racks
/// do MESMO produto na mesma pilha, dá colisão no meio do UPDATE.
class GalpaoService {
  static final GalpaoService _instance = GalpaoService._internal();
  factory GalpaoService() => _instance;
  GalpaoService._internal();

  Future<LibsqlClient?> _conexao() async {
    if (!await TursoService().garantirConexao()) return null;
    return TursoService().client;
  }

  bool _seedFeito = false;

  /// Popula galpao_posicoes a partir de [GalpaoConfig] — idempotente, e
  /// reescreve as coordenadas a cada execução de propósito: a autoridade da
  /// planta é o código (as larguras de corredor ainda são estimativas e vão
  /// ser remedidas), a tabela é só o espelho que os apps irmãos leem.
  ///
  /// UM upsert de várias linhas, numa requisição. Antes eram 129 upserts
  /// dentro de uma transação interativa — ~130 idas e voltas a cada sessão,
  /// com a trava de escrita do banco presa o tempo todo. Na rede da loja isso
  /// levava minutos, e o lançamento de rack ficava esperando a trava atrás
  /// dele.
  ///
  /// E só quando a planta do código mudou: a assinatura do upsert fica
  /// lembrada no aparelho por banco, e com ela igual não há o que reescrever
  /// — nem a requisição única precisa sair (ela disputaria a rede com o
  /// primeiro lançamento do dia).
  Future<bool> garantirSeed({bool forcar = false}) async {
    if (_seedFeito && !forcar) return true;
    final comando = comandoSeedGalpao();
    final assinatura = assinaturaTexto(comando);
    if (!forcar && await _seedLembrado() == assinatura) {
      _seedFeito = true;
      return true;
    }
    try {
      await TursoService().executarLote([comando]);
      _seedFeito = true;
      await _lembrarSeed(assinatura);
      return true;
    } catch (_) {
      return false;
    }
  }

  String? get _chaveSeed {
    final banco = TursoService().identidadeAtiva;
    return banco == null ? null : 'galpao_seed_$banco';
  }

  Future<int?> _seedLembrado() async {
    final chave = _chaveSeed;
    if (chave == null) return null;
    try {
      return (await SharedPreferences.getInstance()).getInt(chave);
    } catch (_) {
      return null;
    }
  }

  Future<void> _lembrarSeed(int assinatura) async {
    final chave = _chaveSeed;
    if (chave == null) return;
    try {
      await (await SharedPreferences.getInstance()).setInt(chave, assinatura);
    } catch (_) {
      // Sem a marca, a próxima sessão só reenvia o upsert idempotente.
    }
  }

  /// Racks e itens dos racks mistos numa consulta só: cada rack vem na sua
  /// linha (item_uuid NULL) seguida das linhas dos itens dele, na ordem em
  /// que entraram.
  static const String _sqlPilhas =
      'SELECT rack_uuid, item_uuid, posicao, ordem, produto_codigo, '
      'produto_nome, quantidade FROM $sqlProdutosGalpao '
      'ORDER BY posicao, ordem, seq';

  /// Ocupação do galpão inteiro: posição → pilha ordenada por ordem.
  ///
  /// Uma consulta só (são no máximo 552 linhas) — percorrer posição a posição
  /// custaria 129 idas ao banco para pintar um frame.
  Future<Map<int, List<RackGalpao>>> carregarPilhas() async {
    try {
      return _pilhasDasLinhas(
        await TursoService().consultarComCache('galpao', _sqlPilhas),
      );
    } catch (_) {
      return {};
    }
  }

  /// Relê a ocupação DO SERVIDOR (sem servir a cópia) e atualiza a cópia de
  /// leitura e a da busca. É a conferência depois que a fila de gravação
  /// esvazia. Null quando a leitura falhou — ao contrário de [carregarPilhas],
  /// aqui um galpão vazio por falta de rede apagaria a tela inteira.
  Future<Map<int, List<RackGalpao>>?> recarregarPilhas() async {
    try {
      final rows = await TursoService().consultarComCache(
        'galpao',
        _sqlPilhas,
        forceRefresh: true,
      );
      await TursoService().guardarConsulta('galpao', rows);
      return _pilhasDasLinhas(rows);
    } catch (_) {
      return null;
    }
  }

  Map<int, List<RackGalpao>> _pilhasDasLinhas(List<Map<String, dynamic>> rows) {
    final pilhas = <int, List<RackGalpao>>{};
    for (final dynamic row in rows) {
      final r = row as Map<String, dynamic>;
      final posicao = r['posicao'] as int? ?? 0;
      // Linha órfã (posição que não existe mais na planta) é ignorada, como
      // as cenas fazem com endereço fora da grade.
      if (GalpaoConfig.porNumero(posicao) == null) continue;
      final itemUuid = r['item_uuid'] as String?;
      if (itemUuid != null) {
        // Item de rack misto: vai para o rack que veio logo antes dele.
        final pilha = pilhas[posicao];
        final rackUuid = r['rack_uuid'] as String?;
        if (pilha == null || pilha.last.rackUuid != rackUuid) continue;
        final rack = pilha.removeLast();
        pilha.add(
          rack.copiar(
            itens: [
              ...rack.itens,
              ProdutoNoRack(
                itemUuid: itemUuid,
                produtoCodigo: r['produto_codigo'] as String? ?? '',
                produtoNome: r['produto_nome'] as String? ?? '',
                quantidade: (r['quantidade'] as num?)?.toDouble() ?? 0,
              ),
            ],
          ),
        );
        continue;
      }
      pilhas.putIfAbsent(posicao, () => <RackGalpao>[]).add(
            RackGalpao(
              rackUuid: r['rack_uuid'] as String?,
              posicao: posicao,
              ordem: r['ordem'] as int? ?? 1,
              produtoCodigo: r['produto_codigo'] as String? ?? '',
              produtoNome: r['produto_nome'] as String? ?? '',
              quantidade: (r['quantidade'] as num?)?.toDouble() ?? 0,
            ),
          );
    }
    return pilhas;
  }

  /// Saldo (sistema × endereçado) dos produtos que têm rack no galpão, mais
  /// os de [codigosExtras] (o produto que o painel está prestes a lançar e
  /// ainda não tem rack nenhum).
  ///
  /// As duas metades da conta somam TODOS os códigos do mesmo produto — é o
  /// que o app do scanner faz, e a falta disso era o "sistema 388" de um
  /// produto que na mão dá 559 (171 + 388). Ver codigos_vinculados.dart.
  ///
  /// Quatro consultas, todas agregadas ou pequenas, contra as 138 posições:
  /// os códigos com rack, o estoque_mestre (mesmo teto de 5000 linhas do
  /// catálogo), o vínculo de códigos do mapa e a soma por código de
  /// estoque_localizado. O endereçado soma TODOS os locais do produto, não só
  /// o galpão (ver a nota em galpao_saldo.dart).
  Future<Map<String, SaldoProduto>> carregarSaldos({
    Set<String> codigosExtras = const {},
  }) async {
    final client = await _conexao();
    if (client == null) return {};
    try {
      // Os códigos entram como estão em galpao_racks (é a chave que a cena
      // usa para achar a cor do cubo); a normalização acontece lá dentro.
      final codigos = await _codigosComRack(client);
      codigos.addAll(codigosExtras);
      if (codigos.isEmpty) return {};

      final mestre = await _lerMestre(client);
      final grupos = gruposDeCodigos(
        codigos: codigos,
        produtoIdPorCodigo: await _lerVinculosDoMapa(client),
        nomePorCodigo: {for (final e in mestre.entries) e.key: e.value.nome},
      );
      return montarSaldos(
        codigos: codigos,
        grupos: grupos,
        sistemaPorCodigo: {
          for (final e in mestre.entries) e.key: e.value.qtdSistema,
        },
        enderecadoPorCodigo: await _lerEnderecado(client),
      );
    } catch (_) {
      return {};
    }
  }

  /// O saldo de UM produto, mesmo que ele ainda não tenha rack no galpão — o
  /// número de que quem vai lançar precisa antes de digitar a quantidade.
  Future<SaldoProduto?> carregarSaldo(String codigo) async {
    if (codigo.trim().isEmpty) return null;
    return (await carregarSaldos(codigosExtras: {codigo}))[codigo];
  }

  Future<Set<String>> _codigosComRack(LibsqlClient client) async {
    final stmt = await client.prepare(
      'SELECT DISTINCT produto_codigo FROM $sqlProdutosGalpao',
    );
    final rows = await stmt.query() as List<dynamic>;
    final codigos = <String>{};
    for (final dynamic row in rows) {
      final r = row as Map<String, dynamic>;
      final codigo = r['produto_codigo'] as String? ?? '';
      if (codigo.trim().isNotEmpty) codigos.add(codigo);
    }
    return codigos;
  }

  /// Nome e qtd_sistema de cada código do estoque_mestre.
  ///
  /// A tabela inteira (com o mesmo teto do catálogo) porque o irmão de um
  /// código sem vínculo no mapa só é achável pelo NOME — ler só os códigos
  /// com rack devolveria de novo meio saldo, que é o bug que isto conserta.
  Future<Map<String, ({String nome, double qtdSistema})>> _lerMestre(
    LibsqlClient client,
  ) async {
    final stmt = await client.prepare(
      'SELECT codigo, produto, qtd_sistema FROM estoque_mestre LIMIT 5000',
    );
    final rows = await stmt.query() as List<dynamic>;
    final mestre = <String, ({String nome, double qtdSistema})>{};
    for (final dynamic row in rows) {
      final r = row as Map<String, dynamic>;
      final codigo = normalizarCodigo(r['codigo'] as String?);
      if (codigo == null) continue;
      mestre[codigo] = (
        nome: r['produto'] as String? ?? '',
        qtdSistema: (r['qtd_sistema'] as num?)?.toDouble() ?? 0,
      );
    }
    return mestre;
  }

  /// Código → produto_id do mapa de produtos (principal e secundários).
  ///
  /// As duas tabelas são criadas pelo dashboard e podem não existir num banco
  /// onde o mapa nunca foi usado; a ausência de uma não pode derrubar a
  /// leitura da outra nem a consulta de saldo — sem mapa, resta o nome.
  Future<Map<String, String>> _lerVinculosDoMapa(LibsqlClient client) async {
    final vinculos = <String, String>{};
    for (final tabela in const ['mapa_produtos', 'mapa_produtos_codigos']) {
      try {
        final stmt = await client.prepare(
          'SELECT produto_id, codigo FROM $tabela WHERE codigo IS NOT NULL',
        );
        final rows = await stmt.query() as List<dynamic>;
        for (final dynamic row in rows) {
          final r = row as Map<String, dynamic>;
          final codigo = normalizarCodigo(r['codigo'] as String?);
          final produtoId = (r['produto_id']?.toString() ?? '').trim();
          if (codigo == null || produtoId.isEmpty) continue;
          vinculos[codigo] = produtoId;
        }
      } catch (_) {
        // Tabela ausente (ou coluna diferente): segue sem ela.
      }
    }
    return vinculos;
  }

  /// Soma de estoque_localizado por código, em todos os locais.
  Future<Map<String, double>> _lerEnderecado(LibsqlClient client) async {
    final stmt = await client.prepare(
      'SELECT produto_codigo, SUM(quantidade) AS enderecado '
      'FROM estoque_localizado GROUP BY produto_codigo',
    );
    final rows = await stmt.query() as List<dynamic>;
    final total = <String, double>{};
    for (final dynamic row in rows) {
      final r = row as Map<String, dynamic>;
      final codigo = normalizarCodigo(r['produto_codigo'] as String?);
      if (codigo == null) continue;
      total[codigo] = (r['enderecado'] as num?)?.toDouble() ?? 0;
    }
    return total;
  }

  // ── Gravação ─────────────────────────────────────────────────────────────
  //
  // A tela do galpão não chama mais estes métodos: ela põe a operação na
  // FilaGravacao, que aplica na hora e reenvia sozinha. Eles ficam para quem
  // grava sem tela — a baixa automática — e usam o MESMO lote (uma requisição,
  // ver gravacao_lote.dart). Devolvem true só com o COMMIT confirmado.

  /// Lança um rack no TOPO da pilha da posição. A ordem é calculada no
  /// servidor; pilha cheia é recusada.
  ///
  /// O UUID vem de `pedidoOnline`: um lançamento cuja resposta se perdeu é
  /// reenviado com o mesmo UUID, e o lote reconhece que já está gravado.
  Future<bool> lancar({
    required int posicao,
    required String produtoCodigo,
    required String produtoNome,
    required double quantidade,
  }) async {
    try {
      final chavePedido = jsonEncode([
        'galpao.lancar',
        posicao,
        produtoCodigo,
        produtoNome,
        quantidade,
      ]);
      final uuid = await TursoService().pedidoOnline(chavePedido);
      await executarOperacao(
        OperacaoPendente(
          uuid: uuid,
          tipo: TipoOperacao.galpaoLancar,
          banco: TursoService().identidadeAtiva ?? '',
          criadaEm: DateTime.now(),
          local: posicao,
          produtoCodigo: produtoCodigo,
          produtoNome: produtoNome,
          quantidade: quantidade,
        ),
      );
      await TursoService().concluirPedidoOnline(chavePedido);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Troca a quantidade de um rack — o palete continua onde está, com o
  /// mesmo produto, só o número muda. O rack é o de [rackUuid] (o nível pode
  /// ter mudado desde a leitura; o palete não). Quantidade não positiva é
  /// recusada: zerar é [esvaziar].
  ///
  /// [itemUuid] escolhe um produto DENTRO de um rack misto; null é o
  /// principal.
  Future<bool> ajustarQuantidade({
    required int posicao,
    required int ordem,
    required double quantidade,
    String? origem,
    String? rackUuid,
    String? itemUuid,
  }) async {
    if (quantidade <= 0 || rackUuid == null) return false;
    try {
      await executarOperacao(
        OperacaoPendente(
          uuid: gerarUuidV4(),
          tipo: TipoOperacao.galpaoAjustar,
          banco: TursoService().identidadeAtiva ?? '',
          criadaEm: DateTime.now(),
          local: posicao,
          rackUuid: rackUuid,
          itemUuid: itemUuid,
          quantidade: quantidade,
          origem: origem,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Esvazia o rack de [rackUuid] e DESCE a pilha: os de cima descem um nível
  /// cada, tudo na mesma transação.
  Future<bool> esvaziar({
    required int posicao,
    required int ordem,
    String? origem,
    String? rackUuid,
  }) async {
    if (rackUuid == null) return false;
    try {
      await executarOperacao(
        OperacaoPendente(
          uuid: gerarUuidV4(),
          tipo: TipoOperacao.galpaoEsvaziar,
          banco: TursoService().identidadeAtiva ?? '',
          criadaEm: DateTime.now(),
          local: posicao,
          rackUuid: rackUuid,
          origem: origem,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Tira UM produto do rack de [rackUuid] ([itemUuid] null é o principal).
  /// Se era o último produto do rack, o rack sai e a pilha desce — é o
  /// esvaziar de um rack comum. Ver pilhaAposRemoverProduto.
  Future<bool> removerProduto({
    required int posicao,
    required int ordem,
    String? origem,
    String? rackUuid,
    String? itemUuid,
  }) async {
    if (rackUuid == null) return false;
    try {
      await executarOperacao(
        OperacaoPendente(
          uuid: gerarUuidV4(),
          tipo: TipoOperacao.galpaoRemoverProduto,
          banco: TursoService().identidadeAtiva ?? '',
          criadaEm: DateTime.now(),
          local: posicao,
          rackUuid: rackUuid,
          itemUuid: itemUuid,
          origem: origem,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
