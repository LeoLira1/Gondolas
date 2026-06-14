import 'dart:convert';
import 'package:flutter/material.dart';
import 'gondola_scene.dart';

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

// ── Catálogo de produtos (mock — substituir por query Turso na Fase 3) ────────

class Produto {
  final String id;
  final String nome;
  final Color cor;
  const Produto({required this.id, required this.nome, required this.cor});
}

const List<Produto> catalogoProdutos = [
  Produto(id: 'lubrax',  nome: 'Óleo Lubrax',  cor: Color(0xFF2e7d32)),
  Produto(id: 'fogo',    nome: 'Botina Fogo',   cor: Color(0xFF1565c0)),
  Produto(id: 'garotti', nome: 'Bota Garotti',  cor: Color(0xFF6d4c41)),
  Produto(id: 'chapeu',  nome: 'Chapéu Palha',  cor: Color(0xFFf9a825)),
  Produto(id: 'lona',    nome: 'Lona 5×7',      cor: Color(0xFFe65100)),
];

// ── Page ──────────────────────────────────────────────────────────────────────

class GondolaPage extends StatefulWidget {
  const GondolaPage({super.key});

  @override
  State<GondolaPage> createState() => _GondolaPageState();
}

class _GondolaPageState extends State<GondolaPage> {
  int     _gondolaAtual         = 1;
  String? _produtoSelecionadoId;

  // Box layout per gondola: gondola number → list of placed boxes
  final Map<int, List<CaixaColocada>> _caixas = {};

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<CaixaColocada> get _caixasAtuais => _caixas[_gondolaAtual] ?? const [];

  Map<String, Color> get _corPorProduto =>
      {for (final p in catalogoProdutos) p.id: p.cor};

  Produto? get _produtoAtual => _produtoSelecionadoId == null
      ? null
      : catalogoProdutos.firstWhere((p) => p.id == _produtoSelecionadoId);

  // ── Actions ────────────────────────────────────────────────────────────────

  void _trocarGondola(int delta) =>
      setState(() => _gondolaAtual = (_gondolaAtual + delta).clamp(1, 12));

  void _selecionarProduto(String id) => setState(() {
        _produtoSelecionadoId =
            _produtoSelecionadoId == id ? null : id;
      });

  void _onTapAndar(int andar, double x, double z) {
    if (_produtoSelecionadoId == null) return;
    final caixa = CaixaColocada(
      andar: andar,
      produtoId: _produtoSelecionadoId!,
      x: x,
      z: z,
    );
    setState(() {
      _caixas[_gondolaAtual] = [..._caixasAtuais, caixa];
    });
  }

  void _limparGondola() => setState(() => _caixas.remove(_gondolaAtual));

  void _salvarLayout() {
    // TODO: POST para Turso aqui — substituir o print pelo request HTTP
    final payload = {
      for (final e in _caixas.entries)
        '${e.key}': e.value.map((c) => c.toJson()).toList(),
    };
    // ignore: avoid_print
    print('Layout JSON:\n${const JsonEncoder.withIndent('  ').convert(payload)}');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Layout salvo no console (Turso em breve)'),
        backgroundColor: Color(0xFF2e6b46),
        duration: Duration(seconds: 2),
      ),
    );
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
          ],
        ),
      ),
      body: Column(
        children: [
          // ── Seletor de gôndola ──────────────────────────────────────────
          _GondolaSelector(
            gondolaAtual: _gondolaAtual,
            onPrev: _gondolaAtual > 1  ? () => _trocarGondola(-1) : null,
            onNext: _gondolaAtual < 12 ? () => _trocarGondola(1)  : null,
          ),

          // ── Cena 3D ─────────────────────────────────────────────────────
          Expanded(
            child: GondolaScene(
              gondolaAtual:           _gondolaAtual,
              caixas:                 _caixasAtuais,
              produtoSelecionadoId:   _produtoSelecionadoId,
              corPorProduto:          _corPorProduto,
              onTapAndar:             _onTapAndar,
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
            catalogo:     catalogoProdutos,
            selecionadoId: _produtoSelecionadoId,
            onSelecionar:  _selecionarProduto,
          ),

          // ── Botões Limpar / Salvar ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(
              children: [
                // Limpar — só ativo se há caixas
                OutlinedButton.icon(
                  onPressed: temCaixas ? _limparGondola : null,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Limpar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFe57373),
                    side: const BorderSide(color: Color(0xFF3a2020)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                ),
                const Spacer(),
                // Salvar layout
                ElevatedButton.icon(
                  onPressed: _salvarLayout,
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('Salvar layout'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2e6b46),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
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
          color: active ? const Color(0xFF1a2530) : const Color(0xFF111518),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? const Color(0xFF2e6b46) : const Color(0xFF1e2830),
            width: 1.5,
          ),
        ),
        child: Icon(
          icon,
          color: active ? const Color(0xFFe8a022) : const Color(0xFF2e3d48),
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
  final void Function(String id) onSelecionar;

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
      child: Row(
        children: catalogo.map((p) {
          final sel = p.id == selecionadoId;
          return Expanded(
            child: GestureDetector(
              onTap: () => onSelecionar(p.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(vertical: 8),
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
                      ? [BoxShadow(
                          color: Color.lerp(Colors.transparent, p.cor, 0.35)!,
                          blurRadius: 8,
                        )]
                      : null,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                        fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                        letterSpacing: 0.1,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
