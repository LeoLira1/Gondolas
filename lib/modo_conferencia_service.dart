import 'package:libsql_dart/libsql_dart.dart';
import 'turso_service.dart';

/// Um item pendente de conferência — linha de contagem_itens (tabela do
/// dashboard Streamlit, SOMENTE LEITURA aqui) ainda não confirmada hoje.
class ItemPendente {
  final String codigo;
  final String produto;
  final String categoria;
  final double qtdEstoque;

  const ItemPendente({
    required this.codigo,
    required this.produto,
    required this.categoria,
    required this.qtdEstoque,
  });
}

/// Uma estrutura do mapa (gôndola ou estante) que contém pendentes de hoje.
class EstruturaConferencia {
  final String tipo; // 'gondola' ou 'estante'
  final int numero;
  final List<ItemPendente> itens;

  const EstruturaConferencia({
    required this.tipo,
    required this.numero,
    required this.itens,
  });

  Set<String> get codigos => itens.map((i) => i.codigo).toSet();
}

/// Resultado pronto do cruzamento entre os pendentes de contagem_itens e os
/// layouts (gôndola/estante): estruturas do mapa que precisam de conferência
/// hoje + itens cujo código não aparece em nenhum layout cadastrado.
class ModoConferenciaResultado {
  final Map<String, EstruturaConferencia> estruturas; // chave '$tipo:$numero'
  final List<ItemPendente> semEndereco;
  final int totalProdutos; // pendentes únicos de hoje (contagem_itens)

  const ModoConferenciaResultado({
    required this.estruturas,
    required this.semEndereco,
    required this.totalProdutos,
  });

  static const vazio = ModoConferenciaResultado(
    estruturas: {},
    semEndereco: [],
    totalProdutos: 0,
  );

  int get totalEstruturas => estruturas.length;
  bool get vazioHoje => totalProdutos == 0;
}

class ModoConferenciaService {
  static final ModoConferenciaService _instance =
      ModoConferenciaService._internal();
  factory ModoConferenciaService() => _instance;
  ModoConferenciaService._internal();

  // Limite de placeholders por IN(...): mantém a query bem abaixo do teto de
  // variáveis do SQLite (999) mesmo num dia com muitos pendentes.
  static const int _maxCodigosPorConsulta = 400;

  Future<LibsqlClient?> _conexao() async {
    if (!await TursoService().garantirConexao()) return null;
    return TursoService().client;
  }

  /// Busca os pendentes de contagem_itens e cruza com gondola_layout e
  /// estante_layout numa única passada — 3 queries no total (ou poucas mais,
  /// se o lote de códigos precisar ser quebrado), nunca uma por estrutura.
  Future<ModoConferenciaResultado> buscarConferenciaDoDia() async {
    final client = await _conexao();
    if (client == null) return ModoConferenciaResultado.vazio;

    try {
      final pendentes = await _buscarPendentes(client);
      if (pendentes.isEmpty) return ModoConferenciaResultado.vazio;

      final codigos = pendentes.map((p) => p.codigo).toList();
      final resultados = await Future.wait([
        _buscarEnderecosGondola(client, codigos),
        _buscarEnderecosEstante(client, codigos),
      ]);
      final gondolasPorCodigo = resultados[0];
      final estantesPorCodigo = resultados[1];

      final estruturas = <String, List<ItemPendente>>{};
      final semEndereco = <ItemPendente>[];

      for (final item in pendentes) {
        final gondolas = gondolasPorCodigo[item.codigo] ?? const <int>{};
        final estantes = estantesPorCodigo[item.codigo] ?? const <int>{};
        if (gondolas.isEmpty && estantes.isEmpty) {
          semEndereco.add(item);
          continue;
        }
        for (final g in gondolas) {
          estruturas.putIfAbsent('gondola:$g', () => []).add(item);
        }
        for (final e in estantes) {
          estruturas.putIfAbsent('estante:$e', () => []).add(item);
        }
      }

      return ModoConferenciaResultado(
        estruturas: {
          for (final entry in estruturas.entries)
            entry.key: EstruturaConferencia(
              tipo:   entry.key.split(':')[0],
              numero: int.parse(entry.key.split(':')[1]),
              itens:  entry.value,
            ),
        },
        semEndereco:  semEndereco,
        totalProdutos: pendentes.length,
      );
    } catch (_) {
      return ModoConferenciaResultado.vazio;
    }
  }

  Future<List<ItemPendente>> _buscarPendentes(LibsqlClient client) async {
    final stmt = await client.prepare(
      "SELECT codigo, produto, categoria, qtd_estoque FROM contagem_itens "
      "WHERE status = 'pendente'",
    );
    final rows = await stmt.query();
    return (rows as List<dynamic>).map((dynamic row) {
      final r = row as Map<String, dynamic>;
      return ItemPendente(
        codigo:     r['codigo']       as String? ?? '',
        produto:    r['produto']      as String? ?? '',
        categoria:  r['categoria']    as String? ?? '',
        qtdEstoque: (r['qtd_estoque'] as num?)?.toDouble() ?? 0,
      );
    }).where((i) => i.codigo.isNotEmpty).toList();
  }

  Future<Map<String, Set<int>>> _buscarEnderecosGondola(
      LibsqlClient client, List<String> codigos) async {
    final mapa = <String, Set<int>>{};
    for (var i = 0; i < codigos.length; i += _maxCodigosPorConsulta) {
      final fim = (i + _maxCodigosPorConsulta < codigos.length)
          ? i + _maxCodigosPorConsulta
          : codigos.length;
      final lote = codigos.sublist(i, fim);
      final placeholders = List.filled(lote.length, '?').join(', ');
      final stmt = await client.prepare(
        'SELECT DISTINCT produto_codigo, gondola_num FROM gondola_layout '
        'WHERE produto_codigo IN ($placeholders)',
      );
      final rows = await stmt.query(positional: lote);
      for (final dynamic row in rows as List<dynamic>) {
        final r       = row as Map<String, dynamic>;
        final codigo  = r['produto_codigo'] as String? ?? '';
        final gondola = r['gondola_num']    as int?    ?? 0;
        if (codigo.isEmpty) continue;
        mapa.putIfAbsent(codigo, () => <int>{}).add(gondola);
      }
    }
    return mapa;
  }

  Future<Map<String, Set<int>>> _buscarEnderecosEstante(
      LibsqlClient client, List<String> codigos) async {
    final mapa = <String, Set<int>>{};
    for (var i = 0; i < codigos.length; i += _maxCodigosPorConsulta) {
      final fim = (i + _maxCodigosPorConsulta < codigos.length)
          ? i + _maxCodigosPorConsulta
          : codigos.length;
      final lote = codigos.sublist(i, fim);
      final placeholders = List.filled(lote.length, '?').join(', ');
      final stmt = await client.prepare(
        'SELECT DISTINCT produto_codigo, estante_num FROM estante_layout '
        'WHERE produto_codigo IN ($placeholders)',
      );
      final rows = await stmt.query(positional: lote);
      for (final dynamic row in rows as List<dynamic>) {
        final r       = row as Map<String, dynamic>;
        final codigo  = r['produto_codigo'] as String? ?? '';
        final estante = r['estante_num']    as int?    ?? 0;
        if (codigo.isEmpty) continue;
        mapa.putIfAbsent(codigo, () => <int>{}).add(estante);
      }
    }
    return mapa;
  }
}
