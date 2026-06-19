import 'dart:async';
import 'package:flutter/material.dart';
import 'configuracao_page.dart';
import 'estante_scene.dart';
import 'gondola_scene.dart';
import 'models.dart';
import 'turso_service.dart';

void main() => runApp(const CamdaApp());

class CamdaApp extends StatelessWidget {
  const CamdaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gôndola 3D CAMDA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2e6b46),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const _MainNav(),
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

// ── Page ──────────────────────────────────────────────────────────────────────

class GondolaPage extends StatefulWidget {
  const GondolaPage({super.key});

  @override
  State<GondolaPage> createState() => _GondolaPageState();
}

class _GondolaPageState extends State<GondolaPage> {
  int     _gondolaAtual        = 1;
  String? _produtoSelecionadoId;
  String? _destacadoCodigo;
  Timer?  _highlightTimer;

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '${produto.nome} não encontrado em nenhuma gôndola.\n'
          'Use "Adicionar produto" para cadastrar.',
        ),
        backgroundColor: const Color(0xFF5a1a1a),
        duration: const Duration(seconds: 3),
      ));
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
    });

    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _destacadoCodigo = null);
    });

    final andarNome = ['Base', 'Meio', 'Topo'][encontrado.andar.clamp(0, 2)];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        '📍 ${produto.nome} → Gôndola ${encontrado.gondolaNum}, Andar $andarNome',
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
                        _caixasAtuais.isNotEmpty ? _limparGondola : null,
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
  const EstantePage({super.key});

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '${produto.nome} não encontrado em nenhuma estante.\n'
          'Use "Adicionar produto" para cadastrar.',
        ),
        backgroundColor: const Color(0xFF5a1a1a),
        duration: const Duration(seconds: 3),
      ));
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
                        _caixasAtuais.isNotEmpty ? _limparEstante : null,
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
