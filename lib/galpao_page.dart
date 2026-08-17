import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'embalagem.dart';
import 'galpao_busca.dart';
import 'galpao_config.dart';
import 'galpao_pilhas.dart';
import 'galpao_scene.dart';
import 'galpao_service.dart';
import 'modo_conferencia_service.dart';
import 'models.dart' show Produto, corConferenciaCiano;
import 'turso_service.dart';

/// Mapa 3D do galpão de racks.
///
/// Etapa 4: lançar produto (busca por qualquer parte do nome, código ou dois
/// termos soltos; últimos lançados como atalho) e esvaziar com a descida
/// animada da pilha. A ocupação ainda vive em memória — a etapa 6 troca as
/// leituras/gravações pelo banco sem mexer no fluxo daqui.
class GalpaoPage extends StatefulWidget {
  /// Ocupação e catálogo iniciais. Quando informados, a página NÃO consulta o
  /// banco — é a costura dos testes e do uso offline. Null = carrega tudo do
  /// Turso e grava lá as mudanças.
  final Map<int, List<RackGalpao>>? pilhasIniciais;
  final List<Produto>?             catalogoInicial;

  /// Abrir já isolando a rua desta posição e marcando o endereço — é por onde
  /// a busca do mapa da loja entra quando o produto está no galpão.
  final int? posicaoInicial;

  /// Abrir já com o Modo Conferência ligado — é por onde o banner do mapa da
  /// loja entra quando há pendentes com rack no galpão.
  final bool conferenciaAoAbrir;

  /// Conferência do dia já pronta. Como [pilhasIniciais], informá-la desliga
  /// as consultas ao banco (testes e uso offline).
  final ModoConferenciaResultado? conferenciaInicial;

  const GalpaoPage({
    super.key,
    this.pilhasIniciais,
    this.catalogoInicial,
    this.posicaoInicial,
    this.conferenciaAoAbrir = false,
    this.conferenciaInicial,
  });

  @override
  State<GalpaoPage> createState() => _GalpaoPageState();
}

/// Um lançamento recente — o atalho de quando chega carga: o mesmo produto é
/// lançado em vários endereços seguidos, então os últimos usados aparecem
/// antes de qualquer digitação, e a quantidade do último lançamento vem
/// preenchida.
class LancamentoRecente {
  final Produto produto;
  final double  quantidade;

  const LancamentoRecente({required this.produto, required this.quantidade});
}

class _GalpaoPageState extends State<GalpaoPage> {
  late final Map<int, List<RackGalpao>> _pilhas = {
    ...?widget.pilhasIniciais,
  };

  List<Produto>      _catalogo           = const [];
  Map<String, Color> _corPorProduto      = const {};
  bool               _carregandoCatalogo = false;

  final List<LancamentoRecente> _recentes = [];
  static const int _maxRecentes = 4;

  ToqueGalpao? _selecionado;

  // Modo Conferência: a mesma função do mapa da loja, aplicada aos racks —
  // pendente de hoje acende em ciano, o resto do galpão apaga. A lista de
  // pendentes é a MESMA (contagem_itens), então os dois prédios sempre falam
  // do mesmo dia de contagem.
  bool                      _modoConferencia       = false;
  bool                      _carregandoConferencia = false;
  ModoConferenciaResultado? _conferencia;

  DescidaPilha? _descida;
  int           _descidaSeq = 0;

  /// Ruas visíveis: null = Todas. Isolar uma rua tira as outras do desenho E
  /// da lista de alvos do toque (a cena reconstrói os alvos).
  Set<int>? _ruasVisiveis;

  final _irParaCtrl = TextEditingController();

  @override
  void dispose() {
    TursoService().dataRevision.removeListener(_aoAtualizarDados);
    _irParaCtrl.dispose();
    super.dispose();
  }

  void _filtrarRua(int? numeroRua) {
    setState(() {
      _ruasVisiveis = numeroRua == null ? null : {numeroRua};
      // Seleção de uma rua que sumiu não pode continuar aberta: o painel
      // mostraria um endereço que não está mais na tela.
      final sel = _selecionado;
      if (sel != null && _ruasVisiveis != null) {
        final rua = GalpaoConfig.ruaDe(sel.posicao);
        if (rua == null || !_ruasVisiveis!.contains(rua.numero)) {
          _selecionado = null;
        }
      }
    });
  }

  /// "Ir para o número": isola a rua da posição e marca o endereço — o rack
  /// do topo se houver pilha, senão a vaga do chão.
  void _irParaPosicao(String texto) {
    final numero = int.tryParse(texto.trim());
    final posicao = numero == null ? null : GalpaoConfig.porNumero(numero);
    if (posicao == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Posição $texto não existe — são 1 a '
            '${GalpaoConfig.totalPosicoes}.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final pilha = _pilhas[posicao.numero] ?? const <RackGalpao>[];
    setState(() {
      _ruasVisiveis = {posicao.rua.numero};
      _selecionado = ToqueGalpao(
        posicao: posicao.numero,
        ordem:   pilha.isEmpty ? 1 : pilha.length,
        ocupado: pilha.isNotEmpty,
      );
      _irParaCtrl.clear();
    });
    FocusScope.of(context).unfocus();
  }

  /// True quando a página fala com o banco. Com pilhas semeadas por
  /// parâmetro (testes, uso offline) tudo fica em memória.
  bool get _persistindo => widget.pilhasIniciais == null;

  /// True quando a conferência do dia vem do banco. Com resultado semeado por
  /// parâmetro, o que veio é o que vale — nem o botão de atualizar consulta.
  bool get _consultandoConferencia => widget.conferenciaInicial == null;

  bool _carregandoPilhas = false;

  @override
  void initState() {
    super.initState();
    final semente = widget.catalogoInicial;
    if (semente != null) {
      _aplicarCatalogo(semente);
    } else {
      _carregarCatalogo();
    }
    _conferencia = widget.conferenciaInicial;
    if (widget.conferenciaAoAbrir) {
      _modoConferencia = true;
      if (_consultandoConferencia) unawaited(_carregarConferencia());
    }
    if (_persistindo) {
      _carregarPilhas();
    } else {
      _marcarPosicaoInicial();
    }
    // Uma sincronização traz racks lançados em outro aparelho — o mesmo
    // gancho que as outras telas usam para se atualizar sem reabrir.
    TursoService().dataRevision.addListener(_aoAtualizarDados);
  }

  void _aoAtualizarDados() {
    if (!mounted || !_persistindo) return;
    _carregarPilhas();
    unawaited(_carregarCatalogo());
    // Uma sincronização também traz as confirmações feitas no app de contagem:
    // rack conferido no meio do caminho tem de apagar sem o usuário pedir.
    if (_modoConferencia && _consultandoConferencia) {
      unawaited(_carregarConferencia());
    }
  }

  Future<void> _carregarPilhas() async {
    setState(() => _carregandoPilhas = true);
    await GalpaoService().garantirSeed();
    final pilhas = await GalpaoService().carregarPilhas();
    if (!mounted) return;
    setState(() {
      _pilhas
        ..clear()
        ..addAll(pilhas);
      _carregandoPilhas = false;
    });
    _marcarPosicaoInicial();
  }

  /// Aplica [GalpaoPage.posicaoInicial], quando informada: isola a rua e marca
  /// o endereço, do mesmo jeito que o campo "ir para o nº". Roda DEPOIS das
  /// pilhas chegarem — antes disso não daria para saber se a posição está
  /// ocupada nem em que nível está o rack do topo.
  void _marcarPosicaoInicial() {
    final numero = widget.posicaoInicial;
    if (numero == null || !mounted) return;
    final posicao = GalpaoConfig.porNumero(numero);
    if (posicao == null) return;
    final pilha = _pilhas[numero] ?? const <RackGalpao>[];
    setState(() {
      _ruasVisiveis = {posicao.rua.numero};
      _selecionado = ToqueGalpao(
        posicao: numero,
        ordem:   pilha.isEmpty ? 1 : pilha.length,
        ocupado: pilha.isNotEmpty,
      );
    });
  }

  Future<void> _carregarCatalogo() async {
    setState(() => _carregandoCatalogo = true);
    final produtos = await TursoService().fetchProdutos();
    if (!mounted) return;
    setState(() {
      _aplicarCatalogo(produtos);
      _carregandoCatalogo = false;
    });
  }

  void _aplicarCatalogo(List<Produto> produtos) {
    _catalogo      = produtos;
    _corPorProduto = {for (final p in produtos) p.codigo: p.cor};
  }

  void _onTapEndereco(ToqueGalpao? toque) {
    setState(() => _selecionado = toque);
  }

  // ── Modo Conferência ───────────────────────────────────────────────────────

  Future<void> _toggleConferencia() async {
    if (_modoConferencia) {
      setState(() {
        _modoConferencia = false;
        // O resultado é jogado fora junto: ligar de novo tem de ler o dia
        // atual, não o de quando a tela abriu.
        if (_consultandoConferencia) _conferencia = null;
      });
      return;
    }
    setState(() => _modoConferencia = true);
    if (_consultandoConferencia) await _carregarConferencia();
  }

  Future<void> _carregarConferencia() async {
    setState(() => _carregandoConferencia = true);
    final resultado = await ModoConferenciaService().buscarConferenciaDoDia();
    if (!mounted) return;
    setState(() {
      _conferencia           = resultado;
      _carregandoConferencia = false;
    });
  }

  /// Posição → nº de pendentes ali, pronto para o badge da cena. Vazio com o
  /// modo desligado: é o que faz a cena voltar às cores de produto.
  Map<int, int> get _contagemConferencia {
    final resultado = _conferencia;
    if (!_modoConferencia || resultado == null) return const {};
    return {
      for (final posicao in resultado.galpao.values)
        posicao.posicao: posicao.itens.length,
    };
  }

  /// Códigos que acendem em ciano (ver GalpaoPainter.codigosConferencia).
  Set<String> get _codigosConferencia {
    final resultado = _conferencia;
    if (!_modoConferencia || resultado == null) return const {};
    return resultado.codigosGalpao;
  }

  /// Ruas que têm posição pendente hoje. Vira um ponto ciano no chip da rua:
  /// com o filtro isolando uma rua, os cubos acesos das outras desaparecem, e
  /// sem essa marca não haveria como saber para qual rua ir.
  Set<int> get _ruasComPendencia {
    final contagem = _contagemConferencia;
    if (contagem.isEmpty) return const {};
    final ruas = <int>{};
    for (final numero in contagem.keys) {
      final rua = GalpaoConfig.ruaDe(numero);
      if (rua != null) ruas.add(rua.numero);
    }
    return ruas;
  }

  /// Lança na tela primeiro e no banco em seguida (UI otimista): o galpão é
  /// usado em pé, com carga chegando, e esperar a ida ao banco a cada rack
  /// travaria o ritmo. Se a gravação falhar, o estado local volta atrás e o
  /// aviso é explícito — nunca fica um rack "lançado" só na tela.
  Future<void> _onLancar(
      int posicao, Produto produto, double quantidade) async {
    final antes = _pilhas[posicao] ?? const <RackGalpao>[];
    final nova = pilhaAposLancar(
      antes,
      posicao:       posicao,
      produtoCodigo: produto.codigo,
      produtoNome:   produto.nome,
      quantidade:    quantidade,
    );
    if (nova == null) return; // pilha cheia — a UI não oferece, guarda dupla
    setState(() {
      _pilhas[posicao] = nova;
      _recentes.removeWhere((r) => r.produto.codigo == produto.codigo);
      _recentes.insert(
          0, LancamentoRecente(produto: produto, quantidade: quantidade));
      if (_recentes.length > _maxRecentes) _recentes.removeLast();
      // Fecha o painel: no fluxo de carga o próximo gesto é tocar a próxima
      // vaga, e o produto recém-lançado está nos recentes.
      _selecionado = null;
    });
    if (!_persistindo) return;

    final gravada = await GalpaoService().lancar(
      posicao:       posicao,
      produtoCodigo: produto.codigo,
      produtoNome:   produto.nome,
      quantidade:    quantidade,
    );
    if (!mounted) return;
    if (gravada == null) {
      setState(() => _pilhas[posicao] = antes);
      _avisar('Não deu para gravar o lançamento — confira a conexão com o '
          'banco em ⚙️.');
    } else {
      // A pilha do banco manda: se outra pessoa lançou nesta posição no meio
      // do caminho, o rack novo entrou num nível acima do previsto.
      setState(() => _pilhas[posicao] = gravada);
    }
  }

  Future<void> _onEsvaziar(int posicao, int ordem) async {
    final antes = _pilhas[posicao] ?? const <RackGalpao>[];
    setState(() {
      _pilhas[posicao] = pilhaAposEsvaziar(antes, ordem);
      _descida = DescidaPilha(
        posicao:        posicao,
        aPartirDaOrdem: ordem,
        id:             ++_descidaSeq,
      );
      _selecionado = null;
    });
    if (!_persistindo) return;

    final gravada = await GalpaoService().esvaziar(
      posicao: posicao,
      ordem:   ordem,
    );
    if (!mounted) return;
    if (gravada == null) {
      setState(() => _pilhas[posicao] = antes);
      _avisar('Não deu para esvaziar no banco — confira a conexão em ⚙️.');
    } else {
      setState(() => _pilhas[posicao] = gravada);
    }
  }

  /// Racks ocupados no galpão inteiro.
  int get _racksOcupados =>
      _pilhas.values.fold(0, (soma, pilha) => soma + pilha.length);

  /// Vagas livres: o total de endereços menos o que está ocupado. É o número
  /// que interessa a quem vai descarregar carga.
  int get _vagasLivres => GalpaoConfig.totalEnderecos - _racksOcupados;

  void _avisar(String mensagem) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(mensagem),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selecionado;

    return Scaffold(
      backgroundColor: const Color(0xFF0b0c0e),
      body: Stack(
        children: [
          GalpaoScene(
            pilhas:        _pilhas,
            corPorProduto: _corPorProduto,
            selecionado:   sel == null
                ? null
                : (posicao: sel.posicao, ordem: sel.ordem),
            onTapEndereco:       _onTapEndereco,
            descida:             _descida,
            ruasVisiveis:        _ruasVisiveis,
            modoConferencia:     _modoConferencia,
            codigosConferencia:  _codigosConferencia,
            contagemConferencia: _contagemConferencia,
          ),

          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BotaoRedondo(
                      icone: Icons.arrow_back,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'CAMDA · Galpão',
                            style: TextStyle(
                              color:      Colors.white,
                              fontSize:   15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _carregandoPilhas
                                ? 'Carregando ocupação…'
                                : '${GalpaoConfig.totalPosicoes} posições · '
                                  '${_racksOcupados} racks · '
                                  '${_vagasLivres} vagas livres',
                            style: TextStyle(
                              color:    Colors.white.withValues(alpha: 0.45),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _ToggleConferenciaGalpao(
                      ativo: _modoConferencia,
                      onTap: _toggleConferencia,
                    ),
                    const SizedBox(width: 10),
                    // Ir para o número: digita 52, isola a rua e marca.
                    SizedBox(
                      width: 92,
                      child: TextField(
                        controller: _irParaCtrl,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.go,
                        onSubmitted: _irParaPosicao,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'nº',
                          hintStyle: const TextStyle(
                              color: Color(0x44ffffff), fontSize: 13),
                          prefixIcon: const Icon(Icons.my_location,
                              color: Color(0xFF8a877f), size: 16),
                          prefixIconConstraints: const BoxConstraints(
                              minWidth: 30, minHeight: 30),
                          filled: true,
                          fillColor: const Color(0xEE141518),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                                color: Colors.white.withValues(alpha: 0.10)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                                color: Colors.white.withValues(alpha: 0.10)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: corCamda, width: 1.4),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Filtro por rua (+ banner da conferência, quando ligada) ─────
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 68),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _BarraDeRuas(
                      visiveis: _ruasVisiveis,
                      onSelecionar: _filtrarRua,
                      comPendencia: _ruasComPendencia,
                    ),
                    if (_modoConferencia)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: _BannerConferenciaGalpao(
                          carregando: _carregandoConferencia,
                          resultado:  _conferencia,
                          onRefresh: _carregandoConferencia ||
                                  !_consultandoConferencia
                              ? null
                              : _carregarConferencia,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // ── Painel inferior ─────────────────────────────────────────────
          if (sel != null)
            Positioned(
              left: 16, right: 16, bottom: 16,
              child: SafeArea(
                top: false,
                child: PainelEnderecoGalpao(
                  // A key troca o estado interno (busca, quantidade) ao mudar
                  // de endereço — resto de digitação de um endereço não pode
                  // vazar para o outro.
                  key: ValueKey('${sel.posicao}-${sel.ordem}-${sel.ocupado}'),
                  toque:               sel,
                  pilhas:              _pilhas,
                  catalogo:            _catalogo,
                  recentes:            _recentes,
                  carregandoCatalogo:  _carregandoCatalogo,
                  codigosConferencia:  _codigosConferencia,
                  onFechar: () => setState(() => _selecionado = null),
                  onLancar: (produto, quantidade) =>
                      _onLancar(sel.posicao, produto, quantidade),
                  onEsvaziar: () => _onEsvaziar(sel.posicao, sel.ordem),
                  onIrParaVaga: () {
                    final pilha = _pilhas[sel.posicao] ?? const [];
                    if (pilha.length >= GalpaoConfig.niveisMax) return;
                    setState(() => _selecionado = ToqueGalpao(
                          posicao: sel.posicao,
                          ordem:   pilha.length + 1,
                          ocupado: false,
                        ));
                  },
                ),
              ),
            )
          else
            Positioned(
              left: 16, right: 16, bottom: 20,
              // IgnorePointer: o parágrafo aceita hit na caixa inteira, e sem
              // isso a dica roubava o toque das posições desenhadas perto do
              // rodapé (a fileira mais próxima da câmera).
              child: IgnorePointer(
                child: SafeArea(
                  top: false,
                  child: Text(
                    _modoConferencia
                        ? 'Racks em ciano guardam produto para conferir hoje — '
                          'toque num deles para ver o que contar.'
                        : 'Toque num rack ou numa vaga para ver o endereço. '
                          'Um dedo arrasta · dois dedos giram e dão zoom.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color:    Colors.white.withValues(alpha: 0.35),
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Barra de filtro por rua ──────────────────────────────────────────────────

/// `Todas` + `R1`…`R7`. Isolar uma rua faz as outras sumirem da cena — e,
/// junto com elas, da lista de alvos do toque.
class _BarraDeRuas extends StatelessWidget {
  final Set<int>?          visiveis;
  final ValueChanged<int?> onSelecionar;

  /// Ruas com pendente de conferência hoje — ganham um ponto ciano no chip.
  final Set<int>           comPendencia;

  const _BarraDeRuas({
    required this.visiveis,
    required this.onSelecionar,
    this.comPendencia = const {},
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _chip('Todas', visiveis == null, () => onSelecionar(null)),
          for (final rua in GalpaoConfig.ruas)
            _chip(
              'R${rua.numero}',
              visiveis != null && visiveis!.contains(rua.numero),
              () => onSelecionar(rua.numero),
              pendente: comPendencia.contains(rua.numero),
            ),
        ],
      ),
    );
  }

  Widget _chip(String texto, bool ativo, VoidCallback onTap,
          {bool pendente = false}) =>
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: ativo
                  ? corCamda.withValues(alpha: 0.18)
                  : const Color(0xEE141518),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: ativo
                    ? corCamda
                    : Colors.white.withValues(alpha: 0.10),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  texto,
                  style: TextStyle(
                    color:      ativo ? corCamda : const Color(0xFF8a877f),
                    fontSize:   12,
                    fontWeight: ativo ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
                if (pendente) ...[
                  const SizedBox(width: 5),
                  Container(
                    width: 6, height: 6,
                    decoration: const BoxDecoration(
                      color: corConferenciaCiano,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}

// ── Painel do endereço ───────────────────────────────────────────────────────

/// Painel inferior do endereço selecionado.
///
/// Ocupado: produto, quantidade, botão Esvaziar (com a descida animada da
/// pilha) e o atalho para a vaga do topo — o toque direto no wireframe da
/// vaga de uma pilha parcial quase sempre acerta o rack embaixo dele (regra
/// de prioridade do hit-test), então o caminho garantido para lançar em cima
/// é por aqui.
///
/// Vazio: busca de produto (qualquer parte do nome, código, dois termos
/// soltos), últimos lançados como atalho, quantidade e Lançar.
class PainelEnderecoGalpao extends StatefulWidget {
  final ToqueGalpao                toque;
  final Map<int, List<RackGalpao>> pilhas;
  final List<Produto>              catalogo;
  final List<LancamentoRecente>    recentes;
  final bool                       carregandoCatalogo;
  final VoidCallback               onFechar;
  final void Function(Produto produto, double quantidade)? onLancar;
  final VoidCallback?              onEsvaziar;
  final VoidCallback?              onIrParaVaga;

  /// Códigos pendentes de conferência hoje: o rack cujo produto está aqui
  /// ganha a tarja ciana — quem tocou o cubo aceso precisa ver, no painel, que
  /// foi por isso que ele acendeu.
  final Set<String>                codigosConferencia;

  const PainelEnderecoGalpao({
    super.key,
    required this.toque,
    required this.pilhas,
    required this.onFechar,
    this.catalogo           = const [],
    this.recentes           = const [],
    this.carregandoCatalogo = false,
    this.onLancar,
    this.onEsvaziar,
    this.onIrParaVaga,
    this.codigosConferencia = const {},
  });

  @override
  State<PainelEnderecoGalpao> createState() => _PainelEnderecoGalpaoState();
}

class _PainelEnderecoGalpaoState extends State<PainelEnderecoGalpao> {
  final _buscaCtrl = TextEditingController();
  final _qtdCtrl   = TextEditingController();

  List<Produto> _resultados  = const [];
  Produto?      _produtoSel;

  @override
  void dispose() {
    _buscaCtrl.dispose();
    _qtdCtrl.dispose();
    super.dispose();
  }

  void _aoDigitarBusca(String q) {
    setState(() => _resultados = buscarProdutosGalpao(q, widget.catalogo));
  }

  /// [quantidadeLitros] é o que o banco guarda; o campo mostra a quantidade
  /// na unidade de manuseio do produto (45 baldes = digita 45), então o
  /// prefill dos recentes converte de volta antes de preencher.
  void _selecionarProduto(Produto p, {double? quantidadeLitros}) {
    setState(() {
      _produtoSel = p;
      _resultados = const [];
      _buscaCtrl.clear();
      if (quantidadeLitros != null) {
        final emUnidades = unidadeDoNome(p.nome) != null
            ? quantidadeLitros / litrosPorUnidade
            : quantidadeLitros;
        _qtdCtrl.text = formatarNumero(emUnidades);
      }
    });
  }

  double? get _quantidadeDigitada {
    final q = double.tryParse(_qtdCtrl.text.replaceAll(',', '.'));
    return q != null && q > 0 ? q : null;
  }

  /// O que foi digitado convertido para litros — a conta que vai ao banco.
  /// Produto sem unidade dedutível grava o número como digitado.
  double? get _quantidadeEmLitros {
    final digitada = _quantidadeDigitada;
    final produto  = _produtoSel;
    if (digitada == null || produto == null) return null;
    return unidadeDoNome(produto.nome) != null
        ? litrosDeUnidades(digitada)
        : digitada;
  }

  void _lancar() {
    final produto = _produtoSel;
    final litros  = _quantidadeEmLitros;
    if (produto == null || litros == null) return;
    widget.onLancar?.call(produto, litros);
  }

  Future<void> _confirmarEsvaziar() async {
    final t     = widget.toque;
    final pilha = widget.pilhas[t.posicao] ?? const <RackGalpao>[];
    final temAcima = t.ordem < pilha.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        title: Text('Esvaziar ${t.posicao} · N${t.ordem}?',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: temAcima
            ? const Text(
                'Os racks de cima descem um nível e a ordem é renumerada.',
                style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 13))
            : null,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Esvaziar',
                style: TextStyle(color: Color(0xFFef5350))),
          ),
        ],
      ),
    );
    if (ok == true) widget.onEsvaziar?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t     = widget.toque;
    final rua   = GalpaoConfig.ruaDe(t.posicao);
    final pilha = widget.pilhas[t.posicao] ?? const <RackGalpao>[];
    final rack  = t.ocupado && t.ordem <= pilha.length
        ? pilha[t.ordem - 1]
        : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color:        const Color(0xF0141a22),
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: const Color(0xFF232f3a)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Endereço: número global + nível derivado da ordem na pilha.
              Text(
                '${t.posicao} · N${t.ordem}',
                style: const TextStyle(
                  color:      corCamda,
                  fontSize:   22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    rua == null
                        ? ''
                        : 'Rua ${rua.numero} · ${pilha.length} de '
                          '${GalpaoConfig.niveisMax} na pilha',
                    style: const TextStyle(
                        color: Color(0xFF8a9aa8), fontSize: 12),
                  ),
                ),
              ),
              GestureDetector(
                onTap: widget.onFechar,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 18, color: Color(0xFF8a9aa8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (rack != null)
            _buildOcupado(rack, pilha)
          else
            _buildVazio(t),
        ],
      ),
    );
  }

  // ── Endereço ocupado ───────────────────────────────────────────────────────

  Widget _buildOcupado(RackGalpao rack, List<RackGalpao> pilha) {
    final embalada = quantidadeEmbalada(rack.produtoNome, rack.quantidade);
    final litros   = '${formatarNumero(rack.quantidade)} L';
    final temVaga  = pilha.length < GalpaoConfig.niveisMax;
    final pendente = widget.codigosConferencia.contains(rack.produtoCodigo);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pendente) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: corConferenciaCiano.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: corConferenciaCiano.withValues(alpha: 0.55)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.fact_check_outlined,
                    size: 13, color: corConferenciaCiano),
                SizedBox(width: 6),
                Text(
                  'Conferir hoje',
                  style: TextStyle(
                      color: corConferenciaCiano,
                      fontSize: 11,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          rack.produtoNome.isEmpty ? rack.produtoCodigo : rack.produtoNome,
          style: const TextStyle(
            color:      Colors.white,
            fontSize:   13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              embalada ?? formatarNumero(rack.quantidade),
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   18,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (embalada != null) ...[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  litros,
                  style: const TextStyle(
                      color: Color(0xFF8a9aa8), fontSize: 12),
                ),
              ),
            ],
            const Spacer(),
            Text(
              'cód. ${rack.produtoCodigo}',
              style:
                  const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    widget.onEsvaziar == null ? null : _confirmarEsvaziar,
                icon: const Icon(Icons.remove_circle_outline, size: 16),
                label: const Text('Esvaziar'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFef5350),
                  side: const BorderSide(color: Color(0x66ef5350)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            if (temVaga && widget.onIrParaVaga != null) ...[
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.onIrParaVaga,
                  icon: const Icon(Icons.add, size: 16),
                  label: Text('Lançar N${pilha.length + 1}'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF6fcf97),
                    side: const BorderSide(color: Color(0x662e6b46)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  // ── Endereço vazio: lançar ─────────────────────────────────────────────────

  Widget _buildVazio(ToqueGalpao t) {
    final produto = _produtoSel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.check_box_outline_blank,
                size: 16, color: Color(0xFF6fcf97)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Vaga livre — carga nova entra como N${t.ordem}, no topo '
                'da pilha.',
                style:
                    const TextStyle(color: Color(0xFF6fcf97), fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (produto == null) ...[
          TextField(
            controller: _buscaCtrl,
            onChanged:  _aoDigitarBusca,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: _decoracaoCampo(
                'Buscar produto por nome ou código…', Icons.search),
          ),
          if (_resultados.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                children: [
                  for (final p in _resultados)
                    InkWell(
                      onTap: () => _selecionarProduto(p),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 8),
                        child: Row(
                          children: [
                            Container(
                              width: 10, height: 10,
                              decoration: BoxDecoration(
                                color: p.cor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                p.nome,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12),
                              ),
                            ),
                            Text(
                              p.codigo,
                              style: const TextStyle(
                                  color: Color(0xFF8a9aa8), fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            )
          else if (_buscaCtrl.text.trim().length >= 2)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                widget.carregandoCatalogo
                    ? 'Carregando catálogo…'
                    : widget.catalogo.isEmpty
                        ? 'Catálogo não carregado — sincronize no mapa da '
                          'loja (⚙️).'
                        : 'Nenhum produto encontrado.',
                style:
                    const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
              ),
            )
          else if (widget.recentes.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 6),
              child: Text(
                'ÚLTIMOS LANÇADOS',
                style: TextStyle(
                  color:         Color(0xFF8a9aa8),
                  fontSize:      10,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: [
                for (final r in widget.recentes)
                  InkWell(
                    onTap: () => _selecionarProduto(r.produto,
                        quantidadeLitros: r.quantidade),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161c22),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF232f3a)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8, height: 8,
                            decoration: BoxDecoration(
                              color: r.produto.cor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: Text(
                              r.produto.nome,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ] else ...[
          // Produto escolhido: chip + quantidade + Lançar.
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF162416),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF2e6b46)),
            ),
            child: Row(
              children: [
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    color: produto.cor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    produto.nome,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color:      Color(0xFF6fcf97),
                      fontSize:   12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() {
                    _produtoSel = null;
                    _qtdCtrl.clear();
                  }),
                  child: const Icon(Icons.close,
                      size: 14, color: Color(0xFF8a9aa8)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _qtdCtrl,
                  onChanged: (_) => setState(() {}),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                  ],
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  // Digita-se o que se CONTA no galpão: baldes ou caixas.
                  // Litros são derivados ao lado, nunca digitados — quem vê
                  // 45 baldes lança 45.
                  decoration: _decoracaoCampo(
                      _rotuloUnidade(produto.nome), null),
                ),
              ),
              const SizedBox(width: 10),
              // Conversão ao vivo para litros (o que o banco guarda).
              Expanded(
                child: Text(
                  _quantidadeEmLitros == null ||
                          unidadeDoNome(produto.nome) == null
                      ? ''
                      : '= ${formatarNumero(_quantidadeEmLitros!)} L',
                  style: const TextStyle(
                      color: Color(0xFF8a9aa8), fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _quantidadeEmLitros == null ? null : _lancar,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2e6b46),
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
              child: Text('Lançar em ${t.posicao} · N${t.ordem}'),
            ),
          ),
        ],
      ],
    );
  }

  /// Rótulo do campo de quantidade: a unidade em que se conta.
  static String _rotuloUnidade(String nomeProduto) {
    switch (unidadeDoNome(nomeProduto)) {
      case 'balde': return 'Baldes';
      case 'caixa': return 'Caixas';
      default:      return 'Quantidade';
    }
  }

  InputDecoration _decoracaoCampo(String hint, IconData? icone) =>
      InputDecoration(
        hintText:  hint,
        hintStyle: const TextStyle(color: Color(0x44ffffff), fontSize: 13),
        prefixIcon: icone == null
            ? null
            : Icon(icone, color: const Color(0xFF8a9aa8), size: 18),
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
      );
}

// ── Modo Conferência: botão e banner ─────────────────────────────────────────

/// Gêmeo do toggle do mapa da loja (main.dart), de propósito: é a MESMA função
/// nos dois prédios, então tem o mesmo ícone, a mesma cor e o mesmo lugar na
/// barra de cima. Quem aprendeu a acender a rota na loja não reaprende aqui.
class _ToggleConferenciaGalpao extends StatelessWidget {
  final bool         ativo;
  final VoidCallback onTap;

  const _ToggleConferenciaGalpao({required this.ativo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        width:  46,
        decoration: BoxDecoration(
          color: ativo
              ? corConferenciaCiano.withValues(alpha: 0.18)
              : const Color(0xEE141518),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: ativo
                ? corConferenciaCiano
                : Colors.white.withValues(alpha: 0.10),
          ),
        ),
        child: Icon(
          ativo ? Icons.fact_check : Icons.fact_check_outlined,
          color: ativo ? corConferenciaCiano : const Color(0xFF8a877f),
          size: 20,
        ),
      ),
    );
  }
}

/// Banner da conferência do dia no galpão: quantos produtos e quantas posições
/// acenderam.
///
/// Conta os PRODUTOS distintos com rack aqui, não os pendentes do dia inteiro:
/// o total do dia é do banner da loja, e repeti-lo aqui só faria o usuário
/// procurar no galpão o que está numa gôndola.
class _BannerConferenciaGalpao extends StatelessWidget {
  final bool                      carregando;
  final ModoConferenciaResultado? resultado;
  final VoidCallback?             onRefresh;

  const _BannerConferenciaGalpao({
    required this.carregando,
    required this.resultado,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final r     = resultado;
    final vazio = !carregando && (r == null || r.galpaoVazioHoje);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color:        const Color(0xE60d2226),
        border:       Border.all(
            color: corConferenciaCiano.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(
          vazio ? Icons.celebration_outlined : Icons.fact_check_outlined,
          color: corConferenciaCiano,
          size:  15,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            carregando
                ? 'Carregando conferência do dia…'
                : vazio
                    ? 'Nenhum pendente com rack no galpão hoje 🎉'
                    : 'Conferência do dia: ${r!.totalProdutosGalpao} '
                      'produto(s) em ${r.totalPosicoesGalpao} posição(ões)',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        if (onRefresh != null) ...[
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.refresh, size: 16, color: Color(0xFF8a9aa8)),
            onPressed: onRefresh,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Atualizar',
          ),
        ],
      ]),
    );
  }
}

class _BotaoRedondo extends StatelessWidget {
  final IconData     icone;
  final VoidCallback onTap;

  const _BotaoRedondo({required this.icone, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        width:  46,
        decoration: BoxDecoration(
          color:        const Color(0xEE141518),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Icon(icone, color: const Color(0xFF8a877f), size: 20),
      ),
    );
  }
}
