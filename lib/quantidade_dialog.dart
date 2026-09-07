import 'dart:async';

import 'package:flutter/material.dart';

import 'estoque_localizado_service.dart';
import 'models.dart';
import 'sugestao_deducao.dart';
import 'turso_service.dart';

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
      produtoNome: produtoNome,
      localTipo: localTipo,
      localNum: localNum,
      faceOuColuna: faceOuColuna,
      andarOuNivel: andarOuNivel,
    ),
  );
}

String _labelEndereco(EnderecoLocalizado e) {
  if (e.ehGondola) {
    final andar = e.andarOuNivel.clamp(0, 2);
    return 'Gôndola ${e.localNum} · Face ${e.faceOuColuna} · Andar ${_andarNomes[andar]}';
  }
  final letra = letraEstanteCelula(e.localNum, e.faceOuColuna, e.andarOuNivel);
  // Endereço antigo de estante que saiu da loja (substituída pela Estante
  // Parede): continua listado com a quantidade para o usuário zerar/migrar,
  // mas marcado — a estrutura não existe mais no app.
  if (estantesRemovidas.contains(e.localNum)) {
    return 'Estante ${e.localNum} · $letra (removida)';
  }
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
  // "Conferi fisicamente e a quantidade está certa" — ao salvar, a linha é
  // regravada com o mesmo valor só pra renovar o atualizado_em (limpa o selo
  // âmbar de endereço desatualizado).
  bool confirmado = false;
  // Linhas de endereço ainda não gravado nascem dirty e precisam continuar
  // dirty mesmo que o ✓ seja desligado.
  final bool nasceuDirty;

  _LinhaEndereco({
    required this.endereco,
    required this.destaque,
    this.dirty = false,
  }) : nasceuDirty = dirty,
       controller = TextEditingController(text: _fmtQtd(endereco.quantidade));

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
  // Controller próprio da lista de endereços: a Scrollbar precisa dele pra
  // manter o polegar sempre visível (thumbVisibility).
  final _scrollController = ScrollController();

  bool _carregando = true;
  bool _salvando = false;
  bool _editou = false;
  String? _erroCarga;
  int _versaoCarga = 0;
  double? _qtdSistema;
  List<_LinhaEndereco> _linhas = [];
  // Sugestão de abatimento calculada uma única vez a partir dos valores
  // PERSISTIDOS (imune à digitação em andamento). Null = sem excesso ou sem
  // linha no estoque_mestre.
  ResultadoSugestao? _sugestao;
  bool _sugestaoAplicada = false;

  @override
  void initState() {
    super.initState();
    TursoService().dataRevision.addListener(_dadosAtualizados);
    _carregar();
    unawaited(_carregarAvisosDesatualizados());
  }

  void _dadosAtualizados() {
    if (!mounted || _editou || _salvando) return;
    unawaited(_carregar());
  }

  // Linhas excluídas durante a sessão do dialog: os controllers não podem ser
  // descartados no mesmo frame em que o campo ainda pode estar montado, então
  // ficam aqui até o dispose do dialog.
  final List<_LinhaEndereco> _linhasRemovidas = [];

  @override
  void dispose() {
    TursoService().dataRevision.removeListener(_dadosAtualizados);
    for (final l in _linhas) {
      l.controller.dispose();
    }
    for (final l in _linhasRemovidas) {
      l.controller.dispose();
    }
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _carregar() async {
    final versao = ++_versaoCarga;
    // O saldo do sistema não bloqueia a abertura das quantidades locais.
    unawaited(_carregarSaldo(versao));
    List<EnderecoLocalizado> enderecos;
    try {
      enderecos = await _service.fetchEnderecosProduto(
        widget.produtoCodigo,
        usarCache: true,
      );
    } catch (_) {
      if (!mounted || versao != _versaoCarga || _editou || _salvando) return;
      setState(() {
        _carregando = false;
        _erroCarga =
            'Não foi possível carregar as quantidades. Tente novamente.';
      });
      return;
    }
    if (!mounted || versao != _versaoCarga || _editou || _salvando) return;

    final tocado = EnderecoLocalizado(
      produtoCodigo: widget.produtoCodigo,
      localTipo: widget.localTipo,
      localNum: widget.localNum,
      faceOuColuna: widget.faceOuColuna,
      andarOuNivel: widget.andarOuNivel,
      quantidade: 0,
    );
    final jaExiste = enderecos.any((e) => e.mesmoEndereco(tocado));

    final todos = [if (!jaExiste) tocado, ...enderecos];
    todos.sort((a, b) {
      final aTocado = a.mesmoEndereco(tocado);
      final bTocado = b.mesmoEndereco(tocado);
      if (aTocado == bTocado) return 0;
      return aTocado ? -1 : 1;
    });

    if (!mounted) return;
    setState(() {
      _linhasRemovidas.addAll(_linhas);
      _erroCarga = null;
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
      _recalcularSugestao();
      _carregando = false;
    });
  }

  Future<void> _carregarSaldo(int versao) async {
    try {
      final info = await _service.buscarInfoMestre(
        widget.produtoCodigo,
        usarCache: true,
      );
      if (!mounted || versao != _versaoCarga || _editou || _salvando) return;
      setState(() {
        _qtdSistema = info?.qtdSistema;
        _recalcularSugestao();
      });
    } catch (_) {
      // Saldo indisponível não é saldo zero; as quantidades seguem visíveis.
    }
  }

  void _recalcularSugestao() {
    final saldo = _qtdSistema;
    final enderecos = _linhas.map((l) => l.endereco).toList();
    _sugestao = saldo == null
        ? null
        : sugerirDeducao(
            enderecos: enderecos,
            excesso:
                enderecos.fold<double>(0, (s, e) => s + e.quantidade) - saldo,
          );
  }

  /// Aquece o cache de endereços desatualizados e repinta quando ele chega —
  /// os avisos aparecem alguns instantes depois do resto do dialog, em vez de
  /// segurarem a abertura inteira.
  Future<void> _carregarAvisosDesatualizados() async {
    await _service.fetchEnderecosDesatualizados();
    if (!mounted) return;
    setState(() {});
  }

  double get _totalContado =>
      _linhas.fold<double>(0, (soma, l) => soma + l.quantidadeAtual);

  // Endereço novo (l.endereco.atualizadoEm == null) nunca está desatualizado
  // — não há nada gravado ainda pra comparar.
  EnderecoDesatualizado? _avisoDesatualizado(EnderecoLocalizado endereco) =>
      endereco.atualizadoEm == null
      ? null
      : _service.infoDesatualizado(endereco);

  /// Preenche os campos com as quantidades sugeridas e marca as linhas como
  /// editadas. Nada é gravado no banco até Salvar/Concluir contagem — o
  /// usuário ainda confere fisicamente.
  void _aplicarSugestao() {
    _editou = true;
    final sugestao = _sugestao;
    if (sugestao == null) return;
    setState(() {
      for (final d in sugestao.deducoes) {
        for (final l in _linhas) {
          if (!l.endereco.mesmoEndereco(d.endereco)) continue;
          l.controller.text = _fmtQtd(d.qtdSugerida);
          l.dirty = true;
          l.confirmado = false;
        }
      }
      _sugestaoAplicada = true;
    });
  }

  void _toggleConfirmado(_LinhaEndereco l) {
    _editou = true;
    setState(() {
      if (l.confirmado) {
        l.confirmado = false;
        // Só desfaz o dirty se o campo continua com o valor persistido e a
        // linha não nasceu dirty (endereço novo precisa ser criado ao salvar).
        if (!l.nasceuDirty &&
            l.controller.text == _fmtQtd(l.endereco.quantidade)) {
          l.dirty = false;
        }
      } else {
        l.confirmado = true;
        l.dirty = true;
      }
    });
  }

  void _removerLinhaLocal(_LinhaEndereco l) {
    _editou = true;
    setState(() {
      _linhas.remove(l);
      _linhasRemovidas.add(l);
    });
    if (_linhas.isEmpty && mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Endereço excluído.'),
          backgroundColor: Color(0xFF2a3a1a),
        ),
      );
    }
  }

  Future<void> _excluirEndereco(_LinhaEndereco l) async {
    _editou = true;
    // Endereço recém-tocado que nunca foi gravado: não existe no banco,
    // basta tirar da lista.
    if (l.endereco.atualizadoEm == null && l.endereco.id == null) {
      _removerLinhaLocal(l);
      return;
    }

    final qtd = l.endereco.quantidade;
    final avisos = <String>[
      'Excluir o endereço ${_labelEndereco(l.endereco)}? '
          'O registro de quantidade deste endereço será apagado.',
      if (qtd > 0)
        'Este endereço tem ${_fmtQtd(qtd)} un registradas — o total contado '
            'do produto vai diminuir.',
      if (l.dirty) 'A edição não salva desta linha será descartada.',
    ];
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Excluir endereço',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          avisos.join('\n\n'),
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
              backgroundColor: const Color(0xFF8b1a1a),
              foregroundColor: Colors.white,
            ),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;

    setState(() => _salvando = true);
    final ok = await _service.deleteEndereco(
      produtoCodigo: l.endereco.produtoCodigo,
      localTipo: l.endereco.localTipo,
      localNum: l.endereco.localNum,
      faceOuColuna: l.endereco.faceOuColuna,
      andarOuNivel: l.endereco.andarOuNivel,
    );
    if (!mounted) return;
    setState(() => _salvando = false);
    if (ok) {
      _removerLinhaLocal(l);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Falha ao excluir o endereço.'),
          backgroundColor: Color(0xFF5a1a1a),
        ),
      );
    }
  }

  Future<bool> _salvarEditados() async {
    var ok = true;
    for (final l in _linhas.where((l) => l.dirty)) {
      final salvo = await _service.upsertQuantidade(
        produtoCodigo: l.endereco.produtoCodigo,
        localTipo: l.endereco.localTipo,
        localNum: l.endereco.localNum,
        faceOuColuna: l.endereco.faceOuColuna,
        andarOuNivel: l.endereco.andarOuNivel,
        quantidade: l.quantidadeAtual,
      );
      ok = ok && salvo;
    }
    return ok;
  }

  /// Sai do dialog sem gravar. Se houver edição pendente, confirma antes —
  /// o botão é grande e fica ao lado das ações de gravação, então um toque
  /// errado não pode jogar a contagem fora em silêncio.
  Future<void> _onVoltar() async {
    if (!_linhas.any((l) => l.dirty)) {
      Navigator.pop(context);
      return;
    }
    final descartar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Descartar alterações?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: const Text(
          'Você alterou quantidades e ainda não salvou. Se voltar agora, '
          'essas alterações serão perdidas.',
          style: TextStyle(color: Color(0xFFb0ada8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Continuar contando'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8b1a1a),
              foregroundColor: Colors.white,
            ),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    if (descartar != true || !mounted) return;
    Navigator.pop(context);
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Quantidades salvas.' : 'Falha ao salvar algumas quantidades.',
        ),
        backgroundColor: ok ? const Color(0xFF2a3a1a) : const Color(0xFF5a1a1a),
      ),
    );
  }

  Future<void> _onConcluirContagem() async {
    _editou = true;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Concluir contagem',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
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
              foregroundColor: Colors.white,
            ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Falha ao concluir a contagem.'),
          backgroundColor: Color(0xFF5a1a1a),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          resultado.status == 'ok'
              ? 'Contagem concluída — sem divergência.'
              : 'Contagem concluída — divergência de ${_fmtDelta(resultado.divergencia)}.',
        ),
        backgroundColor: resultado.status == 'ok'
            ? const Color(0xFF2a3a1a)
            : const Color(0xFF5a3a1a),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Em celular a margem padrão do AlertDialog (40 de cada lado) espreme
    // demais os cards de endereço; 16 dá espaço pro texto respirar.
    final larguraTela = MediaQuery.of(context).size.width;
    final largura = larguraTela - 64 < 380 ? larguraTela - 64 : 380.0;
    return AlertDialog(
      backgroundColor: const Color(0xFF141a22),
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.produtoNome,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            widget.produtoCodigo,
            style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 12),
          ),
        ],
      ),
      titlePadding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      content: SizedBox(
        width: largura,
        child: _carregando
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              )
            // A lista de endereços rola (com barra sempre visível) e o resumo
            // fica fixo no rodapé: com muitos endereços o conteúdo passava da
            // altura da tela e os últimos campos ficavam inacessíveis.
            : _erroCarga != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_erroCarga!),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _carregando = true;
                        _erroCarga = null;
                      });
                      unawaited(_carregar());
                    },
                    child: const Text('Tentar novamente'),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        // Espaço pro polegar da barra não cobrir os cards.
                        padding: const EdgeInsets.only(right: 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_sugestao != null)
                              _buildSugestaoCard(_sugestao!),
                            ..._linhas.map(_buildLinha),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildResumo(),
                ],
              ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      // O rodapé existe desde o primeiro frame, inclusive durante a carga: com
      // `_carregando ? null : …` o "Voltar" só nascia depois das consultas
      // terminarem, e com o cache de badges frio o usuário ficava num modal sem
      // saída. As ações de GRAVAÇÃO é que ficam travadas enquanto carrega —
      // salvar antes de saber o que já existe no endereço apagaria contagem.
      actions: [_buildAcoes()],
    );
  }

  /// Rodapé de ações: "Voltar" ocupa toda a coluna da esquerda, com alvo alto
  /// (92) e afastado das ações de gravação, que ficam empilhadas à direita.
  /// O antigo "Cancelar" era um TextButton pequeno colado no "Salvar" — fácil
  /// de errar no celular e perder a contagem.
  Widget _buildAcoes() {
    return Row(
      // O rodapé fica sob altura não limitada (OverflowBar do AlertDialog),
      // então nada de `stretch`: a altura do Voltar é fixada pra casar com a
      // pilha Salvar + Concluir da direita (40 + 8 + 44).
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          flex: 4,
          child: OutlinedButton.icon(
            onPressed: _salvando ? null : _onVoltar,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Voltar'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFb0ada8),
              side: const BorderSide(color: Color(0xFF3a4450)),
              minimumSize: const Size(0, 92),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 5,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton(
                onPressed: (_salvando || _carregando || _erroCarga != null)
                    ? null
                    : _onSalvar,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Salvar'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: (_salvando || _carregando || _erroCarga != null)
                    ? null
                    : _onConcluirContagem,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2e6b46),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: _salvando
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Concluir contagem',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSugestaoCard(ResultadoSugestao sugestao) {
    final excesso =
        sugestao.deducoes.fold<double>(0, (soma, d) => soma + d.deduzido) +
        sugestao.restante;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0d1117),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF5a3a1a)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '💡 Δ +${_fmtQtd(excesso)} vs sistema — sugestão (gôndola primeiro)',
            style: const TextStyle(
              color: Color(0xFFe0a030),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          ...sugestao.deducoes.map(
            (d) => Text(
              'Provavelmente saíram ${_fmtQtd(d.deduzido)} un de '
              '${_labelEndereco(d.endereco)}',
              style: const TextStyle(color: Color(0xFFb0ada8), fontSize: 12),
            ),
          ),
          if (sugestao.restante > 0)
            Text(
              'Ainda restam ${_fmtQtd(sugestao.restante)} un não localizadas.',
              style: const TextStyle(color: Color(0xFFe57373), fontSize: 12),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed:
                    _salvando || _sugestaoAplicada || sugestao.deducoes.isEmpty
                    ? null
                    : _aplicarSugestao,
                icon: Icon(
                  _sugestaoAplicada ? Icons.check : Icons.auto_fix_high,
                  size: 16,
                  color: _sugestaoAplicada
                      ? const Color(0xFF6fcf97)
                      : const Color(0xFFe0a030),
                ),
                label: Text(
                  _sugestaoAplicada ? 'Sugestão aplicada' : 'Aplicar sugestão',
                  style: TextStyle(
                    color: _sugestaoAplicada
                        ? const Color(0xFF6fcf97)
                        : const Color(0xFFe0a030),
                    fontSize: 12,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: _sugestaoAplicada
                        ? const Color(0xFF2e6b46)
                        : const Color(0xFF5a3a1a),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Confira fisicamente antes de salvar.',
                  style: TextStyle(color: Color(0xFF6a7a88), fontSize: 10),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLinha(_LinhaEndereco l) {
    final aviso = _avisoDesatualizado(l.endereco);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: l.destaque
            ? const Color(0xFF162416)
            : l.confirmado
            ? const Color(0xFF12211a)
            : const Color(0xFF0d1117),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: l.destaque || l.confirmado
              ? const Color(0xFF2e6b46)
              : const Color(0xFF262b33),
        ),
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
                    fontWeight: l.destaque
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
                if (l.endereco.atualizadoEm != null)
                  Text(
                    'Atualizado em ${_fmtData(l.endereco.atualizadoEm!)}',
                    style: const TextStyle(
                      color: Color(0xFF6a7a88),
                      fontSize: 10,
                    ),
                  ),
                if (aviso != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '⚠️ Total conferido em ${_fmtDataCurta(aviso.ultimaContagemEm)} '
                      '· este endereço foi atualizado pela última vez em '
                      '${_fmtDataCurta(aviso.atualizadoEm)}',
                      style: const TextStyle(
                        color: Color(0xFFe0a030),
                        fontSize: 10,
                      ),
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
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                suffixText: ' un',
                suffixStyle: TextStyle(color: Color(0xFF6a7a88), fontSize: 11),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              onChanged: (_) => setState(() {
                _editou = true;
                l.dirty = true;
                // Edição manual invalida a confirmação de "nada mudou".
                l.confirmado = false;
              }),
            ),
          ),
          IconButton(
            onPressed: _salvando ? null : () => _toggleConfirmado(l),
            tooltip: 'Conferi, quantidade correta',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            icon: Icon(
              l.confirmado ? Icons.check_circle : Icons.check_circle_outline,
              size: 20,
              color: l.confirmado
                  ? const Color(0xFF6fcf97)
                  : const Color(0xFF6a7a88),
            ),
          ),
          IconButton(
            onPressed: _salvando ? null : () => _excluirEndereco(l),
            tooltip: 'Excluir endereço',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            icon: const Icon(
              Icons.delete_outline,
              size: 20,
              color: Color(0xFFe57373),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResumo() {
    final contado = _totalContado;
    final sistema = _qtdSistema;
    final delta = sistema == null ? null : contado - sistema;
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
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (sistema != null) ...[
              const TextSpan(text: ' · Sistema: '),
              TextSpan(
                text: _fmtQtd(sistema),
                style: const TextStyle(color: Colors.white),
              ),
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
