import 'package:libsql_dart/libsql_dart.dart';
// Mesmo motivo do import direto em galpao_service.dart: `client.transaction()`
// devolve um Transaction que o pacote não reexporta, e sem este import não dá
// para tipar os helpers que recebem a transação.
import 'package:libsql_dart/src/transaction.dart' show Transaction;

import 'barracao_config.dart';
import 'gravacao_lote.dart';
import 'turso_service.dart';
import 'outbox.dart';
import 'replica_coordinator.dart';

/// Um endereço do barracão, já com o que está nele.
///
/// Diferente do galpão, aqui NÃO há pilha nem nível: o palete é o endereço, e
/// o endereço tem no máximo um produto. Por isso [produtoCodigo] vazio é a
/// leitura de "palete livre" — não existe linha de ocupação separada para
/// apagar.
class EnderecoBarracao {
  /// Chave da linha em `barracao_enderecos`. É o que vai para
  /// `estoque_localizado.local_num` (ver [localTipoBarracao]).
  final int id;

  /// Rótulo etiquetado no palete: 'BAR-01', 'BAR-02', …
  final String rotulo;

  /// Centro do palete no chão, em CENTÍMETROS (ver barracao_config.dart).
  final double x, z;

  final String produtoCodigo;
  final String produtoNome;
  final double quantidade;

  const EnderecoBarracao({
    required this.id,
    required this.rotulo,
    required this.x,
    required this.z,
    this.produtoCodigo = '',
    this.produtoNome   = '',
    this.quantidade    = 0,
  });

  /// True quando há produto atribuído ao palete.
  bool get ocupado => produtoCodigo.trim().isNotEmpty;

  EnderecoBarracao comProduto({
    required String produtoCodigo,
    required String produtoNome,
    required double quantidade,
  }) =>
      EnderecoBarracao(
        id:            id,
        rotulo:        rotulo,
        x:             x,
        z:             z,
        produtoCodigo: produtoCodigo,
        produtoNome:   produtoNome,
        quantidade:    quantidade,
      );

  /// O palete sem produto — o que sobra depois de esvaziar.
  EnderecoBarracao get vazio => EnderecoBarracao(
        id: id, rotulo: rotulo, x: x, z: z,
      );
}

/// Persistência do barracão: uma tabela só, `barracao_enderecos`, em que cada
/// linha é um palete no chão.
///
/// Por que UMA tabela, e não o par estrutura + ocupação do galpão: lá a
/// posição existe sempre e a pilha por cima dela varia, então separar era a
/// única forma de guardar vaga vazia. Aqui o palete É o endereço — some do
/// chão quando sai —, e a ocupação é um produto só. Duas tabelas seriam duas
/// linhas para descrever o mesmo objeto físico.
///
/// A quantidade de paletes é DADO, não código: o app lê desta tabela e desenha
/// o que vier. [BarracaoConfig.posicoesPadrao] só entra quando a tabela está
/// vazia (ver [garantirSeed]) — daí em diante, quem manda é o banco.
///
/// Como o galpão, cada endereço ocupado é espelhado em `estoque_localizado`
/// com local_tipo [localTipoBarracao]: é o contrato com os apps irmãos, e sem
/// ele o estoque do barracão ficaria fora do inventário cíclico e do Modo
/// Conferência.
class BarracaoService {
  static final BarracaoService _instance = BarracaoService._internal();
  factory BarracaoService() => _instance;
  BarracaoService._internal();

  Future<LibsqlClient?> _conexao() async {
    if (!await TursoService().garantirConexao()) return null;
    return TursoService().client;
  }

  bool _seedFeito = false;

  /// Popula `barracao_enderecos` a partir de [BarracaoConfig.posicoesPadrao],
  /// e SÓ quando a tabela está vazia.
  ///
  /// É a diferença deliberada em relação ao seed do galpão, que reescreve as
  /// coordenadas a cada execução: lá a planta é fixa e o código é a
  /// autoridade; aqui a planta MUDA com a operação (paletes entram e saem do
  /// chão), então reescrever apagaria justamente o cadastro que a tabela
  /// existe para guardar. A semente é só o ponto de partida de um banco novo.
  Future<bool> garantirSeed() async {
    // Seed já feito não tem o que escrever: entrar na fila de escrita só para
    // descobrir isso fazia a LEITURA dos paletes esperar o mutex e qualquer
    // sync nativo em andamento.
    if (_seedFeito) return true;
    try {
      return await TursoService().garantirReplicaProntaParaEscrita(_garantirSeed);
    } on ReplicaNaoProntaParaEscrita {
      return false;
    }
  }

  Future<bool> _garantirSeed() async {
    if (_seedFeito) return true;
    final client = await _conexao();
    if (client == null) return false;
    try {
      final stmt = await client.prepare(
        'SELECT COUNT(*) AS n FROM barracao_enderecos',
      );
      final rows = await stmt.query() as List<dynamic>;
      final n = (rows.first as Map<String, dynamic>)['n'] as int? ?? 0;
      // COUNT(*) varre a tabela: conta as linhas dela, não a única devolvida.
      TursoService().contarLeitura('barracao_seed', n);
      if (n > 0) {
        _seedFeito = true;
        return true;
      }

      final agora = DateTime.now().toIso8601String();
      MutacaoOutbox? mutacao;
      List<Map<String, dynamic>>? cacheRows;
      final tx = await client.transaction();
      try {
        for (final p in BarracaoConfig.posicoesPadrao) {
          await tx.execute(
            'INSERT INTO barracao_enderecos '
            '(rotulo, pos_x, pos_z, produto_codigo, produto_nome, '
            'quantidade, atualizado_em) '
            "VALUES (?, ?, ?, '', '', 0, ?) "
            'ON CONFLICT(rotulo) DO NOTHING',
            positional: [p.rotulo, p.x, p.z, agora],
          );
        }
        // Planta do barracão vinda do código, como o seed do galpão: sem
        // estado declarado, porque ela se reexecuta sozinha se faltar.
        mutacao = await TursoService().abrirMutacao(
          operacao: 'barracao.garantirSeed',
          tabela:   'barracao_enderecos',
          chave:    const {},
          estadoAnterior: null,
          estadoFinal:    null,
        );
        await TursoService().carimbarMutacao(tx, mutacao);
        cacheRows = await _lerTodos(tx);
        await tx.commit();
        await _guardarCache(cacheRows);
        // Frame novo no arquivo local esperando o próximo Sincronizar — sem
        // esta marca, um push que não sai passaria por "nada a enviar".
        // Endereço semeado nasce vazio: nada vai para estoque_localizado.
        await TursoService().marcarGravacaoLocal(expirarQuantidades: false);
      } catch (e) {
        await tx.rollback();
        if (mutacao != null) await TursoService().abortarMutacao(mutacao);
        rethrow;
      }
      _seedFeito = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Os endereços do barracão, em ordem de rótulo (a ordem etiquetada no
  /// chão). É daqui que a cena tira quantos paletes desenhar e onde.
  ///
  /// Uma consulta só: são ~100 linhas, e percorrer endereço a endereço
  /// custaria uma ida ao banco por palete para pintar um frame.
  Future<List<EnderecoBarracao>> carregarEnderecos() async {
    try {
      // Mesmo caminho do galpão: a cópia em memória/disco responde na hora e
      // o banco é relido atrás. As gravações abaixo atualizam esta cópia.
      final rows = await TursoService().consultarComCache(
        chaveCache,
        _sqlTodos,
      );
      return [for (final row in rows) _daLinha(row)];
    } catch (_) {
      return const [];
    }
  }

  /// Relê os endereços DO SERVIDOR, sem servir a cópia, e atualiza a cópia de
  /// leitura e a da busca — a conferência depois que a fila de gravação
  /// esvazia. Null quando a leitura falhou: aqui uma lista vazia por falta de
  /// rede apagaria o barracão inteiro da tela.
  Future<List<EnderecoBarracao>?> recarregarEnderecos() async {
    try {
      final rows = await TursoService().consultarComCache(
        chaveCache,
        _sqlTodos,
        forceRefresh: true,
      );
      await _guardarCache(rows);
      return [for (final row in rows) _daLinha(row)];
    } catch (_) {
      return null;
    }
  }

  static EnderecoBarracao _daLinha(Map<String, dynamic> row) =>
      EnderecoBarracao(
        id:            row['id']     as int?    ?? 0,
        rotulo:        row['rotulo'] as String? ?? '',
        x:             (row['pos_x'] as num?)?.toDouble() ?? 0,
        z:             (row['pos_z'] as num?)?.toDouble() ?? 0,
        produtoCodigo: row['produto_codigo'] as String? ?? '',
        produtoNome:   row['produto_nome']   as String? ?? '',
        quantidade:    (row['quantidade'] as num?)?.toDouble() ?? 0,
      );

  /// Chave da cópia de leitura. É a mesma que a busca do mapa lê (ver
  /// `TursoService.chaveBarracao`).
  static const String chaveCache = TursoService.chaveBarracao;

  static const String _sqlTodos = TursoService.sqlBarracao;

  /// Atualiza a cópia de leitura DEPOIS do commit. Falhar aqui não pode virar
  /// rollback de uma gravação já confirmada: no pior caso o refresh em segundo
  /// plano corrige a cópia.
  Future<void> _guardarCache(List<Map<String, dynamic>> linhas) async {
    try {
      await TursoService().guardarConsulta(chaveCache, linhas);
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _lerTodos(Transaction tx) async =>
      (await tx.query(_sqlTodos))
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
}

/// O barracão como a pessoa o vê: o banco com as gravações ainda na fila por
/// cima, na ordem em que foram feitas (ver `aplicarPendentesGalpao`). As duas
/// operações do barracão são absolutas — o palete fica com ESTE produto e
/// ESTE número, ou vazio —, então reaplicar uma que o banco já tem não muda
/// nada.
List<EnderecoBarracao> aplicarPendentesBarracao(
  List<EnderecoBarracao> enderecos,
  Iterable<OperacaoPendente> pendentes,
) {
  var lista = enderecos;
  for (final op in pendentes) {
    if (op.tipo != TipoOperacao.barracaoAtribuir &&
        op.tipo != TipoOperacao.barracaoEsvaziar) {
      continue;
    }
    lista = [
      for (final e in lista)
        if (e.id != op.local)
          e
        else if (op.tipo == TipoOperacao.barracaoEsvaziar)
          e.vazio
        else
          e.comProduto(
            produtoCodigo: op.produtoCodigo,
            produtoNome: op.produtoNome,
            quantidade: op.quantidade,
          ),
    ];
  }
  return lista;
}
