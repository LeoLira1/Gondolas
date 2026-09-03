import 'dart:convert';

import 'package:libsql_dart/libsql_dart.dart';

import 'outbox.dart';

/// Persistência da outbox, num arquivo SQLite SEPARADO da réplica.
///
/// Separado de propósito, e é o ponto inteiro do desenho: a recuperação de uma
/// réplica divergente APAGA o arquivo da réplica. Se o registro das mutações
/// morasse lá dentro, ele morreria junto com aquilo que serve para reconstruir
/// — a lista do que precisa ser reaplicado sumiria exatamente quando é
/// necessária.
///
/// O arquivo é particionado pela identidade do banco (mesma regra do cache
/// local): mutações de um banco nunca podem ser reaplicadas noutro.
class OutboxStore {
  LibsqlClient? _client;
  String? _caminho;

  /// Abre (e cria, se preciso) a outbox em [caminho]. Reaproveita a conexão
  /// enquanto o caminho não muda.
  Future<void> abrir(String caminho) async {
    if (_client != null && _caminho == caminho) return;
    await fechar();
    final client = LibsqlClient.local(caminho);
    await client.connect();
    await client.execute('''
      CREATE TABLE IF NOT EXISTS mutacoes (
        uuid                  TEXT PRIMARY KEY,
        operacao              TEXT NOT NULL,
        tabela                TEXT NOT NULL,
        chave                 TEXT NOT NULL,
        estado_anterior       TEXT,
        estado_final          TEXT,
        criado_em             TEXT NOT NULL,
        dispositivo           TEXT NOT NULL,
        estado                TEXT NOT NULL,
        produto_codigo        TEXT,
        produto_nome          TEXT,
        posicao               INTEGER,
        ordem                 INTEGER,
        quantidade_anterior   REAL,
        quantidade_pretendida REAL
      )
    ''');
    await client.execute(
        'CREATE INDEX IF NOT EXISTS idx_mutacoes_estado ON mutacoes(estado)');
    _client  = client;
    _caminho = caminho;
  }

  Future<void> fechar() async {
    final aberta = _client;
    _client  = null;
    _caminho = null;
    if (aberta != null) {
      try {
        await aberta.dispose();
      } catch (_) {}
    }
  }

  bool get aberta => _client != null;

  /// Grava a intenção. Chamado ANTES do commit local: se o app morrer entre
  /// esta linha e o commit, sobra um registro de algo que talvez não tenha
  /// acontecido — e é isso que se quer. O contrário (o commit sem registro) é
  /// que seria perda silenciosa.
  Future<void> registrar(MutacaoOutbox m) async {
    final client = _client;
    if (client == null) return;
    await client.execute(
      'INSERT OR REPLACE INTO mutacoes (uuid, operacao, tabela, chave, '
      'estado_anterior, estado_final, criado_em, dispositivo, estado, '
      'produto_codigo, produto_nome, posicao, ordem, quantidade_anterior, '
      'quantidade_pretendida) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      positional: [
        m.uuid,
        m.operacao,
        m.alvo.tabela,
        jsonEncode(m.alvo.chave),
        m.estadoAnterior == null ? null : jsonEncode(m.estadoAnterior),
        m.estadoFinal == null ? null : jsonEncode(m.estadoFinal),
        m.criadoEm.toIso8601String(),
        m.dispositivo,
        m.estado.name,
        m.produtoCodigo,
        m.produtoNome,
        m.posicao,
        m.ordem,
        m.quantidadeAnterior,
        m.quantidadePretendida,
      ],
    );
  }

  /// Muda o estado de um registro. Nunca apaga: a outbox é um diário, e um
  /// registro não confirmado é justamente o que não pode sumir.
  Future<void> marcar(String uuid, EstadoMutacao estado) async {
    final client = _client;
    if (client == null) return;
    await client.execute('UPDATE mutacoes SET estado = ? WHERE uuid = ?',
        positional: [estado.name, uuid]);
  }

  /// Tudo que o servidor ainda não confirmou, do mais antigo para o mais novo —
  /// a ordem em que as mutações aconteceram é a ordem em que devem ser
  /// reaplicadas.
  ///
  /// `abortada` fica de fora: a transação caiu antes do commit, então não há
  /// nada no arquivo local para o servidor confirmar. O registro continua
  /// gravado, só não entra na fila.
  Future<List<MutacaoOutbox>> naoConfirmadas() => _consultar(
        "WHERE estado != '${EstadoMutacao.confirmada.name}' "
        "AND estado != '${EstadoMutacao.abortada.name}'",
      );

  /// O que precisa de olho humano: conflito com o remoto ou operação que a
  /// reconstrução não sabe reaplicar sozinha.
  Future<List<MutacaoOutbox>> paraRevisao() => _consultar(
        "WHERE estado IN ('${EstadoMutacao.conflito.name}', "
        "'${EstadoMutacao.revisaoManual.name}')",
      );

  Future<int> quantidadeNaoConfirmada() async {
    final client = _client;
    if (client == null) return 0;
    final linhas = await client.query(
      "SELECT COUNT(*) AS total FROM mutacoes WHERE estado != ? AND estado != ?",
      positional: [
        EstadoMutacao.confirmada.name,
        EstadoMutacao.abortada.name,
      ],
    );
    if (linhas.isEmpty) return 0;
    return (linhas.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<List<MutacaoOutbox>> _consultar(String filtro) async {
    final client = _client;
    if (client == null) return const [];
    final linhas =
        await client.query('SELECT * FROM mutacoes $filtro ORDER BY criado_em');
    return linhas.map(_daLinha).toList();
  }

  static MutacaoOutbox _daLinha(Map<String, dynamic> l) {
    Map<String, Object?>? estado(Object? bruto) => bruto == null
        ? null
        : Map<String, Object?>.from(jsonDecode(bruto as String) as Map);
    return MutacaoOutbox(
      uuid:      l['uuid'] as String,
      operacao:  l['operacao'] as String,
      alvo: AlvoMutacao(
        tabela: l['tabela'] as String,
        chave: Map<String, Object?>.from(
            jsonDecode(l['chave'] as String) as Map),
      ),
      estadoAnterior: estado(l['estado_anterior']),
      estadoFinal:    estado(l['estado_final']),
      criadoEm: DateTime.tryParse(l['criado_em'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      dispositivo: l['dispositivo'] as String? ?? '',
      estado: EstadoMutacao.values.firstWhere(
        (e) => e.name == l['estado'],
        orElse: () => EstadoMutacao.pendente,
      ),
      produtoCodigo:        l['produto_codigo'] as String?,
      produtoNome:          l['produto_nome'] as String?,
      posicao:              (l['posicao'] as num?)?.toInt(),
      ordem:                (l['ordem'] as num?)?.toInt(),
      quantidadeAnterior:   (l['quantidade_anterior'] as num?)?.toDouble(),
      quantidadePretendida: (l['quantidade_pretendida'] as num?)?.toDouble(),
    );
  }
}
