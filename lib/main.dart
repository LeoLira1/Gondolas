import 'package:flutter/material.dart';
import 'configuracao_page.dart';
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
      home: const GondolaPage(),
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

  final Map<int, List<CaixaColocada>> _caixas = {};

  List<Produto> _produtos           = [];
  bool          _dbConectado        = false;
  bool          _carregandoProdutos = false;
  bool          _carregandoLayout   = false;
  bool          _salvando           = false;

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<Produto> get _catalogoAtual =>
      _produtos.isNotEmpty ? _produtos : _catalogoMock;

  List<CaixaColocada> get _caixasAtuais => _caixas[_gondolaAtual] ?? const [];

  Map<String, Color> get _corPorProduto =>
      {for (final p in _catalogoAtual) p.codigo: p.cor};

  Produto? get _produtoAtual {
    if (_produtoSelecionadoId == null) return null;
    try {
      return _catalogoAtual.firstWhere((p) => p.codigo == _produtoSelecionadoId);
    } catch (_) {
      return null;
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _inicializar();
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
      _gondolaAtual      = nova;
      _carregandoLayout  = _dbConectado;
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

  void _selecionarProduto(String codigo) => setState(() {
        _produtoSelecionadoId =
            _produtoSelecionadoId == codigo ? null : codigo;
      });

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configure o banco em ⚙️ para salvar no Turso'),
          backgroundColor: Color(0xFF1a3040),
          duration: Duration(seconds: 3),
        ),
      );
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

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Layout salvo ✓' : 'Erro ao salvar'),
        backgroundColor:
            ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _abrirConfiguracoes() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ConfiguracaoPage()),
    );
    // Re-initialize after possible credential change
    setState(() {
      _caixas.clear();
      _produtoSelecionadoId = null;
    });
    _inicializar();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final temCaixas = _caixasAtuais.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0e1014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0e1014),
        elevation: 0,
        titleSpacing: 12,
        title: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
          ],
        ),
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
      body: Column(
        children: [
          // ── Indicador de carregamento fino ─────────────────────────────
          if (_carregandoLayout || _carregandoProdutos)
            const LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Color(0xFF0d1117),
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2e6b46)),
            ),

          // ── Banner: banco não configurado ───────────────────────────────
          if (!_dbConectado && !_carregandoProdutos)
            Container(
              width: double.infinity,
              color: const Color(0xFF0d1a24),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      color: Color(0xFF4a7a9b), size: 13),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Banco não configurado — usando dados de exemplo  ·  toque em ⚙️',
                      style: TextStyle(
                          color: Color(0xFF4a7a9b), fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),

          // ── Seletor de gôndola ──────────────────────────────────────────
          _GondolaSelector(
            gondolaAtual: _gondolaAtual,
            onPrev: _gondolaAtual > 1  ? () => _trocarGondola(-1) : null,
            onNext: _gondolaAtual < 12 ? () => _trocarGondola(1)  : null,
          ),

          // ── Cena 3D ─────────────────────────────────────────────────────
          Expanded(
            child: GondolaScene(
              gondolaAtual:         _gondolaAtual,
              caixas:               _caixasAtuais,
              produtoSelecionadoId: _produtoSelecionadoId,
              corPorProduto:        _corPorProduto,
              onTapAndar:           _onTapAndar,
            ),
          ),

          // ── Dica ────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text(
              _produtoAtual == null
                  ? 'selecione um produto abaixo'
                  : '${_produtoAtual!.nome} selecionado  ·  toque num andar para adicionar',
              style: const TextStyle(
                color: Color(0x99ffffff),
                fontSize: 11,
                letterSpacing: 0.2,
              ),
            ),
          ),

          // ── Barra de produtos ───────────────────────────────────────────
          _BarraProdutos(
            catalogo:      _catalogoAtual,
            selecionadoId: _produtoSelecionadoId,
            onSelecionar:  _selecionarProduto,
          ),

          // ── Botões Limpar / Salvar ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: temCaixas ? _limparGondola : null,
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Gondola selector ──────────────────────────────────────────────────────────

class _GondolaSelector extends StatelessWidget {
  final int gondolaAtual;
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
          _ArrowBtn(icon: Icons.chevron_left, onTap: onPrev),
          const SizedBox(width: 24),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
            ],
          ),
          const SizedBox(width: 24),
          _ArrowBtn(icon: Icons.chevron_right, onTap: onNext),
        ],
      ),
    );
  }
}

class _ArrowBtn extends StatelessWidget {
  final IconData icon;
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
          color: active
              ? const Color(0xFF1a2530)
              : const Color(0xFF111518),
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

// ── Product bar ───────────────────────────────────────────────────────────────

class _BarraProdutos extends StatelessWidget {
  final List<Produto> catalogo;
  final String? selecionadoId;
  final void Function(String codigo) onSelecionar;

  const _BarraProdutos({
    required this.catalogo,
    required this.selecionadoId,
    required this.onSelecionar,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0d1117),
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
      height: 86,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: catalogo.length,
        itemBuilder: (_, i) {
          final p   = catalogo[i];
          final sel = p.codigo == selecionadoId;
          return GestureDetector(
            onTap: () => onSelecionar(p.codigo),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 80,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              decoration: BoxDecoration(
                color: sel
                    ? Color.lerp(const Color(0xFF141a22), p.cor, 0.25)
                    : const Color(0xFF141a22),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: sel ? p.cor : const Color(0xFF232f3a),
                  width: sel ? 2 : 1,
                ),
                boxShadow: sel
                    ? [
                        BoxShadow(
                          color:
                              Color.lerp(Colors.transparent, p.cor, 0.35)!,
                          blurRadius: 8,
                        )
                      ]
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: p.cor,
                      borderRadius: BorderRadius.circular(4),
                      border: sel
                          ? Border.all(color: Colors.white, width: 1.5)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    p.nome,
                    style: TextStyle(
                      color: sel ? Colors.white : const Color(0xFF8a9aa8),
                      fontSize: 9.5,
                      fontWeight:
                          sel ? FontWeight.bold : FontWeight.normal,
                      letterSpacing: 0.1,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
