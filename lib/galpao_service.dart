import 'package:libsql_dart/libsql_dart.dart';
// `client.transaction()` devolve um Transaction que o pacote NÃO reexporta no
// seu libsql_dart.dart (o tipo vaza da API pública sem estar acessível). Sem
// este import direto não dá para tipar os helpers que recebem a transação; a
// alternativa seria passá-la como dynamic e perder a checagem nas chamadas.
// Se um upgrade do libsql_dart mover o arquivo, é aqui que quebra.
import 'package:libsql_dart/src/transaction.dart' show Transaction;

import 'codigos_vinculados.dart';
import 'galpao_config.dart';
import 'galpao_saldo.dart';
import 'galpao_scene.dart' show RackGalpao;
import 'models.dart' show localTipoGalpao;
import 'turso_service.dart';

/// Persistência do galpão: as 129 posições das duas partes (estrutura) e os
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
  Future<bool> garantirSeed({bool forcar = false}) async {
    if (_seedFeito && !forcar) return true;
    final client = await _conexao();
    if (client == null) return false;
    try {
      final tx = await client.transaction();
      try {
        for (final p in GalpaoConfig.posicoes) {
          await tx.execute(
            'INSERT INTO galpao_posicoes (numero, rua, eixo, pos_x, pos_z) '
            'VALUES (?, ?, ?, ?, ?) '
            'ON CONFLICT(numero) DO UPDATE SET '
            'rua = excluded.rua, eixo = excluded.eixo, '
            'pos_x = excluded.pos_x, pos_z = excluded.pos_z',
            positional: [
              p.numero,
              p.rua.numero,
              p.rua.eixo == EixoRua.z ? 'z' : 'x',
              p.x,
              p.z,
            ],
          );
        }
        await tx.commit();
      } catch (e) {
        await tx.rollback();
        rethrow;
      }
      _seedFeito = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Ocupação do galpão inteiro: posição → pilha ordenada por ordem.
  ///
  /// Uma consulta só (são no máximo 516 linhas) — percorrer posição a posição
  /// custaria 129 idas ao banco para pintar um frame.
  Future<Map<int, List<RackGalpao>>> carregarPilhas() async {
    final client = await _conexao();
    if (client == null) return {};
    try {
      final stmt = await client.prepare(
        'SELECT posicao, ordem, produto_codigo, produto_nome, quantidade '
        'FROM galpao_racks ORDER BY posicao, ordem',
      );
      final rows = await stmt.query() as List<dynamic>;
      final pilhas = <int, List<RackGalpao>>{};
      for (final dynamic row in rows) {
        final r = row as Map<String, dynamic>;
        final posicao = r['posicao'] as int? ?? 0;
        // Linha órfã (posição que não existe mais na planta) é ignorada, como
        // as cenas fazem com endereço fora da grade.
        if (GalpaoConfig.porNumero(posicao) == null) continue;
        pilhas.putIfAbsent(posicao, () => <RackGalpao>[]).add(RackGalpao(
              posicao:       posicao,
              ordem:         r['ordem'] as int? ?? 1,
              produtoCodigo: r['produto_codigo'] as String? ?? '',
              produtoNome:   r['produto_nome']   as String? ?? '',
              quantidade:    (r['quantidade'] as num?)?.toDouble() ?? 0,
            ));
      }
      return pilhas;
    } catch (_) {
      return {};
    }
  }

  /// Saldo (sistema × endereçado) dos produtos que têm rack no galpão, mais
  /// os de [codigosExtras] (o produto que o painel está prestes a lançar e
  /// ainda não tem rack nenhum).
  ///
  /// As duas metades da conta somam TODOS os códigos do mesmo produto — é o
  /// que o app do scanner faz, e a falta disso era o "sistema 388" de um
  /// produto que na mão dá 559 (171 + 388). Ver codigos_vinculados.dart.
  ///
  /// Quatro consultas, todas agregadas ou pequenas, contra as 129 posições:
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
        codigos:            codigos,
        produtoIdPorCodigo: await _lerVinculosDoMapa(client),
        nomePorCodigo:      {
          for (final e in mestre.entries) e.key: e.value.nome,
        },
      );
      return montarSaldos(
        codigos:             codigos,
        grupos:              grupos,
        sistemaPorCodigo:    {
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
      'SELECT DISTINCT produto_codigo FROM galpao_racks',
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
      LibsqlClient client) async {
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
        nome:       r['produto'] as String? ?? '',
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

  /// Lança um rack no TOPO da pilha da posição. Devolve a nova pilha, ou null
  /// se falhou (sem conexão, pilha cheia, corrida com outro dispositivo).
  ///
  /// A ordem do rack novo é lida DENTRO da transação (MAX(ordem) + 1), nunca
  /// recebida da tela: entre o toque e a gravação, outra pessoa pode ter
  /// lançado na mesma posição, e o que vale é o estado do banco.
  Future<List<RackGalpao>?> lancar({
    required int    posicao,
    required String produtoCodigo,
    required String produtoNome,
    required double quantidade,
  }) async {
    final client = await _conexao();
    if (client == null) return null;
    final agora = DateTime.now().toIso8601String();
    try {
      final tx = await client.transaction();
      try {
        final rows = await tx.query(
          'SELECT COALESCE(MAX(ordem), 0) AS topo FROM galpao_racks '
          'WHERE posicao = ?',
          positional: [posicao],
        );
        final topo = (rows.first['topo'] as int?) ?? 0;
        if (topo >= GalpaoConfig.niveisMax) {
          await tx.rollback();
          return null;
        }
        final ordem = topo + 1;

        await tx.execute(
          'INSERT INTO galpao_racks (posicao, ordem, produto_codigo, '
          'produto_nome, quantidade, atualizado_em) VALUES (?, ?, ?, ?, ?, ?)',
          positional: [
            posicao, ordem, produtoCodigo, produtoNome, quantidade, agora,
          ],
        );
        final pilha = await _lerPilha(tx, posicao);
        await _reescreverEspelho(tx, posicao, pilha, agora);
        await _registrarLog(tx, posicao, ordem, produtoCodigo,
            anterior: null, nova: quantidade, agora: agora);
        await tx.commit();
        return pilha;
      } catch (e) {
        await tx.rollback();
        rethrow;
      }
    } catch (_) {
      return null;
    }
  }

  /// Troca a quantidade do rack de [ordem] — o palete continua onde está, com
  /// o mesmo produto, só o número muda. Devolve a nova pilha, ou null se
  /// falhou (sem conexão, rack inexistente, quantidade não positiva).
  ///
  /// É a correção de contagem que faltava: sem ela, acertar "57" num rack
  /// lançado com 14 exigia esvaziar (derrubando a pilha de cima) e lançar de
  /// novo. O espelho de estoque_localizado é reescrito pela mesma rotina do
  /// lançamento, então o saldo do produto acompanha na mesma transação.
  Future<List<RackGalpao>?> ajustarQuantidade({
    required int    posicao,
    required int    ordem,
    required double quantidade,
  }) async {
    if (quantidade <= 0) return null; // zerar é esvaziar, que é outra coisa
    final client = await _conexao();
    if (client == null) return null;
    final agora = DateTime.now().toIso8601String();
    try {
      final tx = await client.transaction();
      try {
        final antes = await tx.query(
          'SELECT produto_codigo, quantidade FROM galpao_racks '
          'WHERE posicao = ? AND ordem = ? LIMIT 1',
          positional: [posicao, ordem],
        );
        if (antes.isEmpty) {
          await tx.rollback();
          return null;
        }
        final codigo   = antes.first['produto_codigo'] as String? ?? '';
        final qtdAntes = (antes.first['quantidade'] as num?)?.toDouble() ?? 0;

        await tx.execute(
          'UPDATE galpao_racks SET quantidade = ?, atualizado_em = ? '
          'WHERE posicao = ? AND ordem = ?',
          positional: [quantidade, agora, posicao, ordem],
        );

        final pilha = await _lerPilha(tx, posicao);
        await _reescreverEspelho(tx, posicao, pilha, agora);
        await _registrarLog(tx, posicao, ordem, codigo,
            anterior: qtdAntes, nova: quantidade, agora: agora);
        await tx.commit();
        return pilha;
      } catch (e) {
        await tx.rollback();
        rethrow;
      }
    } catch (_) {
      return null;
    }
  }

  /// Esvazia o rack de [ordem] e DESCE a pilha: os de cima descem um nível
  /// cada e a ordem é renumerada, tudo numa transação. Devolve a nova pilha,
  /// ou null se falhou.
  Future<List<RackGalpao>?> esvaziar({
    required int posicao,
    required int ordem,
  }) async {
    final client = await _conexao();
    if (client == null) return null;
    final agora = DateTime.now().toIso8601String();
    try {
      final tx = await client.transaction();
      try {
        final antes = await tx.query(
          'SELECT produto_codigo, quantidade FROM galpao_racks '
          'WHERE posicao = ? AND ordem = ? LIMIT 1',
          positional: [posicao, ordem],
        );
        if (antes.isEmpty) {
          await tx.rollback();
          return null;
        }
        final codigo    = antes.first['produto_codigo'] as String? ?? '';
        final qtdAntes  = (antes.first['quantidade'] as num?)?.toDouble() ?? 0;

        await tx.execute(
          'DELETE FROM galpao_racks WHERE posicao = ? AND ordem = ?',
          positional: [posicao, ordem],
        );

        // Renumeração em DOIS passos, via negativos. Um único
        // `SET ordem = ordem - 1` esbarraria no UNIQUE(posicao, ordem) no meio
        // do UPDATE: o SQLite valida linha a linha, e nada garante que a linha
        // de ordem menor seja processada primeiro. O intervalo negativo é
        // território livre, então a ida e a volta nunca colidem.
        await tx.execute(
          'UPDATE galpao_racks SET ordem = -(ordem - 1) '
          'WHERE posicao = ? AND ordem > ?',
          positional: [posicao, ordem],
        );
        await tx.execute(
          'UPDATE galpao_racks SET ordem = -ordem, atualizado_em = ? '
          'WHERE posicao = ? AND ordem < 0',
          positional: [agora, posicao],
        );

        final pilha = await _lerPilha(tx, posicao);
        await _reescreverEspelho(tx, posicao, pilha, agora);
        await _registrarLog(tx, posicao, ordem, codigo,
            anterior: qtdAntes, nova: 0, agora: agora);
        await tx.commit();
        return pilha;
      } catch (e) {
        await tx.rollback();
        rethrow;
      }
    } catch (_) {
      return null;
    }
  }

  Future<List<RackGalpao>> _lerPilha(Transaction tx, int posicao) async {
    final rows = await tx.query(
      'SELECT posicao, ordem, produto_codigo, produto_nome, quantidade '
      'FROM galpao_racks WHERE posicao = ? ORDER BY ordem',
      positional: [posicao],
    );
    return [
      for (final r in rows)
        RackGalpao(
          posicao:       r['posicao'] as int? ?? posicao,
          ordem:         r['ordem']   as int? ?? 1,
          produtoCodigo: r['produto_codigo'] as String? ?? '',
          produtoNome:   r['produto_nome']   as String? ?? '',
          quantidade:    (r['quantidade'] as num?)?.toDouble() ?? 0,
        ),
    ];
  }

  /// Reescreve as linhas de estoque_localizado da posição a partir da pilha
  /// resultante (ver a nota na doc da classe sobre por que é reescrita, e não
  /// atualização linha a linha).
  Future<void> _reescreverEspelho(
      Transaction tx, int posicao, List<RackGalpao> pilha, String agora) async {
    await tx.execute(
      'DELETE FROM estoque_localizado WHERE local_tipo = ? AND local_num = ?',
      positional: [localTipoGalpao, posicao],
    );
    for (final rack in pilha) {
      await tx.execute(
        'INSERT INTO estoque_localizado (produto_codigo, local_tipo, '
        'local_num, face_ou_coluna, andar_ou_nivel, quantidade, atualizado_em) '
        'VALUES (?, ?, ?, 0, ?, ?, ?)',
        positional: [
          rack.produtoCodigo,
          localTipoGalpao,
          posicao,
          rack.ordem,
          rack.quantidade,
          agora,
        ],
      );
    }
  }

  Future<void> _registrarLog(
    Transaction tx,
    int posicao,
    int ordem,
    String produtoCodigo, {
    required double? anterior,
    required double nova,
    required String agora,
  }) async {
    await tx.execute(
      'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
      'qtd_nova, origem, registrado_em) VALUES (?, ?, ?, ?, ?, ?)',
      positional: [
        produtoCodigo,
        'GALPAO·$posicao·N$ordem',
        anterior,
        nova,
        nova == 0 ? 'gondolas_app_galpao_exclusao' : 'gondolas_app_galpao',
        agora,
      ],
    );
  }
}
