import 'package:flutter/foundation.dart' show visibleForTesting;
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

/// Uma gaiola EMPILHADA num endereço do barracão (nível 2 em diante).
///
/// A do chão não precisa desta classe: ela é a própria linha do endereço
/// ([EnderecoBarracao.produtoCodigo] etc.). [gaiolaUuid] é a identidade da
/// linha em `barracao_gaiolas` — o nível muda quando sai uma gaiola de baixo,
/// o UUID não.
class GaiolaBarracao {
  final String gaiolaUuid;
  final String produtoCodigo;
  final String produtoNome;
  final double quantidade;

  const GaiolaBarracao({
    required this.gaiolaUuid,
    required this.produtoCodigo,
    this.produtoNome = '',
    this.quantidade = 0,
  });

  GaiolaBarracao comQuantidade(double q) => GaiolaBarracao(
        gaiolaUuid:    gaiolaUuid,
        produtoCodigo: produtoCodigo,
        produtoNome:   produtoNome,
        quantidade:    q,
      );
}

/// Um endereço do barracão, já com o que está nele.
///
/// O endereço é um lugar no chão e leva uma PILHA de até
/// [BarracaoConfig.gaiolasMax] gaiolas. A do chão (nível 1) mora nos campos
/// do próprio endereço — [produtoCodigo] vazio é a leitura de "palete livre"
/// —, e as de cima em [acima], em ordem de nível (a primeira é o nível 2).
/// Como no galpão, a pilha nunca tem buraco: gaiola nova entra no topo, e
/// tirar uma faz as de cima descerem (ver [semNivel]).
class EnderecoBarracao {
  /// Chave da linha em `barracao_enderecos`. É o que vai para
  /// `estoque_localizado.local_num` (ver [localTipoBarracao]).
  final int id;

  /// Rótulo etiquetado no palete: 'BAR-01', 'BAR-02', …
  final String rotulo;

  /// Centro do palete no chão, em CENTÍMETROS (ver barracao_config.dart).
  final double x, z;

  /// A gaiola do chão.
  final String produtoCodigo;
  final String produtoNome;
  final double quantidade;

  /// As gaiolas empilhadas sobre a do chão, de baixo para cima.
  final List<GaiolaBarracao> acima;

  const EnderecoBarracao({
    required this.id,
    required this.rotulo,
    required this.x,
    required this.z,
    this.produtoCodigo = '',
    this.produtoNome   = '',
    this.quantidade    = 0,
    this.acima         = const [],
  });

  /// True quando há produto atribuído ao palete do chão.
  bool get ocupado => produtoCodigo.trim().isNotEmpty;

  /// Quantas gaiolas há na pilha (0 = palete livre).
  int get niveis => ocupado ? 1 + acima.length : 0;

  /// Pilha no teto: não cabe mais gaiola.
  bool get cheio => niveis >= BarracaoConfig.gaiolasMax;

  /// UUID da gaiola do nível [nivel], ou null no chão (que não tem) e em
  /// nível que não existe.
  String? uuidDoNivel(int nivel) =>
      nivel >= 2 && nivel <= niveis ? acima[nivel - 2].gaiolaUuid : null;

  /// Nível da gaiola [gaiolaUuid] (2 em diante), ou null se ela não está aqui.
  int? nivelDaGaiola(String? gaiolaUuid) {
    if (gaiolaUuid == null) return null;
    final i = acima.indexWhere((g) => g.gaiolaUuid == gaiolaUuid);
    return i < 0 ? null : i + 2;
  }

  /// Produto, nome e quantidade de cada nível, de baixo para cima.
  List<({int nivel, String codigo, String nome, double quantidade})>
      get gaiolas => [
            if (ocupado)
              (
                nivel: 1,
                codigo: produtoCodigo,
                nome: produtoNome,
                quantidade: quantidade,
              ),
            if (ocupado)
              for (var i = 0; i < acima.length; i++)
                (
                  nivel: i + 2,
                  codigo: acima[i].produtoCodigo,
                  nome: acima[i].produtoNome,
                  quantidade: acima[i].quantidade,
                ),
          ];

  /// True quando alguma gaiola da pilha leva [codigo].
  bool contem(String codigo) =>
      codigo.isNotEmpty && gaiolas.any((g) => g.codigo == codigo);

  EnderecoBarracao _com({
    String? produtoCodigo,
    String? produtoNome,
    double? quantidade,
    List<GaiolaBarracao>? acima,
  }) =>
      EnderecoBarracao(
        id:            id,
        rotulo:        rotulo,
        x:             x,
        z:             z,
        produtoCodigo: produtoCodigo ?? this.produtoCodigo,
        produtoNome:   produtoNome ?? this.produtoNome,
        quantidade:    quantidade ?? this.quantidade,
        acima:         acima ?? this.acima,
      );

  /// A gaiola do chão com outro produto/quantidade; as de cima ficam.
  EnderecoBarracao comProduto({
    required String produtoCodigo,
    required String produtoNome,
    required double quantidade,
  }) =>
      _com(
        produtoCodigo: produtoCodigo,
        produtoNome:   produtoNome,
        quantidade:    quantidade,
      );

  /// O palete sem pilha nenhuma.
  EnderecoBarracao get vazio => EnderecoBarracao(
        id: id, rotulo: rotulo, x: x, z: z,
      );

  /// Gaiola nova no TOPO da pilha — ou no chão, se o palete está livre. Null
  /// quando a pilha já está cheia.
  EnderecoBarracao? comGaiolaNoTopo({
    required String gaiolaUuid,
    required String produtoCodigo,
    required String produtoNome,
    required double quantidade,
  }) {
    if (cheio) return null;
    if (!ocupado) {
      return comProduto(
        produtoCodigo: produtoCodigo,
        produtoNome:   produtoNome,
        quantidade:    quantidade,
      );
    }
    return _com(acima: [
      ...acima,
      GaiolaBarracao(
        gaiolaUuid:    gaiolaUuid,
        produtoCodigo: produtoCodigo,
        produtoNome:   produtoNome,
        quantidade:    quantidade,
      ),
    ]);
  }

  /// A pilha com a quantidade do nível [nivel] trocada. Nível inexistente ou
  /// quantidade não positiva devolve o endereço como está.
  EnderecoBarracao comQuantidadeNoNivel(int nivel, double quantidade) {
    if (quantidade <= 0 || nivel < 1 || nivel > niveis) return this;
    if (nivel == 1) return _com(quantidade: quantidade);
    return _com(acima: [
      for (var i = 0; i < acima.length; i++)
        i == nivel - 2 ? acima[i].comQuantidade(quantidade) : acima[i],
    ]);
  }

  /// A pilha sem a gaiola do nível [nivel]: as de cima descem um nível. Tirar
  /// a do chão faz a do nível 2 virar a do chão (perde o UUID: no banco ela
  /// passa a ser a linha do endereço). Nível inexistente não muda nada.
  EnderecoBarracao semNivel(int nivel) {
    if (nivel < 1 || nivel > niveis) return this;
    if (nivel > 1) {
      return _com(acima: [
        for (var i = 0; i < acima.length; i++)
          if (i != nivel - 2) acima[i],
      ]);
    }
    if (acima.isEmpty) return vazio;
    final sobe = acima.first;
    return _com(
      produtoCodigo: sobe.produtoCodigo,
      produtoNome:   sobe.produtoNome,
      quantidade:    sobe.quantidade,
      acima:         acima.sublist(1),
    );
  }
}

/// Persistência do barracão: `barracao_enderecos`, em que cada linha é um
/// palete no chão com a gaiola de baixo, e `barracao_gaiolas`, com as gaiolas
/// empilhadas em cima dela (níveis 2 a [BarracaoConfig.gaiolasMax]).
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
      return enderecosDasLinhas(rows);
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
      return enderecosDasLinhas(rows);
    } catch (_) {
      return null;
    }
  }

  /// Uma linha por gaiola (ver TursoService.sqlBarracao) → um endereço por
  /// palete, com a pilha montada. A linha do chão vem antes das de cima (o
  /// ORDER BY é por rótulo e nível); cópia antiga, sem a coluna `nivel`, é
  /// toda de chão — era o que existia.
  @visibleForTesting
  static List<EnderecoBarracao> enderecosDasLinhas(
      List<Map<String, dynamic>> rows) {
    final porId = <int, EnderecoBarracao>{};
    final acima = <int, List<GaiolaBarracao>>{};
    for (final row in rows) {
      final id = row['id'] as int? ?? 0;
      final nivel = (row['nivel'] as num?)?.toInt() ?? 1;
      final codigo = row['produto_codigo'] as String? ?? '';
      final nome = row['produto_nome'] as String? ?? '';
      final qtd = (row['quantidade'] as num?)?.toDouble() ?? 0;
      if (nivel <= 1) {
        porId[id] = EnderecoBarracao(
          id:            id,
          rotulo:        row['rotulo'] as String? ?? '',
          x:             (row['pos_x'] as num?)?.toDouble() ?? 0,
          z:             (row['pos_z'] as num?)?.toDouble() ?? 0,
          produtoCodigo: codigo,
          produtoNome:   nome,
          quantidade:    qtd,
        );
      } else {
        acima.putIfAbsent(id, () => []).add(GaiolaBarracao(
              gaiolaUuid:    row['gaiola_uuid'] as String? ?? '',
              produtoCodigo: codigo,
              produtoNome:   nome,
              quantidade:    qtd,
            ));
      }
    }
    return [
      for (final e in porId.values)
        if (acima[e.id] case final pilha? when pilha.isNotEmpty)
          _comPilha(e, pilha)
        else
          e,
    ];
  }

  /// Junta a pilha ao endereço. Chão vazio com gaiola em cima não existe no
  /// galpão físico (a gaiola apoia na de baixo); se o banco disser isso, a de
  /// baixo das que sobraram é mostrada no chão, que é onde ela de fato está.
  static EnderecoBarracao _comPilha(
      EnderecoBarracao e, List<GaiolaBarracao> pilha) {
    if (e.ocupado) {
      return EnderecoBarracao(
        id: e.id, rotulo: e.rotulo, x: e.x, z: e.z,
        produtoCodigo: e.produtoCodigo,
        produtoNome:   e.produtoNome,
        quantidade:    e.quantidade,
        acima:         List.unmodifiable(pilha),
      );
    }
    final chao = pilha.first;
    return EnderecoBarracao(
      id: e.id, rotulo: e.rotulo, x: e.x, z: e.z,
      produtoCodigo: chao.produtoCodigo,
      produtoNome:   chao.produtoNome,
      quantidade:    chao.quantidade,
      acima:         List.unmodifiable(pilha.sublist(1)),
    );
  }

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

  Future<List<Map<String, dynamic>>> _lerTodos(Transaction tx) async {
    final rows = await tx.query(_sqlTodos);
    TursoService().contarLeitura(chaveCache, rows.length);
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

/// O barracão como a pessoa o vê: o banco com as gravações ainda na fila por
/// cima, na ordem em que foram feitas (ver `aplicarPendentesGalpao`).
///
/// As operações da gaiola do chão são absolutas — o palete fica com ESTE
/// produto e ESTE número —, e as das gaiolas empilhadas acham a gaiola pelo
/// UUID, nunca pelo nível: reaplicar uma que o banco já tem não muda nada.
List<EnderecoBarracao> aplicarPendentesBarracao(
  List<EnderecoBarracao> enderecos,
  Iterable<OperacaoPendente> pendentes,
) {
  var lista = enderecos;
  for (final op in pendentes) {
    if (!op.tipo.doBarracao) continue;
    lista = [
      for (final e in lista)
        if (e.id != op.local) e else _aplicarNoEndereco(e, op),
    ];
  }
  return lista;
}

EnderecoBarracao _aplicarNoEndereco(EnderecoBarracao e, OperacaoPendente op) {
  switch (op.tipo) {
    case TipoOperacao.barracaoAtribuir:
      return e.comProduto(
        produtoCodigo: op.produtoCodigo,
        produtoNome:   op.produtoNome,
        quantidade:    op.quantidade,
      );
    case TipoOperacao.barracaoEsvaziar:
      return e.semNivel(1);
    case TipoOperacao.barracaoEmpilhar:
      // Já veio do banco (é o UUID da gaiola nova): não empilha de novo.
      if (e.nivelDaGaiola(op.uuid) != null) return e;
      return e.comGaiolaNoTopo(
            gaiolaUuid:    op.uuid,
            produtoCodigo: op.produtoCodigo,
            produtoNome:   op.produtoNome,
            quantidade:    op.quantidade,
          ) ??
          e;
    case TipoOperacao.barracaoAjustarGaiola:
      final nivel = e.nivelDaGaiola(op.rackUuid);
      return nivel == null ? e : e.comQuantidadeNoNivel(nivel, op.quantidade);
    case TipoOperacao.barracaoEsvaziarGaiola:
      final nivel = e.nivelDaGaiola(op.rackUuid);
      return nivel == null ? e : e.semNivel(nivel);
    default:
      return e;
  }
}
