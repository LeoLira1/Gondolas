import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'configuracao_page.dart';
import 'estante_edr300_scene.dart';
import 'estante_scene.dart';
import 'gondola_scene.dart';
import 'loja_scene.dart';
import 'models.dart';
import 'turso_service.dart';

void main() => runApp(const CamdaApp());

class CamdaApp extends StatelessWidget {
  const CamdaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CAMDA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2e6b46),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const LojaPage(),
    );
  }
}

// ── Main Navigation ───────────────────────────────────────────────────────────

class _MainNav extends StatefulWidget {
  const _MainNav();

  @override
  State<_MainNav> createState() => _MainNavState();
}

class _MainNavState extends State<_MainNav> {
  int _tab = 0;

  static const _pages = <Widget>[GondolaPage(), EstantePage()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex:           _tab,
        onDestinationSelected:   (i) => setState(() => _tab = i),
        backgroundColor:         const Color(0xFF0d1117),
        indicatorColor:          const Color(0xFF2e6b46),
        labelBehavior:           NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon:         Icon(Icons.view_carousel_outlined),
            selectedIcon: Icon(Icons.view_carousel),
            label:        'Gôndola',
          ),
          NavigationDestination(
            icon:         Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view),
            label:        'Estante',
          ),
        ],
      ),
    );
  }
}

// ── Catálogo mock (fallback quando sem conexão) ───────────────────────────────

const List<Produto> _catalogoMock = [
  Produto(codigo: 'lubrax',  nome: 'Óleo Lubrax',  categoria: 'Lubrificantes', corHex: '#2e7d4f'),
  Produto(codigo: 'fogo',    nome: 'Botina Fogo',   categoria: 'Calçados',      corHex: '#2c5fb0'),
  Produto(codigo: 'garotti', nome: 'Bota Garotti',  categoria: 'Calçados',      corHex: '#2c5fb0'),
  Produto(codigo: 'chapeu',  nome: 'Chapéu Palha',  categoria: 'Chapéus',       corHex: '#d9b46a'),
  Produto(codigo: 'lona',    nome: 'Lona 5×7',      categoria: 'Lonas',         corHex: '#e87722'),
];

// ══════════════════════════════════════════════════════════════════════════════
// LojaPage — tela inicial com mapa da loja
// ══════════════════════════════════════════════════════════════════════════════

class LojaPage extends StatefulWidget {
  // Opcional: abrir já com uma estrutura selecionada (ex: vindo de GondolaPage)
  final String? itemTipoInicial;
  final int?    itemNumeroInicial;

  const LojaPage({super.key, this.itemTipoInicial, this.itemNumeroInicial});

  @override
  State<LojaPage> createState() => _LojaPageState();
}

class _LojaPageState extends State<LojaPage> {
  int?               _selecionadoIdx;
  ProdutoEncontrado? _produtoSelecionado;
  Vec3?              _focarEm;

  final _searchCtrl  = TextEditingController();
  final _searchFocus = FocusNode();
  List<ProdutoEncontrado> _sugestoes      = [];
  bool                    _showSugestoes  = false;
  bool                    _buscando       = false;
  bool                    _semResultados  = false;
  Timer?                  _debounce;

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() {
      if (!_searchFocus.hasFocus) {
        setState(() {
          _showSugestoes = false;
          _semResultados = false;
        });
      }
    });

    TursoService().init();

    if (widget.itemTipoInicial != null && widget.itemNumeroInicial != null) {
      final idx = itensLoja.indexWhere((it) =>
          it.tipo == widget.itemTipoInicial && it.numero == widget.itemNumeroInicial);
      if (idx != -1) {
        _selecionadoIdx = idx;
        _focarEm = Vec3(itensLoja[idx].x, 0.2, itensLoja[idx].z);
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _onSelecionado(int? idx) {
    setState(() {
      _selecionadoIdx    = idx;
      _produtoSelecionado = null;
      if (idx != null) {
        _focarEm = Vec3(itensLoja[idx].x, 0.2, itensLoja[idx].z);
      }
    });
    _searchFocus.unfocus();
  }

  void _onSearchChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _sugestoes     = [];
        _showSugestoes = false;
        _buscando      = false;
        _semResultados = false;
      });
      return;
    }
    setState(() { _buscando = true; _semResultados = false; });
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final resultados = await TursoService().buscarProdutoGlobal(q.trim());
      if (!mounted) return;
      setState(() {
        _sugestoes     = resultados;
        _showSugestoes = resultados.isNotEmpty;
        _buscando      = false;
        _semResultados = resultados.isEmpty;
      });
    });
  }

  void _selecionarProduto(ProdutoEncontrado p) {
    final idx = itensLoja.indexWhere(
        (it) => it.tipo == p.tipo && it.numero == p.numero);
    setState(() {
      _selecionadoIdx    = idx != -1 ? idx : null;
      _produtoSelecionado = p;
      _searchCtrl.text   = p.nome;
      _sugestoes         = [];
      _showSugestoes     = false;
      if (idx != -1) {
        _focarEm = Vec3(itensLoja[idx].x, 0.2, itensLoja[idx].z);
      }
    });
    _searchFocus.unfocus();
  }

  void _verDetalhes(int idx) {
    final item = itensLoja[idx];
    if (item.tipo == 'gondola') {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => GondolaPage(
          gondolaInicial: item.numero,
          produtoDestacado: _produtoSelecionado != null
              ? ProdutoLoja(
                  nome:   _produtoSelecionado!.nome,
                  tipo:   _produtoSelecionado!.tipo,
                  numero: _produtoSelecionado!.numero,
                  nivel:  _produtoSelecionado!.nivelDescricao,
                )
              : null,
        ),
      ));
    } else if (item.numero == 8) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => const EstanteEdr300Page(),
      ));
    } else {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => EstantePage(estanteInicial: item.numero),
      ));
    }
  }

  void _limparBusca() {
    _debounce?.cancel();
    _searchCtrl.clear();
    setState(() {
      _selecionadoIdx     = null;
      _produtoSelecionado = null;
      _sugestoes          = [];
      _showSugestoes      = false;
      _buscando           = false;
      _semResultados      = false;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final item = _selecionadoIdx != null ? itensLoja[_selecionadoIdx!] : null;

    return Scaffold(
      backgroundColor: const Color(0xFF0b0c0e),
      body: Stack(
        children: [
          // ── Cena 3D (fundo) ─────────────────────────────────────────────
          LojaScene(
            selecionadoIdx: _selecionadoIdx,
            onSelecionado:  _onSelecionado,
            onVerDetalhes:  _verDetalhes,
            focarEm:        _focarEm,
          ),

          // ── HUD superior: busca + legenda + título ───────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Linha: campo de busca + legenda
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _SearchBox(
                            controller:    _searchCtrl,
                            focusNode:     _searchFocus,
                            sugestoes:     _sugestoes,
                            showSugestoes: _showSugestoes,
                            buscando:      _buscando,
                            semResultados: _semResultados,
                            onChanged:     _onSearchChanged,
                            onSelecionar:  _selecionarProduto,
                            onClear:       _searchCtrl.text.isNotEmpty ? _limparBusca : null,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const _LegendRow(),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Título / dica
                    Text(
                      'CAMDA · Mapa da loja — toque numa estrutura ou busque um produto',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.45),
                        fontSize: 11,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Card inferior ────────────────────────────────────────────────
          if (item != null)
            Positioned(
              bottom: 24,
              left: 20,
              right: 20,
              child: _LocationCard(
                item:    item,
                produto: _produtoSelecionado,
                onVerDetalhes: () => _verDetalhes(_selecionadoIdx!),
              ),
            ),
        ],
      ),
    );
  }
}

// ── _SearchBox ────────────────────────────────────────────────────────────────

class _SearchBox extends StatelessWidget {
  final TextEditingController          controller;
  final FocusNode                      focusNode;
  final List<ProdutoEncontrado>        sugestoes;
  final bool                           showSugestoes;
  final bool                           buscando;
  final bool                           semResultados;
  final void Function(String)          onChanged;
  final void Function(ProdutoEncontrado) onSelecionar;
  final VoidCallback?                  onClear;

  const _SearchBox({
    required this.controller,
    required this.focusNode,
    required this.sugestoes,
    required this.showSugestoes,
    required this.buscando,
    required this.semResultados,
    required this.onChanged,
    required this.onSelecionar,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // TextField
        Container(
          decoration: BoxDecoration(
            color: const Color(0xEE141518),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
          ),
          child: TextField(
            controller: controller,
            focusNode:  focusNode,
            onChanged:  onChanged,
            style: const TextStyle(color: Color(0xFFf0eee9), fontSize: 14),
            decoration: InputDecoration(
              hintText:      'Buscar produto...',
              hintStyle:     const TextStyle(color: Color(0xFF7d7a74)),
              prefixIcon:    const Icon(Icons.search, color: Color(0xFF8a877f), size: 18),
              suffixIcon:    onClear != null
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 16, color: Color(0xFF8a877f)),
                      onPressed: onClear,
                    )
                  : null,
              border:        InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        // Dropdown: loading / sem resultado / lista
        if (buscando || showSugestoes || semResultados)
          Container(
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: const Color(0xF7141518),
              border: Border.all(color: Colors.white.withOpacity(0.09)),
              borderRadius: BorderRadius.circular(12),
            ),
            constraints: const BoxConstraints(maxHeight: 260),
            child: buscando && sugestoes.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF8a877f),
                        ),
                      ),
                    ),
                  )
                : semResultados
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                        child: Text(
                          'Nenhum produto encontrado',
                          style: TextStyle(color: Color(0xFF7d7a74), fontSize: 13),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap:  true,
                        padding:     EdgeInsets.zero,
                        itemCount:   sugestoes.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: Colors.white.withOpacity(0.05)),
                        itemBuilder: (_, i) {
                          final p   = sugestoes[i];
                          final cor = p.tipo == 'gondola' ? corGondolaLoja : corEstanteLoja;
                          return InkWell(
                            onTap: () => onSelecionar(p),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.nome,
                                      style: const TextStyle(
                                          color: Color(0xFFf0eee9), fontSize: 13)),
                                  const SizedBox(height: 3),
                                  Row(children: [
                                    Container(
                                      width: 7, height: 7,
                                      decoration: BoxDecoration(
                                        color: cor, borderRadius: BorderRadius.circular(2)),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      '${p.tipo == 'gondola' ? 'Gôndola' : 'Estante'} nº ${p.numero} · ${p.nivelDescricao}',
                                      style: const TextStyle(
                                          color: Color(0xFF9b9893), fontSize: 11),
                                    ),
                                  ]),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
      ],
    );
  }
}

// ── _LegendRow ────────────────────────────────────────────────────────────────

class _LegendRow extends StatelessWidget {
  const _LegendRow();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _chip(corGondolaLoja, 'Gôndola', hexagon: true),
        const SizedBox(height: 6),
        _chip(corEstanteLoja, 'Estante'),
      ],
    );
  }

  Widget _chip(Color cor, String label, {bool hexagon = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x8C141416),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipPath(
            clipper: hexagon ? _HexClipper() : null,
            child: Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: cor,
                borderRadius: hexagon ? null : BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFFcfcdc7))),
        ],
      ),
    );
  }
}

class _HexClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size s) {
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final angle = i * 2 * math.pi / 6 - math.pi / 6;
      final px = s.width  / 2 + s.width  / 2 * math.cos(angle);
      final py = s.height / 2 + s.height / 2 * math.sin(angle);
      i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(_) => false;
}

// ── _LocationCard ─────────────────────────────────────────────────────────────

class _LocationCard extends StatelessWidget {
  final ItemLoja           item;
  final ProdutoEncontrado? produto;
  final VoidCallback?      onVerDetalhes;

  const _LocationCard({
    required this.item,
    this.produto,
    this.onVerDetalhes,
  });

  @override
  Widget build(BuildContext context) {
    final cor    = item.tipo == 'gondola' ? corGondolaLoja : corEstanteLoja;
    final prefixo = item.tipo == 'gondola' ? 'G' : 'E';
    final tipoLabel = item.tipo == 'gondola' ? 'Gôndola' : 'Estante';

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xEE16171A),
        border: Border.all(color: Colors.white.withOpacity(0.09)),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Número em destaque
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 10, height: 10,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: cor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Text(
                '$prefixo${item.numero}',
                style: TextStyle(
                  color: cor,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  height: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            produto != null
                ? '${produto!.nome} · $tipoLabel nº ${item.numero} · ${produto!.nivelDescricao}'
                : '$tipoLabel nº ${item.numero}',
            style: const TextStyle(
              color: Color(0xFFb0ada8),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (onVerDetalhes != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onVerDetalhes,
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('Ver detalhes'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2e6b46),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// GondolaPage
// ══════════════════════════════════════════════════════════════════════════════

class GondolaPage extends StatefulWidget {
  final int          gondolaInicial;
  final ProdutoLoja? produtoDestacado;

  const GondolaPage({
    super.key,
    this.gondolaInicial   = 1,
    this.produtoDestacado,
  });

  @override
  State<GondolaPage> createState() => _GondolaPageState();
}

class _GondolaPageState extends State<GondolaPage> {
  late int _gondolaAtual;
  String? _produtoSelecionadoId;
  String? _destacadoCodigo;
  Timer?  _highlightTimer;
  String? _resultadoBusca;

  final Map<int, List<CaixaColocada>> _caixas = {};

  List<Produto> _produtos           = [];
  bool          _dbConectado        = false;
  bool          _carregandoProdutos = false;
  bool          _carregandoLayout   = false;
  bool          _salvando           = false;

  // null = nenhum aberto, 1 = Adicionar, 2 = Buscar
  int? _expanderAberto;

  // Expander 1 — Adicionar
  final _ctrl1 = TextEditingController();
  List<Produto> _sugestoes1 = [];
  Produto? _produtoChip;

  // Expander 2 — Buscar
  final _ctrl2 = TextEditingController();
  List<Produto> _sugestoes2 = [];

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<Produto> get _catalogoAtual =>
      _produtos.isNotEmpty ? _produtos : _catalogoMock;

  List<CaixaColocada> get _caixasAtuais => _caixas[_gondolaAtual] ?? const [];

  Map<String, Color> get _corPorProduto =>
      {for (final p in _catalogoAtual) p.codigo: p.cor};

  List<Produto> _filtrarProdutos(String query) {
    if (query.length < 2) return [];
    final q = query.toLowerCase();
    return _catalogoAtual
        .where((p) =>
            p.nome.toLowerCase().contains(q) ||
            p.codigo.toLowerCase().contains(q))
        .take(8)
        .toList();
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _gondolaAtual = widget.gondolaInicial;
    _inicializar();
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _ctrl1.dispose();
    _ctrl2.dispose();
    super.dispose();
  }

  Future<void> _inicializar() async {
    setState(() {
      _carregandoProdutos = true;
      _dbConectado        = false;
    });

    await TursoService().init();
    if (!mounted) return;

    final conectado = TursoService().isConnected;
    setState(() => _dbConectado = conectado);

    if (conectado) {
      final produtos = await TursoService().fetchProdutos();
      if (!mounted) return;
      setState(() {
        _produtos           = produtos;
        _carregandoProdutos = false;
      });
      _carregarLayout(_gondolaAtual);
    } else {
      setState(() {
        _produtos           = [];
        _carregandoProdutos = false;
      });
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _trocarGondola(int delta) {
    final nova = (_gondolaAtual + delta).clamp(1, 12);
    setState(() {
      _gondolaAtual     = nova;
      _carregandoLayout = _dbConectado;
    });
    if (_dbConectado) _carregarLayout(nova);
  }

  Future<void> _carregarLayout(int gondolaNum) async {
    final layouts = await TursoService().fetchLayout(gondolaNum);
    if (!mounted) return;
    setState(() {
      _caixas[gondolaNum] = layouts
          .map((l) => CaixaColocada(
                andar:     l.andar,
                produtoId: l.produtoCodigo,
                x:         l.posX,
                z:         l.posZ,
              ))
          .toList();
      if (_gondolaAtual == gondolaNum) _carregandoLayout = false;
    });
  }

  void _onTapAndar(int andar, double x, double z) {
    if (_produtoSelecionadoId == null) return;
    setState(() {
      _caixas[_gondolaAtual] = [
        ..._caixasAtuais,
        CaixaColocada(
          andar:     andar,
          produtoId: _produtoSelecionadoId!,
          x:         x,
          z:         z,
        ),
      ];
    });
  }

  void _limparGondola() => setState(() => _caixas.remove(_gondolaAtual));

  void _limparPorProduto(String produtoId) {
    setState(() {
      final restantes = _caixasAtuais.where((c) => c.produtoId != produtoId).toList();
      if (restantes.isEmpty) {
        _caixas.remove(_gondolaAtual);
      } else {
        _caixas[_gondolaAtual] = restantes;
      }
    });
  }

  void _mostrarDialogLimpar() {
    final idsNaGondola = _caixasAtuais.map((c) => c.produtoId).toSet();
    final produtos = _catalogoAtual.where((p) => idsNaGondola.contains(p.codigo)).toList();

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Limpar produto',
          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...produtos.map((p) {
              final qtd = _caixasAtuais.where((c) => c.produtoId == p.codigo).length;
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  Navigator.pop(ctx);
                  _limparPorProduto(p.codigo);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: p.cor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.nome, style: const TextStyle(color: Colors.white, fontSize: 13)),
                            Text(
                              '$qtd ${qtd == 1 ? 'unidade' : 'unidades'}',
                              style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.delete_outline, color: Color(0xFFe57373), size: 20),
                    ],
                  ),
                ),
              );
            }),
            if (produtos.length > 1) ...[
              const Divider(color: Color(0xFF2a3540), height: 20),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  Navigator.pop(ctx);
                  showDialog<void>(
                    context: context,
                    builder: (ctx2) => AlertDialog(
                      backgroundColor: const Color(0xFF141a22),
                      surfaceTintColor: Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      title: const Text(
                        'Limpar tudo?',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      content: const Text(
                        'Todos os produtos desta gôndola serão removidos.',
                        style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 13),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx2),
                          child: const Text('Cancelar', style: TextStyle(color: Color(0xFF8a9aa8))),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(ctx2);
                            _limparGondola();
                          },
                          child: const Text('Limpar tudo', style: TextStyle(color: Color(0xFFe57373))),
                        ),
                      ],
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.delete_forever, color: Color(0xFFe57373), size: 20),
                      SizedBox(width: 10),
                      Text(
                        'Limpar tudo',
                        style: TextStyle(color: Color(0xFFe57373), fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xFF8a9aa8))),
          ),
        ],
      ),
    );
  }

  Future<void> _salvarLayout() async {
    if (!_dbConectado) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Configure o banco em ⚙️ para salvar no Turso'),
        backgroundColor: Color(0xFF1a3040),
        duration: Duration(seconds: 3),
      ));
      return;
    }

    setState(() => _salvando = true);

    final produtoMap = {for (final p in _produtos) p.codigo: p};
    final itens = _caixasAtuais.map((c) {
      final produto = produtoMap[c.produtoId];
      return CaixaLayout(
        gondolaNum:    _gondolaAtual,
        andar:         c.andar,
        produtoCodigo: c.produtoId,
        produtoNome:   produto?.nome ?? c.produtoId,
        posX:          c.x,
        posZ:          c.z,
        corHex:        produto?.corHex ?? '#888888',
      );
    }).toList();

    final ok = await TursoService().salvarLayout(_gondolaAtual, itens);
    if (!mounted) return;
    setState(() => _salvando = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Layout salvo ✓' : 'Erro ao salvar'),
      backgroundColor: ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _buscarProduto(Produto produto) async {
    if (!_dbConectado) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Configure o banco em ⚙️ para buscar no Turso'),
        backgroundColor: Color(0xFF1a3040),
        duration: Duration(seconds: 3),
      ));
      return;
    }

    final encontrado = await TursoService().buscarProduto(produto.codigo);
    if (!mounted) return;

    if (encontrado == null) {
      // fallback: tenta na estante
      final naEstante =
          await TursoService().buscarProdutoEstante(produto.codigo);
      if (!mounted) return;

      if (naEstante != null) {
        const nivelNomes = ['Nível 1', 'Nível 2', 'Nível 3', 'Nível 4'];
        const colNomes   = ['Col. 1',  'Col. 2',  'Col. 3' ];
        final locEstante =
            '📦 ${produto.nome}\n'
            'Estante ${naEstante.estanteNum} · ${colNomes[naEstante.coluna.clamp(0, 2)]} · '
            '${nivelNomes[naEstante.nivel.clamp(0, 3)]} · Slot ${naEstante.slot + 1}';
        setState(() => _resultadoBusca = locEstante);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(locEstante.replaceAll('\n', ' — ')),
          backgroundColor: const Color(0xFF2a3a1a),
          duration: const Duration(seconds: 6),
        ));
      } else {
        setState(() => _resultadoBusca = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            '${produto.nome} não encontrado em nenhuma gôndola ou estante.\n'
            'Use "Adicionar produto" para cadastrar.',
          ),
          backgroundColor: const Color(0xFF5a1a1a),
          duration: const Duration(seconds: 4),
        ));
      }
      return;
    }

    // Navigate to the gondola and load its layout
    setState(() {
      _gondolaAtual     = encontrado.gondolaNum;
      _carregandoLayout = true;
      _expanderAberto   = null;
      _sugestoes2       = [];
    });
    _ctrl2.clear();

    final layouts = await TursoService().fetchLayout(encontrado.gondolaNum);
    if (!mounted) return;

    _highlightTimer?.cancel();
    final andarNome = ['Base', 'Meio', 'Topo'][encontrado.andar.clamp(0, 2)];
    setState(() {
      _caixas[encontrado.gondolaNum] = layouts
          .map((l) => CaixaColocada(
                andar:     l.andar,
                produtoId: l.produtoCodigo,
                x:         l.posX,
                z:         l.posZ,
              ))
          .toList();
      _carregandoLayout = false;
      _destacadoCodigo  = produto.codigo;
      _resultadoBusca   = '📍 ${produto.nome}\nGôndola ${encontrado.gondolaNum} · Andar $andarNome';
    });

    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _destacadoCodigo = null);
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        '📍 ${produto.nome} → Gôndola ${encontrado.gondolaNum}, Andar $andarNome',
      ),
      backgroundColor: const Color(0xFF1a3a2a),
      duration: const Duration(seconds: 6),
    ));
  }

  void _abrirExpander(int num) {
    setState(() {
      if (_expanderAberto == num) {
        _expanderAberto = null;
        _limparEstadoExpander(num);
      } else {
        if (_expanderAberto != null) _limparEstadoExpander(_expanderAberto!);
        _expanderAberto = num;
      }
    });
  }

  void _limparEstadoExpander(int num) {
    if (num == 1) {
      _produtoSelecionadoId = null;
      _produtoChip          = null;
      _sugestoes1           = [];
      _ctrl1.clear();
    } else {
      _sugestoes2     = [];
      _resultadoBusca = null;
      _ctrl2.clear();
    }
  }

  Future<void> _abrirConfiguracoes() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ConfiguracaoPage()),
    );
    // Reset after possible credential change
    setState(() {
      _caixas.clear();
      _produtoSelecionadoId = null;
      _produtoChip          = null;
      _expanderAberto       = null;
      _sugestoes1           = [];
      _sugestoes2           = [];
      _destacadoCodigo      = null;
    });
    _ctrl1.clear();
    _ctrl2.clear();
    _highlightTimer?.cancel();
    _inicializar();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0e1014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0e1014),
        elevation: 0,
        titleSpacing: 12,
        title: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF2e6b46),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'CAMDA',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Layout de Gôndola',
              style: TextStyle(color: Colors.white, fontSize: 15),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        actions: [
          if (_dbConectado)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.circle, color: Color(0xFF4a9d6a), size: 8),
            ),
          IconButton(
            icon: const Icon(Icons.map_outlined, color: Color(0xFFe8a022)),
            tooltip: 'Ver no mapa',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LojaPage(
                  itemTipoInicial:   'gondola',
                  itemNumeroInicial: _gondolaAtual,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined,
                color: Color(0xFF8a9aa8), size: 22),
            onPressed: _abrirConfiguracoes,
            tooltip: 'Configuração do banco',
          ),
        ],
      ),
      body: Column(children: [
        // ── Indicador de carregamento fino ────────────────────────────────
        if (_carregandoLayout || _carregandoProdutos)
          const LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: Color(0xFF0d1117),
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2e6b46)),
          ),

        // ── Banner: banco não configurado ─────────────────────────────────
        if (!_dbConectado && !_carregandoProdutos)
          Container(
            width: double.infinity,
            color: const Color(0xFF0d1a24),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Row(children: [
              const Icon(Icons.info_outline,
                  color: Color(0xFF4a7a9b), size: 13),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Banco não configurado — usando dados de exemplo  ·  toque em ⚙️',
                  style: TextStyle(color: Color(0xFF4a7a9b), fontSize: 11),
                ),
              ),
            ]),
          ),

        // ── Seletor de gôndola ────────────────────────────────────────────
        _GondolaSelector(
          gondolaAtual: _gondolaAtual,
          onPrev: _gondolaAtual > 1  ? () => _trocarGondola(-1) : null,
          onNext: _gondolaAtual < 12 ? () => _trocarGondola(1)  : null,
        ),

        // ── Cena 3D ───────────────────────────────────────────────────────
        Expanded(
          child: GondolaScene(
            gondolaAtual:         _gondolaAtual,
            caixas:               _caixasAtuais,
            produtoSelecionadoId: _produtoSelecionadoId,
            corPorProduto:        _corPorProduto,
            onTapAndar:           _onTapAndar,
            destacadoCodigo:      _destacadoCodigo,
          ),
        ),

        // ── Painel inferior ───────────────────────────────────────────────
        Container(
          color: const Color(0xFF0d1117),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Hint quando nenhum expander está aberto
              if (_expanderAberto == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _carregandoProdutos
                        ? 'Carregando produtos...'
                        : _dbConectado
                            ? '${_produtos.length} produto(s) disponíve${_produtos.length == 1 ? 'l' : 'is'}'
                            : 'Selecione uma ação abaixo',
                    style: const TextStyle(
                      color: Color(0x55ffffff),
                      fontSize: 11,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),

              // Banner de resultado da última busca
              if (_resultadoBusca != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1e2a20),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF4a9d6a)),
                  ),
                  child: Row(children: [
                    const SizedBox(width: 12),
                    const Icon(Icons.location_on,
                        color: Color(0xFF4a9d6a), size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          _resultadoBusca!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Color(0xFF8a9aa8), size: 16),
                      onPressed: () =>
                          setState(() => _resultadoBusca = null),
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 4),
                  ]),
                ),

              // Expander 1 — Adicionar produto
              _Expander(
                title: '➕ Adicionar produto',
                isOpen: _expanderAberto == 1,
                onToggle: () => _abrirExpander(1),
                child: _buildConteudoAdicionar(),
              ),

              const SizedBox(height: 4),

              // Expander 2 — Buscar produto
              _Expander(
                title: '🔍 Buscar produto',
                isOpen: _expanderAberto == 2,
                onToggle: () => _abrirExpander(2),
                child: _buildConteudoBuscar(),
              ),

              // Botões Limpar / Salvar
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(children: [
                  OutlinedButton.icon(
                    onPressed:
                        _caixasAtuais.isNotEmpty ? _mostrarDialogLimpar : null,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Limpar'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFe57373),
                      side: const BorderSide(color: Color(0xFF3a2020)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                    ),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: _salvando ? null : _salvarLayout,
                    icon: _salvando
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.save_outlined, size: 16),
                    label: const Text('Salvar layout'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2e6b46),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 8),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  // ── Conteúdo Expander 1 ────────────────────────────────────────────────────

  Widget _buildConteudoAdicionar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Chip: produto selecionado
        if (_produtoChip != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF162416),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF2e6b46)),
            ),
            child: Row(children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _produtoChip!.cor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '✓ ${_produtoChip!.nome} — toque num andar para adicionar',
                  style: const TextStyle(
                    color: Color(0xFF6fcf97),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => setState(() {
                  _produtoChip          = null;
                  _produtoSelecionadoId = null;
                }),
                child: const Icon(Icons.close,
                    size: 14, color: Color(0xFF8a9aa8)),
              ),
            ]),
          ),

        _CampoAutocomplete(
          controller: _ctrl1,
          onChanged: (q) =>
              setState(() => _sugestoes1 = _filtrarProdutos(q)),
        ),

        if (_sugestoes1.isNotEmpty)
          _SugestoesList(
            sugestoes: _sugestoes1,
            onSelecionar: (p) => setState(() {
              _produtoSelecionadoId = p.codigo;
              _produtoChip          = p;
              _sugestoes1           = [];
              _ctrl1.clear();
            }),
          ),
      ],
    );
  }

  // ── Conteúdo Expander 2 ────────────────────────────────────────────────────

  Widget _buildConteudoBuscar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CampoAutocomplete(
          controller: _ctrl2,
          onChanged: (q) =>
              setState(() => _sugestoes2 = _filtrarProdutos(q)),
        ),
        if (_sugestoes2.isNotEmpty)
          _SugestoesList(
            sugestoes: _sugestoes2,
            onSelecionar: (p) {
              setState(() => _sugestoes2 = []);
              _ctrl2.clear();
              _buscarProduto(p);
            },
          ),
      ],
    );
  }
}

// ── Campo de autocomplete (compartilhado) ─────────────────────────────────────

class _CampoAutocomplete extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String>  onChanged;

  const _CampoAutocomplete({
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged:  onChanged,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        hintText:  'Buscar por nome ou código...',
        hintStyle: const TextStyle(color: Color(0x44ffffff), fontSize: 13),
        prefixIcon:
            const Icon(Icons.search, color: Color(0xFF8a9aa8), size: 18),
        filled:    true,
        fillColor: const Color(0xFF161c22),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF232f3a)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF232f3a)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: Color(0xFF2e6b46), width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
    );
  }
}

// ── Lista de sugestões ────────────────────────────────────────────────────────

class _SugestoesList extends StatelessWidget {
  final List<Produto>            sugestoes;
  final void Function(Produto)   onSelecionar;

  const _SugestoesList({
    required this.sugestoes,
    required this.onSelecionar,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: const Color(0xFF161c22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF232f3a)),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: sugestoes.length,
        separatorBuilder: (_, __) =>
            const Divider(height: 1, color: Color(0xFF232f3a)),
        itemBuilder: (context, i) {
          final p = sugestoes[i];
          return InkWell(
            onTap: () => onSelecionar(p),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: p.cor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  p.codigo,
                  style: const TextStyle(
                    color: Color(0xFF8a9aa8),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.nome,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

// ── Expander shell ────────────────────────────────────────────────────────────

class _Expander extends StatelessWidget {
  final String       title;
  final bool         isOpen;
  final VoidCallback onToggle;
  final Widget       child;

  const _Expander({
    required this.title,
    required this.isOpen,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      decoration: BoxDecoration(
        color: const Color(0xFF111820),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isOpen
              ? const Color(0xFF2e6b46)
              : const Color(0xFF1e2830),
        ),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Text(
                title,
                style: TextStyle(
                  color: isOpen ? Colors.white : const Color(0xFF8a9aa8),
                  fontSize: 13,
                  fontWeight:
                      isOpen ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              const Spacer(),
              Icon(
                isOpen ? Icons.expand_less : Icons.expand_more,
                color: isOpen
                    ? const Color(0xFF2e6b46)
                    : const Color(0xFF5a6a78),
                size: 20,
              ),
            ]),
          ),
        ),
        if (isOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: child,
          ),
      ]),
    );
  }
}

// ── Gondola selector ──────────────────────────────────────────────────────────

class _GondolaSelector extends StatelessWidget {
  final int           gondolaAtual;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const _GondolaSelector({
    required this.gondolaAtual,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0d1117),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ArrowBtn(icon: Icons.chevron_left,  onTap: onPrev),
          const SizedBox(width: 24),
          Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'GÔNDOLA',
              style: TextStyle(
                color: Color(0xFF8a9aa8),
                fontSize: 10,
                letterSpacing: 2.0,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '$gondolaAtual',
              style: const TextStyle(
                color: Color(0xFFe8a022),
                fontSize: 58,
                fontWeight: FontWeight.bold,
                height: 0.95,
              ),
            ),
            const Text(
              'de 12',
              style: TextStyle(
                color: Color(0xFF5a6a78),
                fontSize: 10,
                letterSpacing: 0.5,
              ),
            ),
          ]),
          const SizedBox(width: 24),
          _ArrowBtn(icon: Icons.chevron_right, onTap: onNext),
        ],
      ),
    );
  }
}

class _ArrowBtn extends StatelessWidget {
  final IconData      icon;
  final VoidCallback? onTap;

  const _ArrowBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1a2530) : const Color(0xFF111518),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? const Color(0xFF2e6b46)
                : const Color(0xFF1e2830),
            width: 1.5,
          ),
        ),
        child: Icon(
          icon,
          color: active
              ? const Color(0xFFe8a022)
              : const Color(0xFF2e3d48),
          size: 30,
        ),
      ),
    );
  }
}

// ── EstantePage ───────────────────────────────────────────────────────────────

class EstantePage extends StatefulWidget {
  final int estanteInicial;
  const EstantePage({super.key, this.estanteInicial = 1});

  @override
  State<EstantePage> createState() => _EstantePageState();
}

class _EstantePageState extends State<EstantePage> {
  int     _estanteAtual        = 1;
  String? _produtoSelecionadoId;
  String? _destacadoCodigo;
  Timer?  _highlightTimer;

  final Map<int, List<CaixaColocadaEstante>> _caixas = {};

  List<Produto> _produtos           = [];
  bool          _dbConectado        = false;
  bool          _carregandoProdutos = false;
  bool          _carregandoLayout   = false;
  bool          _salvando           = false;

  int? _expanderAberto;

  final _ctrl1 = TextEditingController();
  List<Produto> _sugestoes1 = [];
  Produto? _produtoChip;

  final _ctrl2 = TextEditingController();
  List<Produto> _sugestoes2 = [];

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<Produto> get _catalogoAtual =>
      _produtos.isNotEmpty ? _produtos : _catalogoMock;

  List<CaixaColocadaEstante> get _caixasAtuais =>
      _caixas[_estanteAtual] ?? const [];

  Map<String, Color> get _corPorProduto =>
      {for (final p in _catalogoAtual) p.codigo: p.cor};

  List<Produto> _filtrarProdutos(String query) {
    if (query.length < 2) return [];
    final q = query.toLowerCase();
    return _catalogoAtual
        .where((p) =>
            p.nome.toLowerCase().contains(q) ||
            p.codigo.toLowerCase().contains(q))
        .take(8)
        .toList();
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _estanteAtual = widget.estanteInicial;
    _inicializar();
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _ctrl1.dispose();
    _ctrl2.dispose();
    super.dispose();
  }

  Future<void> _inicializar() async {
    setState(() {
      _carregandoProdutos = true;
      _dbConectado        = false;
    });

    await TursoService().init();
    if (!mounted) return;

    final conectado = TursoService().isConnected;
    setState(() => _dbConectado = conectado);

    if (conectado) {
      final produtos = await TursoService().fetchProdutos();
      if (!mounted) return;
      setState(() {
        _produtos           = produtos;
        _carregandoProdutos = false;
      });
      _carregarLayout(_estanteAtual);
    } else {
      setState(() {
        _produtos           = [];
        _carregandoProdutos = false;
      });
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _trocarEstante(int delta) {
    final nova = (_estanteAtual + delta).clamp(1, 12);
    setState(() {
      _estanteAtual     = nova;
      _carregandoLayout = _dbConectado;
    });
    if (_dbConectado) _carregarLayout(nova);
  }

  Future<void> _carregarLayout(int estanteNum) async {
    final layouts = await TursoService().fetchLayoutEstante(estanteNum);
    if (!mounted) return;
    setState(() {
      _caixas[estanteNum] = layouts
          .map((l) => CaixaColocadaEstante(
                coluna:    l.coluna,
                nivel:     l.nivel,
                slot:      l.slot,
                produtoId: l.produtoCodigo,
              ))
          .toList();
      if (_estanteAtual == estanteNum) _carregandoLayout = false;
    });
  }

  void _onTapCelula(int coluna, int nivel, double hx) {
    if (_produtoSelecionadoId == null) return;

    final celula = EstanteGeometry.celulas
        .firstWhere((c) => c.coluna == coluna && c.nivel == nivel);
    final maxSlots = EstanteGeometry.slotsPorCelula(celula);

    final offsetNaCelula = hx - celula.xMin;
    var slotDesejado =
        (offsetNaCelula / (EstanteGeometry.wCaixa + EstanteGeometry.gap))
            .floor()
            .clamp(0, maxSlots - 1);

    final ocupados = _caixasAtuais
        .where((c) => c.coluna == coluna && c.nivel == nivel)
        .map((c) => c.slot)
        .toSet();

    if (ocupados.contains(slotDesejado)) {
      int? livre;
      for (var d = 1; d < maxSlots; d++) {
        final cima  = slotDesejado + d;
        final baixo = slotDesejado - d;
        if (cima  < maxSlots && !ocupados.contains(cima))  { livre = cima;  break; }
        if (baixo >= 0       && !ocupados.contains(baixo)) { livre = baixo; break; }
      }
      if (livre == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Célula cheia (col ${coluna + 1}, nível ${nivel + 1})'),
          backgroundColor: const Color(0xFF5a1a1a),
          duration: const Duration(seconds: 2),
        ));
        return;
      }
      slotDesejado = livre;
    }

    setState(() {
      _caixas[_estanteAtual] = [
        ..._caixasAtuais,
        CaixaColocadaEstante(
          coluna:    coluna,
          nivel:     nivel,
          slot:      slotDesejado,
          produtoId: _produtoSelecionadoId!,
        ),
      ];
    });
  }

  void _limparEstante() => setState(() => _caixas.remove(_estanteAtual));

  void _limparEstantePorProduto(String produtoId) {
    setState(() {
      final restantes = _caixasAtuais.where((c) => c.produtoId != produtoId).toList();
      if (restantes.isEmpty) {
        _caixas.remove(_estanteAtual);
      } else {
        _caixas[_estanteAtual] = restantes;
      }
    });
  }

  void _mostrarDialogLimparEstante() {
    final idsNaEstante = _caixasAtuais.map((c) => c.produtoId).toSet();
    final produtos = _catalogoAtual.where((p) => idsNaEstante.contains(p.codigo)).toList();

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Limpar produto',
          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...produtos.map((p) {
              final qtd = _caixasAtuais.where((c) => c.produtoId == p.codigo).length;
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  Navigator.pop(ctx);
                  _limparEstantePorProduto(p.codigo);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: p.cor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.nome, style: const TextStyle(color: Colors.white, fontSize: 13)),
                            Text(
                              '$qtd ${qtd == 1 ? 'unidade' : 'unidades'}',
                              style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.delete_outline, color: Color(0xFFe57373), size: 20),
                    ],
                  ),
                ),
              );
            }),
            if (produtos.length > 1) ...[
              const Divider(color: Color(0xFF2a3540), height: 20),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  Navigator.pop(ctx);
                  showDialog<void>(
                    context: context,
                    builder: (ctx2) => AlertDialog(
                      backgroundColor: const Color(0xFF141a22),
                      surfaceTintColor: Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      title: const Text(
                        'Limpar tudo?',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      content: const Text(
                        'Todos os produtos desta prateleira serão removidos.',
                        style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 13),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx2),
                          child: const Text('Cancelar', style: TextStyle(color: Color(0xFF8a9aa8))),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(ctx2);
                            _limparEstante();
                          },
                          child: const Text('Limpar tudo', style: TextStyle(color: Color(0xFFe57373))),
                        ),
                      ],
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.delete_forever, color: Color(0xFFe57373), size: 20),
                      SizedBox(width: 10),
                      Text(
                        'Limpar tudo',
                        style: TextStyle(color: Color(0xFFe57373), fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xFF8a9aa8))),
          ),
        ],
      ),
    );
  }

  Future<void> _salvarLayout() async {
    if (!_dbConectado) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Configure o banco em ⚙️ para salvar no Turso'),
        backgroundColor: Color(0xFF1a3040),
        duration: Duration(seconds: 3),
      ));
      return;
    }

    setState(() => _salvando = true);

    final produtoMap = {for (final p in _produtos) p.codigo: p};
    final itens = _caixasAtuais.map((c) {
      final produto = produtoMap[c.produtoId];
      return CaixaLayoutEstante(
        estanteNum:    _estanteAtual,
        coluna:        c.coluna,
        nivel:         c.nivel,
        slot:          c.slot,
        produtoCodigo: c.produtoId,
        produtoNome:   produto?.nome ?? c.produtoId,
        corHex:        produto?.corHex ?? '#888888',
      );
    }).toList();

    final ok = await TursoService().salvarLayoutEstante(_estanteAtual, itens);
    if (!mounted) return;
    setState(() => _salvando = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Layout salvo ✓' : 'Erro ao salvar'),
      backgroundColor:
          ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _buscarProduto(Produto produto) async {
    if (!_dbConectado) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Configure o banco em ⚙️ para buscar no Turso'),
        backgroundColor: Color(0xFF1a3040),
        duration: Duration(seconds: 3),
      ));
      return;
    }

    final encontrado =
        await TursoService().buscarProdutoEstante(produto.codigo);
    if (!mounted) return;

    if (encontrado == null) {
      // fallback: tenta na gôndola
      final naGondola =
          await TursoService().buscarProduto(produto.codigo);
      if (!mounted) return;

      if (naGondola != null) {
        final andarNome =
            ['Base', 'Meio', 'Topo'][naGondola.andar.clamp(0, 2)];
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            '📦 ${produto.nome} está na Gôndola ${naGondola.gondolaNum} '
            '($andarNome) — abra a aba Gôndola.',
          ),
          backgroundColor: const Color(0xFF1a2a3a),
          duration: const Duration(seconds: 4),
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            '${produto.nome} não encontrado em nenhuma estante ou gôndola.\n'
            'Use "Adicionar produto" para cadastrar.',
          ),
          backgroundColor: const Color(0xFF5a1a1a),
          duration: const Duration(seconds: 3),
        ));
      }
      return;
    }

    setState(() {
      _estanteAtual     = encontrado.estanteNum;
      _carregandoLayout = true;
      _expanderAberto   = null;
      _sugestoes2       = [];
    });
    _ctrl2.clear();

    final layouts =
        await TursoService().fetchLayoutEstante(encontrado.estanteNum);
    if (!mounted) return;

    _highlightTimer?.cancel();
    setState(() {
      _caixas[encontrado.estanteNum] = layouts
          .map((l) => CaixaColocadaEstante(
                coluna:    l.coluna,
                nivel:     l.nivel,
                slot:      l.slot,
                produtoId: l.produtoCodigo,
              ))
          .toList();
      _carregandoLayout = false;
      _destacadoCodigo  = produto.codigo;
    });

    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _destacadoCodigo = null);
    });

    const nivelNomes = ['Nível 1', 'Nível 2', 'Nível 3', 'Nível 4'];
    const colNomes   = ['Col. 1',  'Col. 2',  'Col. 3' ];
    final nivelNome  = nivelNomes[encontrado.nivel.clamp(0, 3)];
    final colNome    = colNomes[encontrado.coluna.clamp(0, 2)];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        '📍 ${produto.nome} → Estante ${encontrado.estanteNum}, '
        '$colNome, $nivelNome, Slot ${encontrado.slot + 1}',
      ),
      backgroundColor: const Color(0xFF1a3a2a),
      duration: const Duration(seconds: 3),
    ));
  }

  void _abrirExpander(int num) {
    setState(() {
      if (_expanderAberto == num) {
        _expanderAberto = null;
        _limparEstadoExpander(num);
      } else {
        if (_expanderAberto != null) _limparEstadoExpander(_expanderAberto!);
        _expanderAberto = num;
      }
    });
  }

  void _limparEstadoExpander(int num) {
    if (num == 1) {
      _produtoSelecionadoId = null;
      _produtoChip          = null;
      _sugestoes1           = [];
      _ctrl1.clear();
    } else {
      _sugestoes2 = [];
      _ctrl2.clear();
    }
  }

  Future<void> _abrirConfiguracoes() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ConfiguracaoPage()),
    );
    setState(() {
      _caixas.clear();
      _produtoSelecionadoId = null;
      _produtoChip          = null;
      _expanderAberto       = null;
      _sugestoes1           = [];
      _sugestoes2           = [];
      _destacadoCodigo      = null;
    });
    _ctrl1.clear();
    _ctrl2.clear();
    _highlightTimer?.cancel();
    _inicializar();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0e1014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0e1014),
        elevation: 0,
        titleSpacing: 12,
        title: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF6b3d14),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'CAMDA',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Layout de Estante',
              style: TextStyle(color: Colors.white, fontSize: 15),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        actions: [
          if (_dbConectado)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.circle, color: Color(0xFF4a9d6a), size: 8),
            ),
          IconButton(
            icon: const Icon(Icons.map_outlined, color: Color(0xFFe8a022)),
            tooltip: 'Ver no mapa',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LojaPage(
                  itemTipoInicial:   'estante',
                  itemNumeroInicial: _estanteAtual,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined,
                color: Color(0xFF8a9aa8), size: 22),
            onPressed: _abrirConfiguracoes,
            tooltip: 'Configuração do banco',
          ),
        ],
      ),
      body: Column(children: [
        if (_carregandoLayout || _carregandoProdutos)
          const LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: Color(0xFF0d1117),
            valueColor:
                AlwaysStoppedAnimation<Color>(Color(0xFF8a5a2e)),
          ),

        if (!_dbConectado && !_carregandoProdutos)
          Container(
            width: double.infinity,
            color: const Color(0xFF0d1a24),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Row(children: [
              const Icon(Icons.info_outline,
                  color: Color(0xFF4a7a9b), size: 13),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Banco não configurado — usando dados de exemplo  ·  toque em ⚙️',
                  style:
                      TextStyle(color: Color(0xFF4a7a9b), fontSize: 11),
                ),
              ),
            ]),
          ),

        _EstanteSelector(
          estanteAtual: _estanteAtual,
          onPrev: _estanteAtual > 1  ? () => _trocarEstante(-1) : null,
          onNext: _estanteAtual < 12 ? () => _trocarEstante(1)  : null,
        ),

        Expanded(
          child: EstanteScene(
            estanteAtual:         _estanteAtual,
            caixas:               _caixasAtuais,
            produtoSelecionadoId: _produtoSelecionadoId,
            corPorProduto:        _corPorProduto,
            onTapCelula:          _onTapCelula,
            destacadoCodigo:      _destacadoCodigo,
          ),
        ),

        Container(
          color: const Color(0xFF0d1117),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_expanderAberto == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _carregandoProdutos
                        ? 'Carregando produtos...'
                        : _dbConectado
                            ? '${_produtos.length} produto(s) disponíve${_produtos.length == 1 ? 'l' : 'is'}'
                            : 'Selecione uma ação abaixo',
                    style: const TextStyle(
                      color: Color(0x55ffffff),
                      fontSize: 11,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),

              _Expander(
                title: '➕ Adicionar produto',
                isOpen: _expanderAberto == 1,
                onToggle: () => _abrirExpander(1),
                child: _buildConteudoAdicionar(),
              ),

              const SizedBox(height: 4),

              _Expander(
                title: '🔍 Buscar produto',
                isOpen: _expanderAberto == 2,
                onToggle: () => _abrirExpander(2),
                child: _buildConteudoBuscar(),
              ),

              Padding(
                padding:
                    const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(children: [
                  OutlinedButton.icon(
                    onPressed:
                        _caixasAtuais.isNotEmpty ? _mostrarDialogLimparEstante : null,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Limpar'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFe57373),
                      side:
                          const BorderSide(color: Color(0xFF3a2020)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                    ),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: _salvando ? null : _salvarLayout,
                    icon: _salvando
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white),
                          )
                        : const Icon(Icons.save_outlined, size: 16),
                    label: const Text('Salvar layout'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6b3d14),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 8),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  // ── Conteúdo Expander 1 ────────────────────────────────────────────────────

  Widget _buildConteudoAdicionar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_produtoChip != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF241608),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF8a5a2e)),
            ),
            child: Row(children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _produtoChip!.cor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '✓ ${_produtoChip!.nome} — toque numa célula para adicionar',
                  style: const TextStyle(
                    color: Color(0xFFcf9f6f),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => setState(() {
                  _produtoChip          = null;
                  _produtoSelecionadoId = null;
                }),
                child: const Icon(Icons.close,
                    size: 14, color: Color(0xFF8a9aa8)),
              ),
            ]),
          ),

        _CampoAutocomplete(
          controller: _ctrl1,
          onChanged: (q) =>
              setState(() => _sugestoes1 = _filtrarProdutos(q)),
        ),

        if (_sugestoes1.isNotEmpty)
          _SugestoesList(
            sugestoes: _sugestoes1,
            onSelecionar: (p) => setState(() {
              _produtoSelecionadoId = p.codigo;
              _produtoChip          = p;
              _sugestoes1           = [];
              _ctrl1.clear();
            }),
          ),
      ],
    );
  }

  // ── Conteúdo Expander 2 ────────────────────────────────────────────────────

  Widget _buildConteudoBuscar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CampoAutocomplete(
          controller: _ctrl2,
          onChanged: (q) =>
              setState(() => _sugestoes2 = _filtrarProdutos(q)),
        ),
        if (_sugestoes2.isNotEmpty)
          _SugestoesList(
            sugestoes: _sugestoes2,
            onSelecionar: (p) {
              setState(() => _sugestoes2 = []);
              _ctrl2.clear();
              _buscarProduto(p);
            },
          ),
      ],
    );
  }
}

// ── Estante selector ──────────────────────────────────────────────────────────

class _EstanteSelector extends StatelessWidget {
  final int           estanteAtual;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const _EstanteSelector({
    required this.estanteAtual,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0d1117),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ArrowBtn(icon: Icons.chevron_left,  onTap: onPrev),
          const SizedBox(width: 24),
          Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'ESTANTE',
              style: TextStyle(
                color: Color(0xFF8a9aa8),
                fontSize: 10,
                letterSpacing: 2.0,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '$estanteAtual',
              style: const TextStyle(
                color: Color(0xFFd4853a),
                fontSize: 58,
                fontWeight: FontWeight.bold,
                height: 0.95,
              ),
            ),
            const Text(
              'de 12',
              style: TextStyle(
                color: Color(0xFF5a6a78),
                fontSize: 10,
                letterSpacing: 0.5,
              ),
            ),
          ]),
          const SizedBox(width: 24),
          _ArrowBtn(icon: Icons.chevron_right, onTap: onNext),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EstanteEdr300Page — modelo 3D interativo da Estante de Aço EDR-300
// ─────────────────────────────────────────────────────────────────────────────

class EstanteEdr300Page extends StatefulWidget {
  const EstanteEdr300Page({super.key});

  @override
  State<EstanteEdr300Page> createState() => _EstanteEdr300PageState();
}

class _EstanteEdr300PageState extends State<EstanteEdr300Page> {
  int    _shelves    = 6;
  double _height     = 1.98;
  double _width      = 0.92;
  double _depth      = 0.30;
  bool   _autoRot    = true;
  bool   _showHoles  = false;
  bool   _showFloor  = true;
  bool   _wireframe  = false;
  bool   _panelOpen  = false;

  static const _bg      = Color(0xFF0e1116);
  static const _panel   = Color(0xFF161b22);
  static const _line    = Color(0xFF262d38);
  static const _txt     = Color(0xFFc9d3df);
  static const _txtDim  = Color(0xFF7c8696);
  static const _accent  = Color(0xFFe0772b);
  static const _accentS = Color(0xFFf0a868);

  Edr300Geometry get _geo => Edr300Geometry(
    shelves:   _shelves,
    height:    _height,
    width:     _width,
    depth:     _depth,
    showHoles: _showHoles,
    showFloor: _showFloor,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: Edr300Scene(
              geometry:   _geo,
              wireframe:  _wireframe,
              autoRotate: _autoRot,
            ),
          ),
          // HUD
          Positioned(
            top: 0, left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: const Icon(Icons.arrow_back_ios,
                              color: _txtDim, size: 20),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => Navigator.push(context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const EstantePage(estanteInicial: 8),
                            )),
                          icon: const Icon(Icons.inventory_2_outlined,
                              size: 16, color: _accentS),
                          label: const Text('Produtos',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: _accentS,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text('Estante de Aço',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          letterSpacing: 2, color: _txtDim)),
                    const SizedBox(height: 2),
                    Text.rich(TextSpan(
                      style: const TextStyle(fontSize: 22,
                          fontWeight: FontWeight.bold, color: _txt),
                      children: const [
                        TextSpan(text: 'EDR-300 · '),
                        TextSpan(text: 'Chapa 22',
                            style: TextStyle(color: _accentS)),
                      ],
                    )),
                  ],
                ),
              ),
            ),
          ),
          // Painel de parâmetros
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve:    Curves.easeInOut,
            right: _panelOpen ? 18 : -300,
            top:   18, bottom: 18,
            width: 272,
            child: SingleChildScrollView(
              child: Container(
                decoration: BoxDecoration(
                  color:        _panel,
                  border:       Border.all(color: _line),
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionLabel('Parâmetros'),
                    _slider('Prateleiras', _shelves.toDouble(), 3, 8, 1,
                      (v) => setState(() => _shelves = v.round()),
                      fmt: (v) => '${v.round()}'),
                    _slider('Altura (cm)', _height * 100, 120, 240, 2,
                      (v) => setState(() => _height = v / 100),
                      fmt: (v) => '${v.round()}'),
                    _slider('Largura (cm)', _width * 100, 60, 120, 2,
                      (v) => setState(() => _width = v / 100),
                      fmt: (v) => '${v.round()}'),
                    _slider('Profundidade (cm)', _depth * 100, 25, 60, 2,
                      (v) => setState(() => _depth = v / 100),
                      fmt: (v) => '${v.round()}'),
                    const SizedBox(height: 4),
                    _sectionLabel('Exibição'),
                    Row(children: [
                      _toggle('Girar',   _autoRot,
                        () => setState(() => _autoRot   = !_autoRot)),
                      const SizedBox(width: 8),
                      _toggle('Furos',   _showHoles,
                        () => setState(() => _showHoles = !_showHoles)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      _toggle('Piso',    _showFloor,
                        () => setState(() => _showFloor = !_showFloor)),
                      const SizedBox(width: 8),
                      _toggle('Aramado', _wireframe,
                        () => setState(() => _wireframe = !_wireframe)),
                    ]),
                    const SizedBox(height: 14),
                    const Divider(color: _line),
                    const SizedBox(height: 10),
                    Text.rich(TextSpan(
                      style: const TextStyle(fontSize: 12,
                          color: _txtDim, height: 1.8),
                      children: [
                        const TextSpan(text: 'EDR-300',
                            style: TextStyle(
                                color: _txt, fontWeight: FontWeight.bold)),
                        TextSpan(text: ' · $_shelves prateleiras\n'),
                        const TextSpan(text: 'Chapa 22 · capacidade '),
                        const TextSpan(text: '120 kg/prat.',
                            style: TextStyle(
                                color: _txt, fontWeight: FontWeight.bold)),
                        const TextSpan(
                            text: '\nMontante perfurado, regulagem livre'),
                      ],
                    )),
                  ],
                ),
              ),
            ),
          ),
          // Botão de ajustes
          Positioned(
            right: 18, bottom: 24,
            child: SafeArea(
              child: ElevatedButton(
                onPressed: () => setState(() => _panelOpen = !_panelOpen),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: const Color(0xFF1a1208),
                  shape:           const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 22, vertical: 14),
                  textStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold),
                  elevation: 8,
                ),
                child: Text(_panelOpen ? '✕ Fechar' : '⚙ Ajustes'),
              ),
            ),
          ),
          // hint
          const Positioned(
            left: 22, bottom: 18,
            child: SafeArea(
              child: Text('Arraste para girar · pinça para zoom',
                style: TextStyle(fontSize: 11, color: _txtDim)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 14, top: 8),
    child: Text(text,
      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
          letterSpacing: 2.5, color: _txtDim)),
  );

  Widget _slider(
    String label, double value, double min, double max, double step,
    ValueChanged<double> onChanged, {
    required String Function(double) fmt,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                style: const TextStyle(fontSize: 13, color: _txt)),
              Text(fmt(value),
                style: const TextStyle(fontSize: 13,
                    color: _accentS, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor:   _accent,
              inactiveTrackColor: _line,
              thumbColor:         _accent,
              overlayColor: _accent.withAlpha(40),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              trackHeight: 4,
            ),
            child: Slider(
              value:     value,
              min:       min,
              max:       max,
              divisions: ((max - min) / step).round(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggle(String label, bool on, VoidCallback onTap) => Expanded(
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: on ? _accent : Colors.transparent,
          border: Border.all(color: on ? _accent : _line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w700,
            color: on ? const Color(0xFF1a1208) : _txtDim,
          )),
      ),
    ),
  );
}
