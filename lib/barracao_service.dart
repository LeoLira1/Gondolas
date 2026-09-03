import 'package:libsql_dart/libsql_dart.dart';
// Mesmo motivo do import direto em galpao_service.dart: `client.transaction()`
// devolve um Transaction que o pacote não reexporta, e sem este import não dá
// para tipar os helpers que recebem a transação.
import 'package:libsql_dart/src/transaction.dart' show Transaction;

import 'barracao_config.dart';
import 'models.dart' show localTipoBarracao;
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
      if (n > 0) {
        _seedFeito = true;
        return true;
      }

      final agora = DateTime.now().toIso8601String();
      MutacaoOutbox? mutacao;
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
        await tx.commit();
        // Frame novo no arquivo local esperando o próximo Sincronizar — sem
        // esta marca, um push que não sai passaria por "nada a enviar".
        await TursoService().marcarGravacaoLocal();
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
    final client = await _conexao();
    if (client == null) return const [];
    try {
      final stmt = await client.prepare(
        'SELECT id, rotulo, pos_x, pos_z, produto_codigo, produto_nome, '
        'quantidade FROM barracao_enderecos ORDER BY rotulo',
      );
      final rows = await stmt.query() as List<dynamic>;
      return [
        for (final dynamic row in rows)
          if (row is Map<String, dynamic>)
            EnderecoBarracao(
              id:            row['id']     as int?    ?? 0,
              rotulo:        row['rotulo'] as String? ?? '',
              x:             (row['pos_x'] as num?)?.toDouble() ?? 0,
              z:             (row['pos_z'] as num?)?.toDouble() ?? 0,
              produtoCodigo: row['produto_codigo'] as String? ?? '',
              produtoNome:   row['produto_nome']   as String? ?? '',
              quantidade:    (row['quantidade'] as num?)?.toDouble() ?? 0,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Atribui um produto ao palete (ou troca o que estava lá) com a quantidade
  /// informada. Devolve o endereço gravado, ou null se falhou.
  ///
  /// Atribuir e corrigir a quantidade são a MESMA gravação de propósito: no
  /// barracão não existe "empilhar por cima" — o palete tem um produto e um
  /// número, e mudar qualquer um dos dois é reescrever a linha.
  Future<EnderecoBarracao?> atribuir({required int id, required String produtoCodigo,
      required String produtoNome, required double quantidade}) async {
    try {
      return await TursoService().garantirReplicaProntaParaEscrita(() =>
          _atribuir(id: id, produtoCodigo: produtoCodigo,
              produtoNome: produtoNome, quantidade: quantidade));
    } on ReplicaNaoProntaParaEscrita { return null; }
  }

  Future<EnderecoBarracao?> _atribuir({
    required int id, required String produtoCodigo,
    required String produtoNome, required double quantidade,
  }) async {
    if (quantidade <= 0) return null; // zerar é esvaziar, que é outra coisa
    final client = await _conexao();
    if (client == null) return null;
    final agora = DateTime.now().toIso8601String();
    try {
      MutacaoOutbox? mutacao;
      final tx = await client.transaction();
      try {
        final antes = await tx.query(
          'SELECT rotulo, pos_x, pos_z, produto_codigo, quantidade '
          'FROM barracao_enderecos WHERE id = ? LIMIT 1',
          positional: [id],
        );
        if (antes.isEmpty) {
          await tx.rollback();
          return null;
        }
        final rotulo = antes.first['rotulo'] as String? ?? '';
        final codigoAntes = antes.first['produto_codigo'] as String? ?? '';
        // Quantidade anterior só conta como "anterior" quando é do MESMO
        // produto: trocar o produto do palete é lançamento novo, e registrar
        // a quantidade do produto que saiu como ponto de partida do que
        // entrou faria o log mentir.
        final qtdAntes = codigoAntes == produtoCodigo
            ? (antes.first['quantidade'] as num?)?.toDouble() ?? 0
            : null;

        await tx.execute(
          'UPDATE barracao_enderecos SET produto_codigo = ?, '
          'produto_nome = ?, quantidade = ?, atualizado_em = ? WHERE id = ?',
          positional: [produtoCodigo, produtoNome, quantidade, agora, id],
        );
        await _reescreverEspelho(tx, id, produtoCodigo, quantidade, agora);
        await _registrarLog(tx, rotulo, produtoCodigo,
            anterior: qtdAntes, nova: quantidade, agora: agora);
        // O endereço do barracão tem `id` próprio e não é renumerado: a chave
        // aponta sempre para o MESMO palete, então dá para reaplicar sozinho.
        mutacao = await TursoService().abrirMutacao(
          operacao: 'barracao.atribuir',
          tabela:   'barracao_enderecos',
          chave:    {'id': id},
          estadoAnterior: {
            'produto_codigo': codigoAntes,
            'quantidade': (antes.first['quantidade'] as num?)?.toDouble() ?? 0,
          },
          estadoFinal: {
            'produto_codigo': produtoCodigo,
            'quantidade':     quantidade,
          },
          produtoCodigo: produtoCodigo,
          produtoNome:   produtoNome,
          posicao:       id,
          quantidadeAnterior:   qtdAntes,
          quantidadePretendida: quantidade,
        );
        await TursoService().carimbarMutacao(tx, mutacao);
        await tx.commit();
        // Frame novo no arquivo local esperando o próximo Sincronizar — sem
        // esta marca, um push que não sai passaria por "nada a enviar".
        await TursoService().marcarGravacaoLocal();

        return EnderecoBarracao(
          id:            id,
          rotulo:        rotulo,
          x:             (antes.first['pos_x'] as num?)?.toDouble() ?? 0,
          z:             (antes.first['pos_z'] as num?)?.toDouble() ?? 0,
          produtoCodigo: produtoCodigo,
          produtoNome:   produtoNome,
          quantidade:    quantidade,
        );
      } catch (e) {
        await tx.rollback();
        if (mutacao != null) await TursoService().abortarMutacao(mutacao);
        rethrow;
      }
    } catch (_) {
      return null;
    }
  }

  /// Tira o produto do palete — o endereço continua existindo, vazio.
  ///
  /// É o que o 0 do teclado de quantidade pede. O palete NÃO sai da tabela:
  /// ele continua no chão do barracão esperando a próxima carga, e apagar a
  /// linha recicaria o rótulo num endereço futuro (mesma lição do
  /// PaleteRegistry, ver palete_registry.dart).
  Future<EnderecoBarracao?> esvaziar({required int id, String? origem}) async {
    try {
      return await TursoService().garantirReplicaProntaParaEscrita(
          () => _esvaziar(id: id, origem: origem));
    } on ReplicaNaoProntaParaEscrita { return null; }
  }

  Future<EnderecoBarracao?> _esvaziar({required int id, String? origem}) async {
    final client = await _conexao();
    if (client == null) return null;
    final agora = DateTime.now().toIso8601String();
    try {
      MutacaoOutbox? mutacao;
      final tx = await client.transaction();
      try {
        final antes = await tx.query(
          'SELECT rotulo, pos_x, pos_z, produto_codigo, quantidade '
          'FROM barracao_enderecos WHERE id = ? LIMIT 1',
          positional: [id],
        );
        if (antes.isEmpty) {
          await tx.rollback();
          return null;
        }
        final rotulo   = antes.first['rotulo'] as String? ?? '';
        final codigo   = antes.first['produto_codigo'] as String? ?? '';
        final qtdAntes = (antes.first['quantidade'] as num?)?.toDouble() ?? 0;

        await tx.execute(
          "UPDATE barracao_enderecos SET produto_codigo = '', "
          "produto_nome = '', quantidade = 0, atualizado_em = ? WHERE id = ?",
          positional: [agora, id],
        );
        await _reescreverEspelho(tx, id, '', 0, agora);
        await _registrarLog(tx, rotulo, codigo,
            anterior: qtdAntes, nova: 0, agora: agora, origem: origem);
        // O endereço continua existindo, vazio — por isso o estado final não é
        // `null`: a linha não some, ela zera.
        mutacao = await TursoService().abrirMutacao(
          operacao: 'barracao.esvaziar',
          tabela:   'barracao_enderecos',
          chave:    {'id': id},
          estadoAnterior: {
            'produto_codigo': codigo,
            'quantidade':     qtdAntes,
          },
          estadoFinal: const {'produto_codigo': '', 'quantidade': 0},
          produtoCodigo: codigo,
          posicao:       id,
          quantidadeAnterior:   qtdAntes,
          quantidadePretendida: 0,
        );
        await TursoService().carimbarMutacao(tx, mutacao);
        await tx.commit();
        // Frame novo no arquivo local esperando o próximo Sincronizar — sem
        // esta marca, um push que não sai passaria por "nada a enviar".
        await TursoService().marcarGravacaoLocal();

        return EnderecoBarracao(
          id:     id,
          rotulo: rotulo,
          x:      (antes.first['pos_x'] as num?)?.toDouble() ?? 0,
          z:      (antes.first['pos_z'] as num?)?.toDouble() ?? 0,
        );
      } catch (e) {
        await tx.rollback();
        if (mutacao != null) await TursoService().abortarMutacao(mutacao);
        rethrow;
      }
    } catch (_) {
      return null;
    }
  }

  /// Reescreve as linhas de `estoque_localizado` do endereço.
  ///
  /// Apaga e insere, como o galpão faz por posição: o endereço tem no máximo
  /// uma linha, e reescrever é o que faz a TROCA de produto no palete não
  /// deixar a linha do produto anterior para trás — um UPDATE por chave
  /// deixaria o antigo endereçado para sempre.
  Future<void> _reescreverEspelho(Transaction tx, int id, String codigo,
      double quantidade, String agora) async {
    await tx.execute(
      'DELETE FROM estoque_localizado WHERE local_tipo = ? AND local_num = ?',
      positional: [localTipoBarracao, id],
    );
    if (codigo.trim().isEmpty || quantidade <= 0) return;
    await tx.execute(
      'INSERT INTO estoque_localizado (produto_codigo, local_tipo, '
      'local_num, face_ou_coluna, andar_ou_nivel, quantidade, atualizado_em) '
      'VALUES (?, ?, ?, 0, 0, ?, ?)',
      positional: [codigo, localTipoBarracao, id, quantidade, agora],
    );
  }

  /// Uma linha em `contagens_log` por gravação do barracão, no mesmo formato
  /// do galpão — o endereço textual aqui pode ser o rótulo puro justamente
  /// porque ele não carrega nível nenhum para vencer na primeira movimentação.
  Future<void> _registrarLog(
    Transaction tx,
    String rotulo,
    String produtoCodigo, {
    required double? anterior,
    required double nova,
    required String agora,
    String? origem,
  }) async {
    await tx.execute(
      'INSERT INTO contagens_log (produto_codigo, endereco, qtd_anterior, '
      'qtd_nova, origem, registrado_em) VALUES (?, ?, ?, ?, ?, ?)',
      positional: [
        produtoCodigo,
        'BARRACAO·$rotulo',
        anterior,
        nova,
        origem ??
            (nova == 0
                ? 'gondolas_app_barracao_exclusao'
                : 'gondolas_app_barracao'),
        agora,
      ],
    );
  }
}
