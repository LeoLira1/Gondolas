import 'package:flutter/foundation.dart' show visibleForTesting;

import 'models.dart';
import 'turso_service.dart';

/// Palete de madeira do piso, cadastrado em RUNTIME na tabela `paletes` —
/// diferente das estantes e expositores, que são const em tempo de
/// compilação, o número de paletes na loja é variável (entram e saem
/// conforme a necessidade). O palete reutiliza a infra de estante:
/// local_tipo 'estante', número próprio >= paleteNumMin (101), slot sempre 0.
class Palete {
  final int    num;      // >= paleteNumMin; nunca reciclado (ver desativar)
  final String apelido;  // ex.: "Palete óleo — corredor 3"
  // posX/posZ em METROS na escala do mapa da loja (lojaW = 10,0 × lojaH =
  // 14,0 — as medidas do palete, 1,20 × 1,00 m, batem com essa escala);
  // rotacao em GRAUS, sentido horário visto de cima, 0 = frente pro corredor.
  final double posX, posZ, rotacao;
  final int    colunas, fileiras;
  final bool   ativo;

  const Palete({
    required this.num,
    required this.apelido,
    required this.posX,
    required this.posZ,
    required this.rotacao,
    this.colunas = colunasPalete,
    this.fileiras = fileirasPalete,
    this.ativo = true,
  });

  Palete copyWith({
    String? apelido,
    double? posX,
    double? posZ,
    double? rotacao,
    bool?   ativo,
  }) => Palete(
        num:      num,
        apelido:  apelido ?? this.apelido,
        posX:     posX    ?? this.posX,
        posZ:     posZ    ?? this.posZ,
        rotacao:  rotacao ?? this.rotacao,
        colunas:  colunas,
        fileiras: fileiras,
        ativo:    ativo   ?? this.ativo,
      );
}

/// Catálogo em memória dos paletes cadastrados. Singleton no estilo do
/// TursoService: carregado no fim do init() da conexão (os paletes precisam
/// estar em memória antes do primeiro build do mapa e do carrossel) e
/// recarregado a cada sincronização. A tabela `paletes` vive no mesmo banco
/// (embedded replica com offline writes), então o cache offline segue a
/// mesma estratégia das outras tabelas — nada extra a fazer aqui.
class PaleteRegistry {
  static final PaleteRegistry _instance = PaleteRegistry._internal();
  factory PaleteRegistry() => _instance;
  PaleteRegistry._internal();

  // Todas as linhas da tabela, inclusive as inativas — a alocação de número
  // e o byNum precisam enxergar paletes desativados.
  List<Palete> _paletes = const [];

  // Modo de teste: as operações trabalham só na lista em memória, espelhando
  // a semântica do SQL (inclusive o MAX sobre TODAS as linhas na alocação de
  // número, que é o que garante a não-reciclagem). Permite testar alocação e
  // ordemNavegacaoEstantes sem banco.
  @visibleForTesting
  bool modoMemoria = false;

  @visibleForTesting
  void substituirEmMemoria(List<Palete> paletes) {
    _paletes = List.of(paletes)..sort((a, b) => a.num.compareTo(b.num));
  }

  /// Paletes ativos, ordenados por número (a ordem do carrossel).
  List<Palete> get ativos =>
      _paletes.where((p) => p.ativo).toList(growable: false);

  /// Palete pelo número (ativo ou não), ou null se nunca cadastrado.
  Palete? byNum(int n) {
    for (final p in _paletes) {
      if (p.num == n) return p;
    }
    return null;
  }

  /// (Re)carrega o catálogo da tabela. Usa a conexão já aberta do
  /// TursoService (é chamado de dentro do init() dele — chamar init() aqui
  /// entraria em recursão). Falha de leitura mantém o cache anterior.
  Future<void> carregar() async {
    if (modoMemoria) return;
    final client = TursoService().client;
    if (client == null) return;
    try {
      final stmt = await client.prepare(
        'SELECT num, apelido, pos_x, pos_z, rotacao, colunas, fileiras, ativo '
        'FROM paletes ORDER BY num',
      );
      final rows = await stmt.query();
      _paletes = (rows as List<dynamic>).map((dynamic row) {
        final r = row as Map<String, dynamic>;
        return Palete(
          num:      r['num']     as int?    ?? 0,
          apelido:  r['apelido'] as String? ?? '',
          posX:     (r['pos_x']   as num?)?.toDouble() ?? 0,
          posZ:     (r['pos_z']   as num?)?.toDouble() ?? 0,
          rotacao:  (r['rotacao'] as num?)?.toDouble() ?? 0,
          colunas:  r['colunas']  as int? ?? colunasPalete,
          fileiras: r['fileiras'] as int? ?? fileirasPalete,
          ativo:    (r['ativo']   as int? ?? 1) != 0,
        );
      }).toList(growable: false);
    } catch (_) {
      // Tabela ainda não criada (replica vazia antes do bootstrap) ou leitura
      // falhou: mantém o que já estava em memória.
    }
  }

  /// Cadastra um palete novo e devolve o número alocado (null se falhou).
  ///
  /// A alocação é MAX(num) + 1 varrendo TODAS as linhas, inclusive as
  /// inativas — deliberadamente sem AUTOINCREMENT. É isso que garante que
  /// número de palete retirado nunca volta: se o 103 sair e o próximo
  /// entrasse como 103, ele herdaria os endereços velhos do 103 em
  /// estoque_localizado e viraria divergência fantasma (mesma lição das
  /// estantes 3 e 4, ver estantesRemovidas). A garantia só se sustenta se as
  /// linhas desativadas PERMANECEREM na tabela — um DELETE FROM paletes
  /// quebra a não-reciclagem.
  /// posX/posZ/rotacao ficam em 0 por padrão: o palete não é desenhado no mapa
  /// da loja (como a estante 5, ele só existe no carrossel de detalhes), então
  /// não há posição a informar. Os parâmetros continuam aqui para o dia em que
  /// o palete ganhar geometria no mapa — aí é só passar os valores, sem mudar
  /// a assinatura nem a tabela.
  Future<int?> criar({
    String apelido = '',
    double posX = 0,
    double posZ = 0,
    double rotacao = 0,
  }) async {
    if (modoMemoria) {
      final num = _maxNumEmMemoria() + 1;
      substituirEmMemoria([
        ..._paletes,
        Palete(num: num, apelido: apelido, posX: posX, posZ: posZ,
            rotacao: rotacao),
      ]);
      return num;
    }
    if (!await TursoService().garantirConexao()) return null;
    final client = TursoService().client!;
    try {
      final stmtMax = await client.prepare(
        'SELECT COALESCE(MAX(num), ${paleteNumMin - 1}) + 1 AS proximo '
        'FROM paletes',
      );
      final rows = await stmtMax.query() as List<dynamic>;
      final num  =
          (rows.first as Map<String, dynamic>)['proximo'] as int? ?? 0;
      if (num < paleteNumMin) return null;

      final stmtIns = await client.prepare(
        'INSERT INTO paletes '
        '(num, apelido, pos_x, pos_z, rotacao, colunas, fileiras, ativo, criado_em) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)',
      );
      await stmtIns.query(positional: [
        num,
        apelido,
        posX,
        posZ,
        rotacao,
        colunasPalete,
        fileirasPalete,
        DateTime.now().toIso8601String(),
      ]);
      await carregar();
      TursoService().marcarGravacaoLocal();
      return num;
    } catch (_) {
      return null;
    }
  }

  int _maxNumEmMemoria() =>
      _paletes.fold(paleteNumMin - 1, (max, p) => p.num > max ? p.num : max);

  /// Atualiza apelido/posição/rotação (e demais campos) do palete.
  Future<bool> atualizar(Palete p) async {
    if (modoMemoria) {
      substituirEmMemoria(
          [for (final q in _paletes) q.num == p.num ? p : q]);
      return true;
    }
    if (!await TursoService().garantirConexao()) return false;
    try {
      final stmt = await TursoService().client!.prepare(
        'UPDATE paletes SET apelido = ?, pos_x = ?, pos_z = ?, rotacao = ?, '
        'colunas = ?, fileiras = ?, ativo = ? WHERE num = ?',
      );
      await stmt.query(positional: [
        p.apelido,
        p.posX,
        p.posZ,
        p.rotacao,
        p.colunas,
        p.fileiras,
        p.ativo ? 1 : 0,
        p.num,
      ]);
      await carregar();
      TursoService().marcarGravacaoLocal();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Desativa o palete — UPDATE ativo = 0, nunca DELETE. A linha fica na
  /// tabela de propósito: é ela que segura o MAX(num) e impede que o número
  /// seja reciclado por um palete futuro (ver criar()). Os endereços antigos
  /// do palete em estoque_localizado continuam no banco, como nos removidos
  /// da parede — o produto deve ser recadastrado em outro endereço.
  Future<bool> desativar(int num) async {
    if (modoMemoria) {
      substituirEmMemoria([
        for (final q in _paletes) q.num == num ? q.copyWith(ativo: false) : q
      ]);
      return true;
    }
    if (!await TursoService().garantirConexao()) return false;
    try {
      final stmt = await TursoService().client!.prepare(
        'UPDATE paletes SET ativo = 0 WHERE num = ?',
      );
      await stmt.query(positional: [num]);
      await carregar();
      TursoService().marcarGravacaoLocal();
      return true;
    } catch (_) {
      return false;
    }
  }
}
