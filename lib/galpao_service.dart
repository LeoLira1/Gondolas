import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'codigos_vinculados.dart';
import 'fila_gravacao.dart' show executarOperacao;
import 'galpao_config.dart';
import 'galpao_saldo.dart';
import 'galpao_scene.dart' show ProdutoNoRack, RackGalpao;
import 'gravacao_lote.dart';
import 'turso_service.dart';
import 'outbox.dart' show gerarUuidV4;

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

  /// Racks e itens dos racks mistos (ver TursoService.sqlGalpao): cada rack
  /// vem na sua linha (item_uuid NULL) seguida das linhas dos itens dele.
  static const String _sqlPilhas = TursoService.sqlGalpao;

  /// Ocupação do galpão inteiro: posição → pilha ordenada por ordem.
  ///
  /// Uma consulta só (são no máximo 516 linhas) — percorrer posição a posição
  /// custaria 129 idas ao banco para pintar um frame.
  Future<Map<int, List<RackGalpao>>> carregarPilhas() async {
    try {
      return _pilhasDasLinhas(
        await TursoService().consultarComCache(TursoService.chaveGalpao, _sqlPilhas),
      );
    } catch (_) {
      return {};
    }
  }

  /// Relê a ocupação DO SERVIDOR (sem servir a cópia) e atualiza a cópia de
  /// leitura (que a busca do mapa também usa). Null quando a leitura falhou — ao contrário de [carregarPilhas],
  /// aqui um galpão vazio por falta de rede apagaria a tela inteira.
  Future<Map<int, List<RackGalpao>>?> recarregarPilhas() async {
    try {
      final rows = await TursoService().consultarComCache(
        TursoService.chaveGalpao,
        _sqlPilhas,
        forceRefresh: true,
      );
      await TursoService().guardarConsulta(TursoService.chaveGalpao, rows);
      return _pilhasDasLinhas(rows);
    } catch (_) {
      return null;
    }
  }

  /// Relê do servidor só as [posicoes] (pelo UNIQUE(posicao, ordem)) e as
  /// troca na cópia de leitura, mantendo a ordem (posicao, ordem). É a
  /// conferência depois que a fila do galpão esvazia: antes ela relia o galpão
  /// inteiro (até 516 racks) a cada palete lançado. Rack que outro aparelho
  /// mexeu em outra posição aparece pela janela da cópia (30 s), como antes
  /// aparecia pela recarga. Sem cópia nenhuma, relê tudo.
  Future<Map<int, List<RackGalpao>>?> recarregarPosicoes(
    Set<int> posicoes,
  ) async {
    if (posicoes.isEmpty) return recarregarPilhas();
    try {
      final lista = posicoes.toList()..sort();
      final rows = await TursoService().consultarDireto(
        'SELECT rack_uuid, item_uuid, posicao, ordem, produto_codigo, '
        'produto_nome, quantidade, seq FROM $sqlProdutosGalpao WHERE posicao IN '
        '(${List.filled(lista.length, '?').join(', ')}) '
        'ORDER BY posicao, ordem, seq',
        parametros: lista,
        tipo: 'galpao_posicoes',
      );
      final copia = await TursoService().corrigirConsulta(
        TursoService.chaveGalpao,
        (r) => posicoes.contains(r['posicao']),
        rows,
        ordenar: (a, b) {
          final porPosicao = (a['posicao'] as int? ?? 0).compareTo(
            b['posicao'] as int? ?? 0,
          );
          if (porPosicao != 0) return porPosicao;
          final porOrdem = (a['ordem'] as int? ?? 0).compareTo(
            b['ordem'] as int? ?? 0,
          );
          if (porOrdem != 0) return porOrdem;
          // O rack antes dos itens dele (ver _pilhasDasLinhas).
          return (a['seq'] as int? ?? 0).compareTo(b['seq'] as int? ?? 0);
        },
      );
      return copia == null ? await recarregarPilhas() : _pilhasDasLinhas(copia);
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

  /// Saldo (sistema × endereçado) dos produtos de [codigosComRack] — os que
  /// têm rack no galpão —, mais os de [codigosExtras] (o produto que o painel
  /// está prestes a lançar e ainda não tem rack nenhum). Sem
  /// [codigosComRack], os códigos saem da cópia de leitura das pilhas.
  ///
  /// As duas metades da conta somam TODOS os códigos do mesmo produto — é o
  /// que o app do scanner faz, e a falta disso era o "sistema 388" de um
  /// produto que na mão dá 559 (171 + 388). Ver codigos_vinculados.dart. O
  /// endereçado soma TODOS os locais do produto, não só o galpão (ver a nota
  /// em galpao_saldo.dart).
  ///
  /// Nenhuma leitura própria: o estoque_mestre, o mapa de produtos e o
  /// estoque_localizado vêm das cópias que o app já guarda, cada uma com a
  /// sua janela (ver TursoService.consultarSaldos, vinculosDoMapa e
  /// consultarQuantidades). Antes eram quatro consultas de tabela inteira A
  /// CADA saldo — inclusive o de um produto só, no painel —, e o Turso cobra
  /// cada linha varrida: catalogar um palete custava umas 15 mil linhas.
  Future<Map<String, SaldoProduto>> carregarSaldos({
    Iterable<String>? codigosComRack,
    Set<String> codigosExtras = const {},
  }) async {
    try {
      // Os códigos entram como estão em galpao_racks (é a chave que a cena
      // usa para achar a cor do cubo); a normalização acontece lá dentro.
      final codigos = <String>{
        ...(codigosComRack ?? await _codigosComRack()),
        ...codigosExtras,
      }..removeWhere((c) => c.trim().isEmpty);
      if (codigos.isEmpty) return {};

      final turso = TursoService();
      final mestre = mestrePorCodigo(await turso.consultarSaldos());
      final grupos = gruposDeCodigos(
        codigos: codigos,
        produtoIdPorCodigo: await turso.vinculosDoMapa(),
        nomePorCodigo: {for (final e in mestre.entries) e.key: e.value.nome},
      );
      return montarSaldos(
        codigos: codigos,
        grupos: grupos,
        sistemaPorCodigo: {
          for (final e in mestre.entries) e.key: e.value.qtdSistema,
        },
        // Sem cópia nenhuma das quantidades a leitura FALHA em vez de vir
        // vazia: endereçado zero pintaria de vermelho todo rack do galpão.
        enderecadoPorCodigo: enderecadoPorCodigo(
          await turso.consultarQuantidades(falharSemCache: true),
        ),
      );
    } catch (_) {
      return {};
    }
  }

  /// O saldo de UM produto, mesmo que ele ainda não tenha rack no galpão — o
  /// número de que quem vai lançar precisa antes de digitar a quantidade.
  Future<SaldoProduto?> carregarSaldo(String codigo) async {
    if (codigo.trim().isEmpty) return null;
    return (await carregarSaldos(
      codigosComRack: const [],
      codigosExtras: {codigo},
    ))[codigo];
  }

  Future<Set<String>> _codigosComRack() async => {
        for (final pilha in (await carregarPilhas()).values)
          for (final rack in pilha)
            for (final p in rack.produtos) p.produtoCodigo,
      };

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
