import 'package:flutter/material.dart';

import 'estocados_busca.dart';
import 'barracao_service.dart';
import 'galpao_scene.dart' show corCamda;
import 'galpao_service.dart';
import 'turso_service.dart';

/// Lê a lista de material de cooperado guardado (tabela `materiais_terceiros`,
/// a mesma do app Estocados). Só leitura: nada daqui vai para o saldo.
Future<List<ItemEstocado>> carregarEstocados({bool forceRefresh = false}) async {
  final rows = await TursoService().consultarComCache(
    'estocados',
    'SELECT * FROM materiais_terceiros WHERE saldo > 0 '
        'ORDER BY razao_social, descricao',
    forceRefresh: forceRefresh,
  );
  return rows.map(ItemEstocado.deLinha).toList();
}

/// Onde cada palete de estocado está (nome do palete → endereços). Lê o que o
/// mapa já guarda de galpão e barracão; falha vira "sem endereços", nunca erro.
Future<Map<String, List<String>>> carregarEnderecosDosEstocados() async {
  try {
    final pilhas = await GalpaoService().carregarPilhas();
    final barracao = await BarracaoService().carregarEnderecos();
    return enderecosDosEstocados(
      galpao: [
        for (final pilha in pilhas.values)
          for (final r in pilha)
            (
              posicao: r.posicao,
              ordem: r.ordem,
              codigo: r.produtoCodigo,
              nome: r.produtoNome,
            ),
      ],
      barracao: [
        for (final e in barracao)
          (rotulo: e.rotulo, codigo: e.produtoCodigo, nome: e.produtoNome),
      ],
    );
  } catch (_) {
    return const {};
  }
}

/// Botão da barra de cima (galpão e barracão) que abre a busca de estocados.
class BotaoEstocados extends StatelessWidget {
  const BotaoEstocados({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => abrirEstocados(context),
      child: Container(
        height: 46,
        width: 46,
        decoration: BoxDecoration(
          color: const Color(0xEE141518),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: const Icon(
          Icons.inventory_2_outlined,
          color: Color(0xFF8a877f),
          size: 20,
        ),
      ),
    );
  }
}

Future<void> abrirEstocados(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF141518),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const _EstocadosSheet(),
  );
}

class _EstocadosSheet extends StatefulWidget {
  const _EstocadosSheet();

  @override
  State<_EstocadosSheet> createState() => _EstocadosSheetState();
}

class _EstocadosSheetState extends State<_EstocadosSheet> {
  final _busca = TextEditingController();
  List<ItemEstocado> _itens = const [];
  Map<String, List<String>> _enderecos = const {};
  bool _carregando = true;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    _busca.dispose();
    super.dispose();
  }

  Future<void> _carregar({bool forceRefresh = false}) async {
    setState(() {
      _carregando = true;
      _erro = null;
    });
    try {
      final itens = await carregarEstocados(forceRefresh: forceRefresh);
      final enderecos = await carregarEnderecosDosEstocados();
      if (!mounted) return;
      setState(() {
        _itens = itens;
        _enderecos = enderecos;
        _carregando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = 'Não consegui ler os estocados (tabela materiais_terceiros).';
        _carregando = false;
      });
    }
  }

  String _qtd(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  Widget build(BuildContext context) {
    final achados = buscarEstocados(_busca.text, _itens);
    // Agrupa por cooperado mantendo a ordem do banco.
    final grupos = <String, List<ItemEstocado>>{};
    for (final i in achados) {
      grupos.putIfAbsent(i.cooperado, () => []).add(i);
    }
    final altura = MediaQuery.of(context).size.height * 0.85;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: altura,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.inventory_2_outlined,
                      color: corCamda, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Produtos estocados',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _carregar(forceRefresh: true),
                    icon: const Icon(Icons.refresh, color: Color(0xFF8a877f)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _busca,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Cooperado, produto ou código',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                  prefixIcon: const Icon(Icons.search, color: corCamda),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.06),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (!_carregando && _erro == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${achados.length} itens · ${grupos.length} cooperados',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _carregando
                  ? const Center(child: CircularProgressIndicator())
                  : _erro != null
                      ? Center(
                          child: Text(
                            _erro!,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          children: [
                            for (final g in grupos.entries) ...[
                              Padding(
                                padding: const EdgeInsets.only(top: 12, bottom: 4),
                                child: Text(
                                  g.key.isEmpty ? '(sem cooperado)' : g.key,
                                  style: const TextStyle(
                                    color: corCamda,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              for (final i in g.value) _linha(i),
                            ],
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _linha(ItemEstocado i) {
    final detalhe = [
      if (i.codigo.isNotEmpty) i.codigo,
      if (i.armazem.isNotEmpty) 'arm ${i.armazem}',
      if (i.documento.isNotEmpty) 'doc ${i.documento}',
    ].join(' · ');
    final onde = _enderecos[nomeDoPalete(i)] ?? const <String>[];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i.produto,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                if (detalhe.isNotEmpty)
                  Text(
                    detalhe,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 11,
                    ),
                  ),
                Text(
                  onde.isEmpty ? 'sem endereço' : '📍 ${onde.join('  ·  ')}',
                  style: TextStyle(
                    color: onde.isEmpty
                        ? Colors.white.withValues(alpha: 0.30)
                        : corCamda,
                    fontSize: 11,
                    fontWeight: onde.isEmpty ? FontWeight.w400 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _qtd(i.saldo),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
