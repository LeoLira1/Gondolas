import 'package:flutter/material.dart';
import 'loja_scene.dart';

// ──────────────────────────────────────────────────────────────────────────────
// LojaPage — store map with 12 gondolas + 7 wall shelves
// ──────────────────────────────────────────────────────────────────────────────

class LojaPage extends StatefulWidget {
  const LojaPage({super.key});

  /// Returns the selected gondola id (int) if the user taps "Visitar", or null.
  @override
  State<LojaPage> createState() => _LojaPageState();
}

class _LojaPageState extends State<LojaPage> {
  LojaItem? _selected;
  final _searchCtrl = TextEditingController();
  String    _busca  = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSelect(LojaItem item) {
    setState(() => _selected = _selected == item ? null : item);
  }

  void _visitarGondola() {
    final sel = _selected;
    if (sel == null || sel.tipo != LojaItemTipo.gondola) return;
    Navigator.pop(context, sel.id);
  }

  // Items highlighted by current search text (case-insensitive label match)
  LojaItem? get _searchHit {
    if (_busca.isEmpty) return null;
    final q = _busca.toLowerCase().trim();
    final allItems = [...lojaGondolas, ...lojaEstantes];
    try {
      return allItems.firstWhere(
        (i) => i.label.toLowerCase().contains(q),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final highlight = _selected ?? _searchHit;

    return Scaffold(
      backgroundColor: const Color(0xFF0e1014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0e1014),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
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
            const Text(
              'Mapa da Loja',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _busca = v),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Buscar gôndola ou estante (ex: 5, E3)…',
                hintStyle: const TextStyle(color: Color(0xFF5a6a78), fontSize: 13),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF5a6a78), size: 20),
                suffixIcon: _busca.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Color(0xFF5a6a78), size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _busca = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF1a2530),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          // 3D map
          Expanded(
            child: LojaScene(
              selected: highlight,
              onSelect: _onSelect,
            ),
          ),

          // Hint / selected item bar
          _buildBottomBar(highlight),
        ],
      ),
    );
  }

  Widget _buildBottomBar(LojaItem? highlight) {
    if (highlight == null) {
      return Container(
        color: const Color(0xFF0d1117),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: const Text(
          'Toque numa gôndola ou estante para selecionar  ·  Arraste para girar  ·  Aperte para zoom',
          style: TextStyle(color: Color(0xFF5a6a78), fontSize: 11),
          textAlign: TextAlign.center,
        ),
      );
    }

    final isGondola = highlight.tipo == LojaItemTipo.gondola;
    return Container(
      color: const Color(0xFF0d1117),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Row(
        children: [
          // Icon badge
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: const Color(0xFF2e6b46),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                highlight.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isGondola
                      ? 'Gôndola ${highlight.label}'
                      : 'Estante ${highlight.label}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Text(
                  isGondola
                      ? 'Toque em "Visitar" para abrir o editor de layout'
                      : 'Estante de parede — editor em breve',
                  style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
                ),
              ],
            ),
          ),
          if (isGondola) ...[
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _visitarGondola,
              icon: const Icon(Icons.store, size: 16),
              label: const Text('Visitar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2e6b46),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
