import 'package:flutter/material.dart';

import 'caixa_mista.dart';
import 'galpao_saldo.dart';
import 'models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Folha da caixa mista: os produtos de UMA caixa da estante
// ─────────────────────────────────────────────────────────────────────────────
//
// Abre por baixo ao tocar numa caixa mista, ou pelo "Outro produto nesta
// caixa" do diálogo de quantidade de uma caixa comum. Só mostra e pede: quem
// grava é a EstantePage (layout) e o diálogo de quantidade de sempre
// (estoque_localizado) — a folha recebe o estado pronto em [vista] e se
// redesenha quando a página o troca.

/// Um produto da caixa, pronto para a folha.
class ItemCaixaVista {
  final String codigo;
  final String nome;
  final Color corCategoria;

  /// Quantidade em estoque_localizado NESTA posição (null: nunca contado).
  final double? qtdAqui;
  final SaldoProduto? saldo;

  const ItemCaixaVista({
    required this.codigo,
    required this.nome,
    required this.corCategoria,
    this.qtdAqui,
    this.saldo,
  });

  Color get corStatus => corDaFatia(saldo, corSemSaldo: corCategoria);
}

/// O estado da caixa que a folha mostra. Null em [ValueNotifier] = a caixa
/// saiu da estante (a folha se fecha).
class CaixaMistaVista {
  final String endereco;
  final String? nome;
  final List<ItemCaixaVista> itens;
  final bool ocupado;

  const CaixaMistaVista({
    required this.endereco,
    required this.nome,
    required this.itens,
    this.ocupado = false,
  });

  bool get cheia => itens.length >= produtosMaxPorCaixa;
}

const _fundo = Color(0xFF141a22);
const _painel = Color(0xFF0d1117);
const _linha = Color(0xFF262d38);
const _laranja = Color(0xFFe87722);
const _laranjaTx = Color(0xFFf0a35e);
const _texto = Color(0xFFe6e8ec);
const _apagado = Color(0xFF8a9aa8);
const _verde = Color(0xFF2e6b46);
const _verdeTx = Color(0xFF6fcf97);
const _vermelhoTx = Color(0xFFe57373);
const _azulTx = Color(0xFF6ea8ff);

String _fmt(double q) =>
    q == q.roundToDouble() ? q.round().toString() : q.toString();

/// Abre a folha. Termina quando ela fecha.
Future<void> mostrarCaixaMistaSheet(
  BuildContext context, {
  required ValueNotifier<CaixaMistaVista?> vista,
  required List<Produto> Function(String query) filtrar,
  required Future<void> Function(Produto produto) onAdicionar,
  required Future<void> Function(String codigo) onTirar,
  required Future<void> Function(String codigo) onQuantidade,
  required Future<void> Function(String? nome) onNome,
  required Future<void> Function() onRemoverCaixa,
  bool focarBusca = false,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CaixaMistaSheet(
        vista: vista,
        filtrar: filtrar,
        onAdicionar: onAdicionar,
        onTirar: onTirar,
        onQuantidade: onQuantidade,
        onNome: onNome,
        onRemoverCaixa: onRemoverCaixa,
        focarBusca: focarBusca,
      ),
    );

class CaixaMistaSheet extends StatefulWidget {
  final ValueNotifier<CaixaMistaVista?> vista;
  final List<Produto> Function(String query) filtrar;
  final Future<void> Function(Produto produto) onAdicionar;
  final Future<void> Function(String codigo) onTirar;
  final Future<void> Function(String codigo) onQuantidade;
  final Future<void> Function(String? nome) onNome;
  final Future<void> Function() onRemoverCaixa;
  final bool focarBusca;

  const CaixaMistaSheet({
    super.key,
    required this.vista,
    required this.filtrar,
    required this.onAdicionar,
    required this.onTirar,
    required this.onQuantidade,
    required this.onNome,
    required this.onRemoverCaixa,
    this.focarBusca = false,
  });

  @override
  State<CaixaMistaSheet> createState() => _CaixaMistaSheetState();
}

class _CaixaMistaSheetState extends State<CaixaMistaSheet> {
  final _busca = TextEditingController();
  final _nome = TextEditingController();
  final _focoBusca = FocusNode();
  final _focoNome = FocusNode();
  List<Produto> _sugestoes = const [];
  bool _confirmarRemocao = false;
  // Último nome mandado à página: "Concluir" e a saída do campo disparam
  // juntos, e cada envio é um salvamento do layout inteiro.
  String? _nomeEnviado;

  @override
  void initState() {
    super.initState();
    _nome.text = widget.vista.value?.nome ?? '';
    widget.vista.addListener(_aoMudarVista);
    // O nome grava ao sair do campo (ou no "concluído" do teclado), não a
    // cada letra: cada gravação é um salvamento do layout inteiro.
    _focoNome.addListener(() {
      if (!_focoNome.hasFocus) _gravarNome();
    });
    if (widget.focarBusca) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focoBusca.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    widget.vista.removeListener(_aoMudarVista);
    _busca.dispose();
    _nome.dispose();
    _focoBusca.dispose();
    _focoNome.dispose();
    super.dispose();
  }

  void _aoMudarVista() {
    final v = widget.vista.value;
    if (v == null) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    if (!_focoNome.hasFocus && _nome.text != (v.nome ?? '')) {
      _nome.text = v.nome ?? '';
    }
    if (mounted) setState(() {});
  }

  void _gravarNome() {
    final novo = _nome.text.trim();
    if (novo == (widget.vista.value?.nome ?? '') || novo == _nomeEnviado)
      return;
    _nomeEnviado = novo;
    widget.onNome(novo);
  }

  Future<void> _escolher(Produto p) async {
    _busca.clear();
    setState(() => _sugestoes = const []);
    _focoBusca.unfocus();
    await widget.onAdicionar(p);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vista.value;
    if (v == null) return const SizedBox.shrink();
    final n = v.itens.length;
    final total = v.itens.fold<double>(0, (s, i) => s + (i.qtdAqui ?? 0));
    final altura = MediaQuery.of(context).size.height;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: altura * 0.88),
        decoration: const BoxDecoration(
          color: _fundo,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(top: BorderSide(color: Color(0x59e87722))),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF3a414b),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _cabecalho(v, n, total),
              const SizedBox(height: 10),
              _campoBusca(v, n),
              if (_sugestoes.isNotEmpty) _listaSugestoes(v),
              const SizedBox(height: 8),
              const _Legenda(),
              const SizedBox(height: 8),
              Flexible(child: _lista(v)),
              const SizedBox(height: 10),
              _rodape(v),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cabecalho(CaixaMistaVista v, int n, double total) => Row(
        children: [
          _IconeListrado(cores: [for (final i in v.itens) i.corStatus]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('caixa_mista_nome'),
                  controller: _nome,
                  focusNode: _focoNome,
                  maxLength: 40,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _focoNome.unfocus(),
                  style: const TextStyle(
                    color: _texto,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    counterText: '',
                    hintText: 'Nome da caixa (opcional)',
                    hintStyle: TextStyle(color: _apagado, fontSize: 15),
                    contentPadding: EdgeInsets.symmetric(vertical: 4),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF3a414b)),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: _laranja),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: v.endereco,
                      style: const TextStyle(
                        color: _laranja,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(
                      text: ' · $n/$produtosMaxPorCaixa produtos'
                          '${total > 0 ? ' · ${_fmt(total)} un' : ''}',
                    ),
                  ]),
                  style: const TextStyle(color: _apagado, fontSize: 12),
                ),
              ],
            ),
          ),
          if (n > 1) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: _laranja,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '+$n',
                style: const TextStyle(
                  color: Color(0xFF0b0d10),
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      );

  Widget _campoBusca(CaixaMistaVista v, int n) => TextField(
        key: const Key('caixa_mista_busca'),
        controller: _busca,
        focusNode: _focoBusca,
        enabled: !v.cheia && !v.ocupado,
        onChanged: (q) =>
            setState(() => _sugestoes = widget.filtrar(q).take(6).toList()),
        style: const TextStyle(color: _texto, fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: _painel,
          prefixIcon: const Icon(Icons.add, color: _laranja, size: 20),
          hintText: v.cheia
              ? 'Caixa cheia ($produtosMaxPorCaixa/$produtosMaxPorCaixa) — '
                  'tire um produto para pôr outro'
              : 'Outro produto nesta caixa ($n/$produtosMaxPorCaixa)',
          hintStyle: const TextStyle(color: _apagado, fontSize: 13),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: _linha),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: _linha),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: _laranja),
          ),
        ),
      );

  Widget _listaSugestoes(CaixaMistaVista v) => Container(
        margin: const EdgeInsets.only(top: 6),
        constraints: const BoxConstraints(maxHeight: 200),
        decoration: BoxDecoration(
          color: const Color(0xFF12161b),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: _linha),
        ),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final p in _sugestoes)
              InkWell(
                onTap: () => _escolher(p),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  child: Row(children: [
                    Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: p.cor,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Text(p.codigo,
                        style:
                            const TextStyle(color: _laranjaTx, fontSize: 11)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.nome,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _texto, fontSize: 13),
                      ),
                    ),
                    if (v.itens.any((i) => i.codigo == p.codigo))
                      const Text('✓ já está',
                          style: TextStyle(color: _verdeTx, fontSize: 10)),
                  ]),
                ),
              ),
          ],
        ),
      );

  Widget _lista(CaixaMistaVista v) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1a1e24),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _linha),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: v.itens.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, thickness: 1, color: Color(0xFF1f242b)),
          itemBuilder: (_, i) => _linhaItem(v, v.itens[i]),
        ),
      );

  Widget _linhaItem(CaixaMistaVista v, ItemCaixaVista item) {
    final s = item.saldo;
    final String status;
    final Color corStatusTx;
    if (s == null) {
      status = 'sem saldo no sistema';
      corStatusTx = _apagado;
    } else if (s.falta) {
      status = 'faltam ${_fmt(s.quantoFalta)}';
      corStatusTx = _vermelhoTx;
    } else if (s.sobra) {
      status = '+${_fmt(s.quantoSobra)} além do sistema';
      corStatusTx = _azulTx;
    } else {
      status = 'ok';
      corStatusTx = _verdeTx;
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 6, color: item.corStatus),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(children: [
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: item.corCategoria,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.codigo,
                          style:
                              const TextStyle(color: _laranjaTx, fontSize: 11)),
                      Text(
                        item.nome,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _texto, fontSize: 13),
                      ),
                      Text.rich(
                        TextSpan(children: [
                          if (s != null)
                            TextSpan(
                              text: 'sist. ${_fmt(s.qtdSistema)} · '
                                  'end. ${_fmt(s.enderecado)} · ',
                            ),
                          TextSpan(
                            text: status,
                            style: TextStyle(
                              color: corStatusTx,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ]),
                        style: const TextStyle(color: _apagado, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // A quantidade abre o diálogo de sempre: é ele que grava em
                // estoque_localizado, com contagem, histórico e conflitos.
                OutlinedButton(
                  key: Key('caixa_mista_qtd_${item.codigo}'),
                  onPressed:
                      v.ocupado ? null : () => widget.onQuantidade(item.codigo),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _texto,
                    side: const BorderSide(color: Color(0xFF3a4450)),
                    minimumSize: const Size(58, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    item.qtdAqui == null ? '—' : _fmt(item.qtdAqui!),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  key: Key('caixa_mista_tirar_${item.codigo}'),
                  tooltip: 'Tirar da caixa',
                  onPressed:
                      v.ocupado ? null : () => widget.onTirar(item.codigo),
                  icon: const Icon(Icons.delete_outline,
                      color: _vermelhoTx, size: 20),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rodape(CaixaMistaVista v) => Row(
        children: [
          Flexible(
            child: OutlinedButton.icon(
              key: const Key('caixa_mista_remover'),
              onPressed: v.ocupado
                  ? null
                  : () {
                      if (!_confirmarRemocao) {
                        setState(() => _confirmarRemocao = true);
                        return;
                      }
                      widget.onRemoverCaixa();
                    },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(
                _confirmarRemocao
                    ? 'Toque de novo p/ remover'
                    : 'Remover caixa',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: _confirmarRemocao ? Colors.white : _vermelhoTx,
                backgroundColor:
                    _confirmarRemocao ? const Color(0xFF3a1a1a) : null,
                side: const BorderSide(color: Color(0xFF3a2020)),
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              key: const Key('caixa_mista_concluir'),
              onPressed: () {
                _gravarNome();
                Navigator.of(context).maybePop();
              },
              icon: v.ocupado
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check, size: 18),
              label: const Text('Concluir'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _verde,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 44),
              ),
            ),
          ),
        ],
      );
}

/// Miniatura da caixa listrada: uma faixa por produto, na ordem da lista.
class _IconeListrado extends StatelessWidget {
  final List<Color> cores;
  const _IconeListrado({required this.cores});

  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 34,
        padding: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: corFileteFatia,
          borderRadius: BorderRadius.circular(4),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Column(
            children: [
              for (var i = 0; i < cores.length; i++) ...[
                if (i > 0) const SizedBox(height: 1),
                Expanded(child: Container(color: cores[i])),
              ],
            ],
          ),
        ),
      );
}

class _Legenda extends StatelessWidget {
  const _Legenda();

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String t) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 8,
              decoration: BoxDecoration(
                color: c,
                border: Border.all(color: corFileteFatia),
              ),
            ),
            const SizedBox(width: 5),
            Text(t, style: const TextStyle(color: _apagado, fontSize: 11)),
          ],
        );
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        item(const Color(0xFFe53935), 'falta endereçar'),
        item(const Color(0xFF1565C0), 'acima do saldo'),
        item(corFatiaOk, 'ok'),
      ],
    );
  }
}
