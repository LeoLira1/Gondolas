import 'package:flutter/material.dart';
import 'estoque_localizado_service.dart';
import 'models.dart';

const List<String> _andarNomes = ['Base', 'Meio', 'Topo'];

/// Abre o dialog de quantidades por endereço de um produto. Chamado ao tocar
/// numa caixa existente (gôndola ou estante), fora do modo de edição de layout.
Future<void> mostrarQuantidadeDialog(
  BuildContext context, {
  required String produtoCodigo,
  required String produtoNome,
  required String localTipo, // 'gondola' | 'estante'
  required int localNum,
  required int faceOuColuna,
  required int andarOuNivel,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _QuantidadeDialog(
      produtoCodigo: produtoCodigo,
      produtoNome:   produtoNome,
      localTipo:     localTipo,
      localNum:      localNum,
      faceOuColuna:  faceOuColuna,
      andarOuNivel:  andarOuNivel,
    ),
  );
}

String _labelEndereco(EnderecoLocalizado e) {
  if (e.ehGondola) {
    final andar = e.andarOuNivel.clamp(0, 2);
    return 'Gôndola ${e.localNum} · Face ${e.faceOuColuna} · Andar ${_andarNomes[andar]}';
  }
  final letra = letraEstanteCelula(e.localNum, e.faceOuColuna, e.andarOuNivel);
  return 'Estante ${e.localNum} · $letra';
}

String _fmtQtd(double q) =>
    q == q.roundToDouble() ? q.round().toString() : q.toString();

String _fmtDelta(double delta) =>
    delta == 0 ? '0' : (delta > 0 ? '+${_fmtQtd(delta)}' : _fmtQtd(delta));

String _fmtData(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
}

String _fmtDataCurta(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}/${two(dt.month)}';
}

double _parseQtd(String s) =>
    double.tryParse(s.trim().replaceAll(',', '.')) ?? 0;

class _LinhaEndereco {
  EnderecoLocalizado endereco;
  final bool destaque;
  final TextEditingController controller;
  bool dirty;

  _LinhaEndereco({
    required this.endereco,
    required this.destaque,
    this.dirty = false,
  }) : controller = TextEditingController(text: _fmtQtd(endereco.quantidade));

  double get quantidadeAtual => _parseQtd(controller.text);
}

class _QuantidadeDialog extends StatefulWidget {
  final String produtoCodigo;
  final String produtoNome;
  final String localTipo;
  final int localNum;
  final int faceOuColuna;
  final int andarOuNivel;

  const _QuantidadeDialog({
    required this.produtoCodigo,
    required this.produtoNome,
    required this.localTipo,
    required this.localNum,
    required this.faceOuColuna,
    required this.andarOuNivel,
  });

  @override
  State<_QuantidadeDialog> createState() => _QuantidadeDialogState();
}

class _QuantidadeDialogState extends State<_QuantidadeDialog> {
  final _service = EstoqueLocalizadoService();

  bool    _carregando = true;
  bool    _salvando   = false;
  double? _qtdSistema;
  List<_LinhaEndereco> _linhas = [];

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    for (final l in _linhas) {
      l.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _carregar() async {
    final resultados = await Future.wait([
      _service.fetchEnderecosProduto(widget.produtoCodigo),
      _service.buscarInfoMestre(widget.produtoCodigo),
      _service.fetchEnderecosDesatualizados(),
    ]);
    final enderecos = resultados[0] as List<EnderecoLocalizado>;
    final info      = resultados[1] as InfoEstoqueMestre?;

    final tocado = EnderecoLocalizado(
      produtoCodigo: widget.produtoCodigo,
      localTipo:     widget.localTipo,
      localNum:      widget.localNum,
      faceOuColuna:  widget.faceOuColuna,
      andarOuNivel:  widget.andarOuNivel,
      quantidade:    0,
    );
    final jaExiste = enderecos.any((e) => e.mesmoEndereco(tocado));

    final todos = [
      if (!jaExiste) tocado,
      ...enderecos,
    ];
    todos.sort((a, b) {
      final aTocado = a.mesmoEndereco(tocado);
      final bTocado = b.mesmoEndereco(tocado);
      if (aTocado == bTocado) return 0;
      return aTocado ? -1 : 1;
    });

    if (!mounted) return;
    setState(() {
      _linhas = todos.map((e) {
        final destaque = e.mesmoEndereco(tocado);
        return _LinhaEndereco(
          endereco: e,
          destaque: destaque,
          // Endereço novo: precisa ser criado mesmo que o usuário não altere
          // o campo (permanece em 0), então já nasce "dirty".
          dirty: destaque && !jaExiste,
        );
      }).toList();
      _qtdSistema = info?.qtdSistema;
      _carregando = false;
    });
  }

  double get _totalContado =>
      _linhas.fold<double>(0, (soma, l) => soma + l.quantidadeAtual);

  // Endereço novo (l.endereco.atualizadoEm == null) nunca está desatualizado
  // — não há nada gravado ainda pra comparar.
  EnderecoDesatualizado? _avisoDesatualizado(EnderecoLocalizado endereco) =>
      endereco.atualizadoEm == null ? null : _service.infoDesatualizado(endereco);

  Future<bool> _salvarEditados() async {
    var ok = true;
    for (final l in _linhas.where((l) => l.dirty)) {
      final salvo = await _service.upsertQuantidade(
        produtoCodigo: l.endereco.produtoCodigo,
        localTipo:     l.endereco.localTipo,
        localNum:      l.endereco.localNum,
        faceOuColuna:  l.endereco.faceOuColuna,
        andarOuNivel:  l.endereco.andarOuNivel,
        quantidade:    l.quantidadeAtual,
      );
      ok = ok && salvo;
    }
    return ok;
  }

  Future<void> _onSalvar() async {
    if (!_linhas.any((l) => l.dirty)) {
      Navigator.pop(context);
      return;
    }
    setState(() => _salvando = true);
    final ok = await _salvarEditados();
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          ok ? 'Quantidades salvas.' : 'Falha ao salvar algumas quantidades.'),
      backgroundColor: ok ? const Color(0xFF2a3a1a) : const Color(0xFF5a1a1a),
    ));
  }

  Future<void> _onConcluirContagem() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Concluir contagem',
            style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        content: Text(
          'Isso vai sincronizar o total contado (${_fmtQtd(_totalContado)} un) de '
          '"${widget.produtoNome}" com o inventário cíclico. Confirmar?',
          style: const TextStyle(color: Color(0xFFb0ada8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2e6b46),
                foregroundColor: Colors.white),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    if (confirmar != true) return;

    setState(() => _salvando = true);
    final salvouEditados = await _salvarEditados();
    final resultado = await _service.concluirContagem(widget.produtoCodigo);
    if (!mounted) return;
    Navigator.pop(context);

    if (resultado == null || !salvouEditados) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Falha ao concluir a contagem.'),
        backgroundColor: Color(0xFF5a1a1a),
      ));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(resultado.status == 'ok'
          ? 'Contagem concluída — sem divergência.'
          : 'Contagem concluída — divergência de ${_fmtDelta(resultado.divergencia)}.'),
      backgroundColor: resultado.status == 'ok'
          ? const Color(0xFF2a3a1a)
          : const Color(0xFF5a3a1a),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF141a22),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.produtoNome,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          Text(widget.produtoCodigo,
              style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 12)),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: _carregando
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ..._linhas.map(_buildLinha),
                  const SizedBox(height: 10),
                  _buildResumo(),
                ],
              ),
      ),
      actions: _carregando
          ? null
          : [
              TextButton(
                onPressed: _salvando ? null : () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              OutlinedButton(
                onPressed: _salvando ? null : _onSalvar,
                child: const Text('Salvar'),
              ),
              ElevatedButton(
                onPressed: _salvando ? null : _onConcluirContagem,
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2e6b46),
                    foregroundColor: Colors.white),
                child: _salvando
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Concluir contagem'),
              ),
            ],
    );
  }

  Widget _buildLinha(_LinhaEndereco l) {
    final aviso = _avisoDesatualizado(l.endereco);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: l.destaque ? const Color(0xFF162416) : const Color(0xFF0d1117),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: l.destaque
                ? const Color(0xFF2e6b46)
                : const Color(0xFF262b33)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _labelEndereco(l.endereco),
                  style: TextStyle(
                    color: l.destaque ? Colors.white : const Color(0xFFb0ada8),
                    fontSize: 13,
                    fontWeight: l.destaque ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                if (l.endereco.atualizadoEm != null)
                  Text(
                    'Atualizado em ${_fmtData(l.endereco.atualizadoEm!)}',
                    style: const TextStyle(
                        color: Color(0xFF6a7a88), fontSize: 10),
                  ),
                if (aviso != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '⚠️ Total conferido em ${_fmtDataCurta(aviso.ultimaContagemEm)} '
                      '· este endereço foi atualizado pela última vez em '
                      '${_fmtDataCurta(aviso.atualizadoEm)}',
                      style: const TextStyle(
                          color: Color(0xFFe0a030), fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: TextField(
              controller: l.controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                suffixText: ' un',
                suffixStyle: TextStyle(color: Color(0xFF6a7a88), fontSize: 11),
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onChanged: (_) => setState(() => l.dirty = true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResumo() {
    final contado = _totalContado;
    final sistema = _qtdSistema;
    final delta   = sistema == null ? null : contado - sistema;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0d1117),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(fontSize: 13, color: Color(0xFFb0ada8)),
          children: [
            const TextSpan(text: 'Contado: '),
            TextSpan(
                text: _fmtQtd(contado),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
            if (sistema != null) ...[
              const TextSpan(text: ' · Sistema: '),
              TextSpan(
                  text: _fmtQtd(sistema),
                  style: const TextStyle(color: Colors.white)),
              const TextSpan(text: ' · Δ '),
              TextSpan(
                text: _fmtDelta(delta!),
                style: TextStyle(
                  color: delta == 0
                      ? const Color(0xFF6fcf97)
                      : const Color(0xFFe57373),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
