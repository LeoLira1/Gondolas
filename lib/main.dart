import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'configuracao_page.dart';
import 'estante_edr300_scene.dart';
import 'estante_parede_scene.dart';
import 'estante_scene.dart';
import 'estoque_localizado_service.dart';
import 'expositor_magnojet_scene.dart';
import 'expositor_monitor_scene.dart';
import 'expositor_nellore_scene.dart';
import 'galpao_page.dart';
import 'galpao_scene.dart' show corCamda;
import 'gondola_scene.dart';
import 'loja_scene.dart';
import 'modo_conferencia_service.dart';
import 'models.dart';
import 'palete_registry.dart';
import 'palete_scene.dart';
import 'quantidade_dialog.dart';
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

  // Modo Conferência (Fase 3): transforma a lista de pendentes do dia numa
  // rota visual no mapa. _conferencia é null até a primeira carga.
  bool                        _modoConferencia     = false;
  bool                        _carregandoConferencia = false;
  ModoConferenciaResultado?   _conferencia;

  bool _sincronizando = false;

  @override
  void initState() {
    super.initState();
    // Bonecos caminhando pelo mapa (0 = desligado, 1 ou 2): quem escolhe a
    // quantidade é a tela de Configuração; aqui só carregamos o valor salvo e
    // deixamos o notifier de PreferenciasMapa reconstruir a cena.
    PreferenciasMapa.lerBonecos();
    _searchFocus.addListener(() {
      if (!_searchFocus.hasFocus) {
        setState(() {
          _showSugestoes = false;
          _semResultados = false;
        });
      }
    });

    // Prewarm: assim que a conexão sobe, carrega layouts e catálogo enquanto o
    // usuário ainda está se situando no mapa. LojaPage é a home e não emite
    // consulta própria, então essa janela é livre — e é ela que faz a PRIMEIRA
    // abertura de uma gôndola/prateleira custar o mesmo que as seguintes.
    unawaited(TursoService().init().then((_) => TursoService().prewarm()));

    if (widget.itemTipoInicial != null && widget.itemNumeroInicial != null) {
      final numeroMapa =
          numeroNoMapaLoja(widget.itemTipoInicial!, widget.itemNumeroInicial!);
      final idx = itensLoja.indexWhere((it) =>
          it.tipo == widget.itemTipoInicial && it.numero == numeroMapa);
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
    final numeroMapa = numeroNoMapaLoja(p.tipo, p.numero);
    final idx = itensLoja.indexWhere(
        (it) => it.tipo == p.tipo && it.numero == numeroMapa);
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

  /// Abre a cena da estrutura selecionada. [idx] é o índice em [itensLoja]
  /// quando o toque veio do mapa; quando é null, a estrutura do produto
  /// encontrado na busca NÃO tem maquete no mapa (paletes e estante 5, que só
  /// existem no carrossel de detalhes) e o endereço do próprio produto é o que
  /// diz onde abrir — sem isso o "Ver detalhes" ficava inalcançável para esses
  /// endereços, mesmo a busca achando o produto.
  Future<void> _verDetalhes([int? idx]) async {
    final item   = idx != null ? itensLoja[idx] : null;
    final tipo   = item?.tipo   ?? _produtoSelecionado?.tipo;
    final numero = item?.numero ?? _produtoSelecionado?.numero;
    if (tipo == null || numero == null) return;
    await _abrirEstrutura(tipo, numero);
  }

  Future<void> _abrirEstrutura(String tipo, int numero) async {
    if (_modoConferencia) {
      // O retângulo da parede representa as 6 seções (13–18): acende os
      // pendentes de todas ao abrir a cena pela seção 1.
      final codigos = <String>{};
      if (tipo == 'estante' && ehEstanteParede(numero)) {
        for (var n = estanteParedeMin; n <= estanteParedeMax; n++) {
          codigos.addAll(
              _conferencia?.estruturas['estante:$n']?.codigos ?? const {});
        }
      } else {
        codigos.addAll(
            _conferencia?.estruturas['$tipo:$numero']?.codigos ?? const {});
      }
      await Navigator.push(context, MaterialPageRoute(
        builder: (_) => tipo == 'gondola'
            ? GondolaPage(gondolaInicial: numero, codigosConferencia: codigos)
            : EstantePage(estanteInicial: numero, codigosConferencia: codigos),
      ));
      // O usuário pode ter confirmado itens no app de contagem enquanto
      // estava na cena — recarrega pra refletir o estado atual ao voltar.
      if (mounted && _modoConferencia) _carregarConferencia();
      return;
    }

    final produto = _produtoSelecionado != null
        ? ProdutoLoja(
            nome:          _produtoSelecionado!.nome,
            tipo:          _produtoSelecionado!.tipo,
            numero:        _produtoSelecionado!.numero,
            nivel:         _produtoSelecionado!.nivelDescricao,
            produtoCodigo: _produtoSelecionado!.produtoCodigo,
            face:          _produtoSelecionado!.face,
            andar:         _produtoSelecionado!.andar,
          )
        : null;
    if (tipo == localTipoGalpao) {
      // O galpão não tem maquete no mapa da loja (é outro prédio): a busca
      // leva direto à tela dele, isolando a rua e marcando a posição.
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => GalpaoPage(posicaoInicial: numero),
      ));
    } else if (tipo == 'gondola') {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => GondolaPage(
          gondolaInicial:   numero,
          produtoDestacado: produto,
        ),
      ));
    } else {
      // Se a busca apontou uma seção específica da parede (13–18), abre nela;
      // sem produto, o retângulo da parede abre pela seção 1 (E13).
      final estanteInicial = produto != null && produto.tipo == 'estante'
          ? produto.numero
          : numero;
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => EstantePage(
          estanteInicial:   estanteInicial,
          produtoDestacado: produto,
        ),
      ));
    }
  }

  // ── Modo Conferência (Fase 3) ──────────────────────────────────────────────

  Future<void> _toggleModoConferencia() async {
    if (_modoConferencia) {
      setState(() {
        _modoConferencia    = false;
        _conferencia        = null;
        _selecionadoIdx     = null;
        _produtoSelecionado = null;
      });
      return;
    }
    setState(() {
      _modoConferencia    = true;
      _selecionadoIdx     = null;
      _produtoSelecionado = null;
    });
    await _carregarConferencia();
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

  /// Estruturas com pendentes que não têm maquete no mapa (paletes, estante 5).
  /// O badge delas não tem retângulo onde pousar, então sumiriam do Modo
  /// Conferência sem sequer cair na lista "sem endereço" — elas TÊM endereço
  /// cadastrado. Viram um atalho próprio no banner.
  List<EstruturaConferencia> get _estruturasForaDoMapa {
    final conferencia = _conferencia;
    if (conferencia == null) return const [];
    final fora = conferencia.estruturas.values.where((e) {
      final numeroMapa = numeroNoMapaLoja(e.tipo, e.numero);
      return !itensLoja
          .any((it) => it.tipo == e.tipo && it.numero == numeroMapa);
    }).toList();
    fora.sort((a, b) => a.numero.compareTo(b.numero));
    return fora;
  }

  // idx (em itensLoja) → nº de pendentes na estrutura, pronto pro painter.
  Map<int, int> get _contagemPorIdx {
    final conferencia = _conferencia;
    if (conferencia == null) return {};
    final mapa = <int, int>{};
    for (final estrutura in conferencia.estruturas.values) {
      // As seções da parede (13–18) compartilham o mesmo retângulo no mapa:
      // soma os pendentes de todas no badge da estrutura única.
      final numeroMapa = numeroNoMapaLoja(estrutura.tipo, estrutura.numero);
      final idx = itensLoja.indexWhere(
          (it) => it.tipo == estrutura.tipo && it.numero == numeroMapa);
      if (idx != -1) mapa[idx] = (mapa[idx] ?? 0) + estrutura.itens.length;
    }
    return mapa;
  }

  void _mostrarSemEndereco() {
    final itens = _conferencia?.semEndereco ?? const [];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141a22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sem endereço no mapa',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '${itens.length} produto(s) pendente(s) não têm endereço cadastrado — '
                'confira "no braço" e cadastre no mapa quando possível.',
                style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 12),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: itens.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: Color(0xFF232f3a), height: 16),
                  itemBuilder: (_, i) {
                    final item = itens[i];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.produto,
                            style: const TextStyle(color: Colors.white, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(
                          '${item.codigo} · ${item.categoria}',
                          style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
                        ),
                      ],
                    );
                  },
                ),
              ),
              // Itens de depósito (Fase 3.1) ficam fora da lista por completo
              // — só um rodapé discreto avisando quantos foram ocultados.
              if ((_conferencia?.totalFiltradosDeposito ?? 0) > 0) ...[
                const SizedBox(height: 10),
                Text(
                  '${_conferencia!.totalFiltradosDeposito} itens de depósito ocultos '
                  'pelo filtro de categorias',
                  style: const TextStyle(color: Color(0xFF5a6a78), fontSize: 11),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sincronizar() async {
    if (_sincronizando) return;
    setState(() => _sincronizando = true);
    final ok = await TursoService().sincronizar();
    if (!mounted) return;
    setState(() => _sincronizando = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Sincronizado com o banco online ✓'
          : 'Não foi possível sincronizar — '
              '${TursoService().ultimoErroSync ?? 'verifique a conexão'}'),
      backgroundColor: ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: Duration(seconds: ok ? 2 : 6),
    ));
    if (ok && _modoConferencia) _carregarConferencia();
  }

  void _mostrarForaDoMapa() {
    final estruturas = _estruturasForaDoMapa;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141a22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Fora do mapa geral',
                style: TextStyle(
                    color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                'Estruturas com pendentes que não são desenhadas no mapa '
                '(paletes e estante 5). Toque para abrir a cena.',
                style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 12),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: estruturas.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: Color(0xFF232f3a), height: 8),
                  itemBuilder: (_, i) {
                    final e = estruturas[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        Navigator.pop(context);
                        _abrirEstrutura(e.tipo, e.numero);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: corConferenciaCiano.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                rotuloCurtoEstrutura(e.tipo, e.numero),
                                style: const TextStyle(
                                    color: corConferenciaCiano,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${nomeEstrutura(e.tipo, e.numero)} · '
                                '${e.itens.length} pendente(s)',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13),
                              ),
                            ),
                            const Icon(Icons.chevron_right,
                                color: Color(0xFF8a9aa8), size: 20),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
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
    // O card também aparece quando a busca achou o produto numa estrutura sem
    // maquete no mapa (item == null): é a única porta de entrada para os
    // detalhes de paletes e da estante 5.
    final mostrarCard = item != null || _produtoSelecionado != null;

    return Scaffold(
      backgroundColor: const Color(0xFF0b0c0e),
      body: Stack(
        children: [
          // ── Cena 3D (fundo) ─────────────────────────────────────────────
          // A quantidade de bonecos vem da tela de Configuração: o notifier
          // reconstrói só a cena quando o usuário troca a opção por lá.
          ValueListenableBuilder<int>(
            valueListenable: PreferenciasMapa.bonecos,
            builder: (_, bonecos, __) => LojaScene(
              selecionadoIdx:       _selecionadoIdx,
              onSelecionado:        _onSelecionado,
              onVerDetalhes:        _verDetalhes,
              focarEm:              _focarEm,
              modoConferencia:      _modoConferencia,
              contagemConferencia:  _contagemPorIdx,
              bonecos:              bonecos,
            ),
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
                    // O campo de busca fica SOZINHO na linha, ocupando a
                    // largura toda. Ele dividia a linha com três botões de
                    // 46 px e a legenda, e num celular sobrava tão pouco que
                    // o nome do produto não cabia — os nomes cadastrados são
                    // longos ('HERBICIDA BORAL 500 SC 20L'), então é a busca
                    // que precisa do espaço, não os botões.
                    _SearchBox(
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
                    const SizedBox(height: 8),
                    // Segunda linha: ações e legenda. Sincronizar, galpão e
                    // conferência à esquerda; a legenda encostada à direita.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SyncButton(
                          sincronizando: _sincronizando,
                          onTap: _sincronizar,
                        ),
                        const SizedBox(width: 10),
                        _GalpaoButton(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => const GalpaoPage()),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _ModoConferenciaToggle(
                          ativo: _modoConferencia,
                          onTap: _toggleModoConferencia,
                        ),
                        const Spacer(),
                        const _LegendRow(),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_modoConferencia)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _BannerConferencia(
                          carregando: _carregandoConferencia,
                          resultado:  _conferencia,
                          onRefresh:  _carregarConferencia,
                          onVerSemEndereco: _mostrarSemEndereco,
                          foraDoMapa: _estruturasForaDoMapa,
                          onVerForaDoMapa: _mostrarForaDoMapa,
                        ),
                      ),
                    // Título / dica
                    Text(
                      'CAMDA · Mapa da loja — toque numa estrutura ou busque um produto',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
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
          if (mostrarCard && !_modoConferencia)
            Positioned(
              bottom: 24,
              left: 20,
              right: 20,
              child: _LocationCard(
                item:    item,
                produto: _produtoSelecionado,
                onVerDetalhes: () => _verDetalhes(_selecionadoIdx),
              ),
            ),
        ],
      ),
    );
  }
}

// ── _DialogLimparProduto ─────────────────────────────────────────────────────
// Conteúdo do dialog "Limpar produto" (gôndola e estante): a lista de produtos
// rola quando não cabe na tela, com barra de rolagem sempre visível, e a ação
// "Limpar tudo" fica fixa embaixo, fora da área rolável.

class _DialogLimparProduto extends StatefulWidget {
  final List<Produto>        produtos;
  final Map<String, int>     qtdPorProduto;
  final ValueChanged<String> onExcluirProduto;
  final VoidCallback         onLimparTudo;

  const _DialogLimparProduto({
    required this.produtos,
    required this.qtdPorProduto,
    required this.onExcluirProduto,
    required this.onLimparTudo,
  });

  @override
  State<_DialogLimparProduto> createState() => _DialogLimparProdutoState();
}

class _DialogLimparProdutoState extends State<_DialogLimparProduto> {
  final _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // width: double.maxFinite evita o IntrinsicWidth do AlertDialog, que não
    // convive com ListView; Flexible deixa a lista encolher pro "Limpar tudo"
    // continuar visível mesmo com muitos produtos.
    return SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Scrollbar(
              controller: _scrollCtrl,
              thumbVisibility: true,
              child: ListView.builder(
                controller: _scrollCtrl,
                shrinkWrap: true,
                padding: const EdgeInsets.only(right: 10),
                itemCount: widget.produtos.length,
                itemBuilder: (_, i) {
                  final p   = widget.produtos[i];
                  final qtd = widget.qtdPorProduto[p.codigo] ?? 0;
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.onExcluirProduto(p.codigo),
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
                                  '${p.codigo} · $qtd ${qtd == 1 ? 'unidade' : 'unidades'}',
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
                },
              ),
            ),
          ),
          if (widget.produtos.length > 1) ...[
            const Divider(color: Color(0xFF2a3540), height: 20),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.onLimparTudo,
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
    );
  }
}

// ── _SyncButton ─────────────────────────────────────────────────────────────
// Sincroniza o cache local com o banco online (ver TursoService.sincronizar).

class _SyncButton extends StatelessWidget {
  final bool         sincronizando;
  final VoidCallback onTap;

  const _SyncButton({required this.sincronizando, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: sincronizando ? null : onTap,
      child: Container(
        height: 46,
        width:  46,
        decoration: BoxDecoration(
          color: const Color(0xEE141518),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: sincronizando
            ? const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF4a9d6a),
                  ),
                ),
              )
            : const Icon(Icons.sync, color: Color(0xFF8a877f), size: 20),
      ),
    );
  }
}

// ── _GalpaoButton ────────────────────────────────────────────────────────────

/// Porta de entrada do mapa do galpão. Fica na barra do mapa da loja, e não
/// como uma estrutura desenhada nele, porque o galpão é outro prédio — não
/// uma peça a mais do salão.
class _GalpaoButton extends StatelessWidget {
  final VoidCallback onTap;

  const _GalpaoButton({required this.onTap});

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
        child: const Icon(Icons.warehouse_outlined,
            color: Color(0xFF8a877f), size: 20),
      ),
    );
  }
}

// ── _ModoConferenciaToggle ──────────────────────────────────────────────────

class _ModoConferenciaToggle extends StatelessWidget {
  final bool         ativo;
  final VoidCallback onTap;

  const _ModoConferenciaToggle({required this.ativo, required this.onTap});

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

// ── _BannerConferencia ───────────────────────────────────────────────────────

class _BannerConferencia extends StatelessWidget {
  final bool                      carregando;
  final ModoConferenciaResultado? resultado;
  final VoidCallback              onRefresh;
  final VoidCallback              onVerSemEndereco;
  // Estruturas com pendentes que não são desenhadas no mapa (paletes,
  // estante 5): não têm retângulo pra piscar, então ganham um atalho próprio.
  final List<EstruturaConferencia> foraDoMapa;
  final VoidCallback               onVerForaDoMapa;

  const _BannerConferencia({
    required this.carregando,
    required this.resultado,
    required this.onRefresh,
    required this.onVerSemEndereco,
    this.foraDoMapa = const [],
    required this.onVerForaDoMapa,
  });

  @override
  Widget build(BuildContext context) {
    final r     = resultado;
    final vazio = !carregando && (r == null || r.vazioHoje);
    final temSemEndereco = r != null && r.semEndereco.isNotEmpty;
    final temFiltrados   = r != null && r.totalFiltradosDeposito > 0;
    final filtradosTexto =
        temFiltrados ? ' · ${r.totalFiltradosDeposito} depósito (filtrados)' : '';
    final temForaDoMapa  = !carregando && foraDoMapa.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xE60d2226),
        border: Border.all(color: corConferenciaCiano.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(
          vazio ? Icons.celebration_outlined : Icons.fact_check_outlined,
          color: corConferenciaCiano,
          size: 15,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: carregando
              ? const Text(
                  'Carregando conferência do dia...',
                  style: TextStyle(color: Color(0xFFb0ada8), fontSize: 12),
                )
              : GestureDetector(
                  onTap: (temSemEndereco || temFiltrados) ? onVerSemEndereco : null,
                  child: Text(
                    vazio
                        ? 'Nenhuma conferência pendente hoje 🎉$filtradosTexto'
                        : 'Conferência do dia: ${r!.totalProdutos} produto(s) · '
                          '${r.totalEstruturas} estrutura(s)'
                          '${temSemEndereco ? ' · ${r.semEndereco.length} sem endereço' : ''}'
                          '$filtradosTexto',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
        ),
        if (temForaDoMapa) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onVerForaDoMapa,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x33d9a441),
                border: Border.all(color: const Color(0x99d9a441)),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.location_off_outlined,
                    size: 12, color: Color(0xFFd9a441)),
                const SizedBox(width: 4),
                Text(
                  '${foraDoMapa.length} fora do mapa',
                  style: const TextStyle(color: Color(0xFFd9a441), fontSize: 11),
                ),
              ]),
            ),
          ),
        ],
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.refresh, size: 16, color: Color(0xFF8a9aa8)),
          onPressed: carregando ? null : onRefresh,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: 'Atualizar',
        ),
      ]),
    );
  }
}

// ── _SearchBox ────────────────────────────────────────────────────────────────

String _fmtQtdSugestao(double q) =>
    q == q.roundToDouble() ? q.round().toString() : q.toString();

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
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
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
              border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
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
                            Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
                        itemBuilder: (_, i) {
                          final p   = sugestoes[i];
                          final cor = p.tipo == 'gondola' ? corGondolaLoja : corEstanteLoja;
                          return InkWell(
                            onTap: () => onSelecionar(p),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                              child: Row(
                                children: [
                                  Expanded(
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
                                          Flexible(
                                            child: Text(
                                              '${p.tipo == 'gondola' ? 'Gôndola' : p.tipo == localTipoGalpao ? 'Galpão' : ehPalete(p.numero) ? 'Palete' : 'Estante'}'
                                              ' nº ${p.numero} · ${p.nivelDescricao}',
                                              style: const TextStyle(
                                                  color: Color(0xFF9b9893), fontSize: 11),
                                            ),
                                          ),
                                        ]),
                                      ],
                                    ),
                                  ),
                                  if (p.quantidade != null) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      '${_fmtQtdSugestao(p.quantidade!)} un',
                                      style: const TextStyle(
                                          color: Color(0xFFf0eee9),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ],
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
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
  // null quando a estrutura do produto encontrado não é desenhada no mapa
  // (paletes e estante 5): aí o endereço do próprio produto descreve o card.
  final ItemLoja?          item;
  final ProdutoEncontrado? produto;
  final VoidCallback?      onVerDetalhes;

  const _LocationCard({
    required this.item,
    this.produto,
    this.onVerDetalhes,
  }) : assert(item != null || produto != null);

  @override
  Widget build(BuildContext context) {
    final foraDoMapa = item == null;
    final tipo       = item?.tipo   ?? produto!.tipo;
    final numero     = item?.numero ?? produto!.numero;

    final ehPaleteAqui = tipo == 'estante' && ehPalete(numero);
    final ehParede     = tipo == 'estante' && ehEstanteParede(numero);
    final ehGalpaoAqui = tipo == localTipoGalpao;
    final cor = tipo == 'gondola'
        ? corGondolaLoja
        : ehGalpaoAqui
            ? corCamda
            : corEstanteLoja;
    // No galpão o número JÁ é o endereço (1–78, único no galpão inteiro), sem
    // letra na frente — é assim que a etiqueta física está no chão.
    final prefixo = tipo == 'gondola'
        ? 'G'
        : ehGalpaoAqui
            ? ''
            : ehPaleteAqui
                ? 'P'
                : 'E';
    final tipoLabel = tipo == 'gondola'
        ? 'Gôndola'
        : ehGalpaoAqui
            ? 'Galpão'
            : ehPaleteAqui
                ? 'Palete'
                : ehParede
                    ? 'Estante Parede'
                    : 'Estante';
    // O retângulo da parede cobre as 6 seções; o número exibido acompanha o
    // resultado da busca quando há produto selecionado.
    final numeroTitulo = ehParede
        ? 'E$estanteParedeMin–E$estanteParedeMax'
        : '$prefixo$numero';
    final numeroTexto =
        produto != null && produto!.tipo == tipo ? produto!.numero : numero;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xEE16171A),
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
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
                numeroTitulo,
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
                ? '${produto!.nome} · $tipoLabel nº $numeroTexto · ${produto!.nivelDescricao}'
                : ehParede
                    ? '$tipoLabel · 6 seções · P1–P12'
                    : '$tipoLabel nº $numero',
            style: const TextStyle(
              color: Color(0xFFb0ada8),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          // Sem maquete no mapa não há retângulo piscando pra guiar o olho:
          // o aviso explica por que nada acendeu e o botão abaixo continua
          // levando à cena da estrutura.
          if (foraDoMapa) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0x33d9a441),
                border: Border.all(color: const Color(0x66d9a441)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline, size: 13, color: Color(0xFFd9a441)),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Esta estrutura não é desenhada no mapa geral — '
                      'abra os detalhes para ver a posição.',
                      style: TextStyle(color: Color(0xFFd9a441), fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
  // Modo Conferência (Fase 3): códigos pendentes de hoje que moram nesta
  // gôndola, vindos do mapa — acende todas as caixas de uma vez.
  final Set<String>? codigosConferencia;

  const GondolaPage({
    super.key,
    this.gondolaInicial   = 1,
    this.produtoDestacado,
    this.codigosConferencia,
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

  // Endereçamento por face: G{n} · F{face} · A{andar}
  int? _faceSelecionada;
  int? _andarSelecionado;
  int? _faceParaCamera;

  // Caixa exata tocada na cena — uma face+andar pode ter caixas de vários
  // produtos, então o endereço sozinho não identifica qual foi selecionada.
  CaixaColocada? _caixaSelecionada;

  final Map<int, List<CaixaColocada>> _caixas = {};

  // Endereços desatualizados (Fase 2) — carregado uma vez ao abrir a página
  // e recarregado após salvar no dialog de quantidade.
  Set<String> _desatualizados = {};

  // Endereços com divergência de contagem — carregado junto com os
  // desatualizados; badge vermelho (espelhado do âmbar).
  Set<String> _divergentes = {};

  // Subconjunto de _divergentes cuja divergência é positiva (contado maior
  // que o sistema) — pintado de azul escuro em vez de vermelho.
  Set<String> _divergentesPositivas = {};

  // Códigos acesos pelo Modo Conferência (Fase 3), vindos do mapa.
  late Set<String> _destacadosCodigos;

  List<Produto> _produtos           = [];
  bool          _dbConectado        = false;
  bool          _carregandoProdutos = false;
  bool          _carregandoLayout   = false;
  bool          _salvando           = false;
  bool          _sincronizando      = false;

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

  // Só cai no catálogo de exemplo quando NÃO há banco configurado — que é o
  // caso para o qual ele existe (o banner "usando dados de exemplo"). Com banco
  // conectado, o catálogo agora chega depois da cena (ver _inicializar), e
  // deixar o mock valer nessa janela pintaria as caixas com códigos falsos.
  List<Produto> get _catalogoAtual => _produtos.isNotEmpty
      ? _produtos
      : (_dbConectado ? const <Produto>[] : _catalogoMock);

  List<CaixaColocada> get _caixasAtuais => _caixas[_gondolaAtual] ?? const [];

  // Cor e nome que vêm nas PRÓPRIAS linhas de gondola_layout: chegam junto com
  // o layout, então a cena pinta certo no primeiro frame, sem esperar o
  // catálogo. Também servem de rede de segurança ao salvar — ver _salvarLayout.
  Map<String, String> _hexDoLayout   = const {};
  Map<String, String> _nomesDoLayout = const {};

  // Derivados do catálogo, recalculados só quando o catálogo ou o layout mudam.
  // Eram getters avaliados a cada build() — com 854 produtos, isso era um mapa
  // de 854 entradas remontado (e 854 hex reparseados) a cada setState, e a
  // identidade nova do Map ainda derrubava as comparações rio abaixo.
  Map<String, Color>   _corPorProduto    = const {};
  Map<String, Produto> _produtoPorCodigo = const {};

  void _recomputarCatalogoDerivado() {
    final catalogo = _catalogoAtual;
    _corPorProduto = mesclarCores(
      {for (final e in _hexDoLayout.entries) e.key: corDeHex(e.value)},
      catalogo,
    );
    _produtoPorCodigo = {for (final p in catalogo) p.codigo: p};
  }

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
    _gondolaAtual       = widget.gondolaInicial;
    _destacadoCodigo    = widget.produtoDestacado?.produtoCodigo;
    _faceSelecionada    = widget.produtoDestacado?.face;
    _andarSelecionado   = widget.produtoDestacado?.andar;
    _faceParaCamera     = widget.produtoDestacado?.face;
    _destacadosCodigos  = widget.codigosConferencia ?? {};
    _inicializar();
    TursoService().dataRevision.addListener(_aoAtualizarDados);
  }

  @override
  void dispose() {
    TursoService().dataRevision.removeListener(_aoAtualizarDados);
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

    if (!conectado) {
      setState(() {
        _produtos           = [];
        _carregandoProdutos = false;
        _recomputarCatalogoDerivado();
      });
      return;
    }

    // Só o layout é esperado: ele já traz cor e nome de cada caixa, então a
    // cena aparece completa e nas cores certas. O catálogo (estoque_mestre) só
    // é preciso para o autocomplete do "Adicionar" e para o contador — esperar
    // por ele aqui era o que deixava as caixas cinzas até a consulta voltar,
    // atrás ainda das duas consultas de badge na fila do banco.
    await _carregarLayout(_gondolaAtual);
    unawaited(_carregarDesatualizados());
    unawaited(_carregarCatalogo());
  }

  Future<void> _carregarCatalogo() async {
    final produtos = await TursoService().fetchProdutos();
    if (!mounted) return;
    setState(() {
      _produtos           = produtos;
      _carregandoProdutos = false;
      _recomputarCatalogoDerivado();
      // Reaplica o filtro no que já estava digitado: sem isso, quem começou a
      // buscar antes do catálogo chegar teria de reescrever para ver sugestão.
      if (_ctrl1.text.length >= 2) _sugestoes1 = _filtrarProdutos(_ctrl1.text);
      if (_ctrl2.text.length >= 2) _sugestoes2 = _filtrarProdutos(_ctrl2.text);
    });
  }

  // Recarrega a cena quando uma sincronização (carga inicial em segundo plano
  // ou botão Sincronizar) traz dados novos, sem travar a abertura. É o ÚNICO
  // caminho de recarga pós-sync — o botão Sincronizar não chama _inicializar,
  // senão tudo rodaria em dobro.
  void _aoAtualizarDados() {
    if (!mounted) return;
    // Descarta só as OUTRAS estruturas: limpar a atual aqui (fora de setState,
    // com o reload assíncrono) daria um frame com a gôndola vazia.
    _caixas.removeWhere((k, _) => k != _gondolaAtual);
    _carregarLayout(_gondolaAtual);
    unawaited(_carregarDesatualizados(forceRefresh: true));
    // sincronizar() zera o cache do catálogo, então ele precisa ser relido —
    // era o que o _inicializar do botão Sincronizar fazia.
    unawaited(_carregarCatalogo());
  }

  Future<void> _carregarDesatualizados({bool forceRefresh = false}) async {
    final servico = EstoqueLocalizadoService();
    final resultados = await Future.wait([
      servico.fetchEnderecosDesatualizados(forceRefresh: forceRefresh),
      servico.fetchEnderecosDivergentes(forceRefresh: forceRefresh),
    ]);
    if (!mounted) return;
    setState(() {
      _desatualizados       = resultados[0];
      _divergentes          = resultados[1];
      // Lido do cache preenchido pela fetchEnderecosDivergentes acima.
      _divergentesPositivas = servico.divergentesPositivas;
    });
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _trocarGondola(int delta) {
    final nova = (_gondolaAtual + delta).clamp(1, 12);
    setState(() {
      _gondolaAtual     = nova;
      // Com layout em cache, mostra na hora e atualiza em silêncio por trás;
      // a barra de progresso só aparece na primeira visita à gôndola.
      final semeou = _semearDoCache(nova);
      _carregandoLayout =
          !semeou && _dbConectado && !_caixas.containsKey(nova);
      _caixaSelecionada = null;
    });
    if (_dbConectado) _carregarLayout(nova);
  }

  /// Preenche a gôndola a partir do cache do serviço, se ela já tiver sido
  /// lida. Síncrono: é o que permite o carrossel trocar de estrutura dentro do
  /// mesmo frame do toque, sem passar pelo banco.
  ///
  /// Deve ser chamado de dentro de um setState.
  bool _semearDoCache(int gondolaNum) {
    final cache = TursoService().layoutEmCache(gondolaNum);
    if (cache == null) return false;
    _aplicarLayout(gondolaNum, cache);
    return true;
  }

  /// Aplica as linhas do banco à cena: as caixas e, junto, o mapa de cores e
  /// nomes que vem nas próprias linhas. Deve ser chamado de dentro de setState.
  void _aplicarLayout(int gondolaNum, List<CaixaLayout> layouts) {
    _caixas[gondolaNum] = layouts.map(_caixaDoLayout).toList();
    if (gondolaNum == _gondolaAtual) {
      _hexDoLayout   = {for (final l in layouts) l.produtoCodigo: l.corHex};
      _nomesDoLayout = {for (final l in layouts) l.produtoCodigo: l.produtoNome};
      _recomputarCatalogoDerivado();
      _carregandoLayout = false;
    }
  }

  // Caixas gravadas na era do octógono podem cair fora do hexágono novo
  // (apótema menor): o clamp corrige só a exibição — a posição no banco
  // persiste até a próxima edição normal do usuário.
  CaixaColocada _caixaDoLayout(CaixaLayout l) {
    final andar = l.andar.clamp(0, 2);
    final pos   = GondolaGeometry.clampAoAndar(andar, l.posX, l.posZ);
    return CaixaColocada(
      andar:     andar,
      produtoId: l.produtoCodigo,
      x:         pos.x,
      z:         pos.z,
    );
  }

  Future<void> _carregarLayout(int gondolaNum) async {
    final layouts = await TursoService().fetchLayout(gondolaNum);
    if (!mounted) return;
    setState(() => _aplicarLayout(gondolaNum, layouts));
  }

  void _onTapAndar(int andar, double x, double z) {
    if (_produtoSelecionadoId == null) return;
    final nova = CaixaColocada(
      andar:     andar,
      produtoId: _produtoSelecionadoId!,
      x:         x,
      z:         z,
    );
    setState(() {
      _caixas[_gondolaAtual] = [..._caixasAtuais, nova];
      _faceSelecionada  = faceFromPos(x, z);
      _andarSelecionado = andar;
      _caixaSelecionada = nova;
    });
  }

  void _onFaceTap(int face, int? andar, double? x, double? z) {
    // Uma face+andar pode ter várias caixas de produtos diferentes: escolhe
    // a mais próxima do ponto exato do toque, não a primeira cadastrada.
    final caixa = (andar != null && x != null && z != null)
        ? _caixaMaisProximaEm(face, andar, x, z)
        : null;
    setState(() {
      _faceSelecionada = face;
      if (andar != null) _andarSelecionado = andar;
      _caixaSelecionada = caixa;
    });
    // Só abre o dialog de quantidade quando o toque veio de uma prateleira
    // (andar != null) e há de fato uma caixa colocada ali — tap num label
    // de face (andar == null) ou numa prateleira vazia só seleciona a face.
    if (andar == null || caixa == null) return;
    _abrirQuantidade(
      produtoCodigo: caixa.produtoId,
      localTipo:     'gondola',
      localNum:      _gondolaAtual,
      faceOuColuna:  face,
      andarOuNivel:  andar,
    );
  }

  CaixaColocada? _caixaEm(int face, int andar) {
    for (final c in _caixasAtuais) {
      if (c.andar == andar && faceFromPos(c.x, c.z) == face) return c;
    }
    return null;
  }

  CaixaColocada? _caixaMaisProximaEm(int face, int andar, double x, double z) {
    CaixaColocada? melhor;
    var melhorDist = double.infinity;
    for (final c in _caixasAtuais) {
      if (c.andar != andar || faceFromPos(c.x, c.z) != face) continue;
      final dx = c.x - x, dz = c.z - z;
      final dist = dx * dx + dz * dz;
      if (dist < melhorDist) {
        melhorDist = dist;
        melhor     = c;
      }
    }
    return melhor;
  }

  // Produto da caixa no endereço selecionado — alimenta o nome exibido no
  // chip de endereço para o usuário saber qual produto selecionou. Prioriza
  // a caixa exata tocada; cai no endereço (face + andar) quando ela não vale
  // mais (layout recarregado, caixa removida).
  Produto? get _produtoNoEnderecoSelecionado {
    if (_faceSelecionada == null || _andarSelecionado == null) return null;
    final selecionada = _caixaSelecionada;
    final caixa = (selecionada != null && _caixasAtuais.contains(selecionada))
        ? selecionada
        : _caixaEm(_faceSelecionada!, _andarSelecionado!);
    if (caixa == null) return null;
    final doCatalogo = _produtoPorCodigo[caixa.produtoId];
    if (doCatalogo != null) return doCatalogo;
    // Produto fora do catálogo carregado (ou catálogo ainda a caminho): usa o
    // nome e a cor que vieram na própria linha do layout, caindo no código só
    // se nem isso houver.
    return Produto(
      codigo:    caixa.produtoId,
      nome:      _nomesDoLayout[caixa.produtoId] ?? caixa.produtoId,
      categoria: '',
      corHex:    _hexDoLayout[caixa.produtoId] ?? '#888888',
    );
  }

  Future<void> _abrirQuantidade({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
    required int faceOuColuna,
    required int andarOuNivel,
  }) async {
    final produtoNome = _produtoPorCodigo[produtoCodigo]?.nome ??
        _nomesDoLayout[produtoCodigo] ??
        produtoCodigo;
    await mostrarQuantidadeDialog(
      context,
      produtoCodigo: produtoCodigo,
      produtoNome:   produtoNome,
      localTipo:     localTipo,
      localNum:      localNum,
      faceOuColuna:  faceOuColuna,
      andarOuNivel:  andarOuNivel,
    );
    // O dialog pode ter alterado atualizado_em de algum endereço: recarrega
    // o conjunto de desatualizados pro badge refletir o estado atual.
    _carregarDesatualizados();
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
    final produtos = produtosComCaixa(
      idsComCaixa: _caixasAtuais.map((c) => c.produtoId),
      catalogo:    _catalogoAtual,
    );

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
        content: _DialogLimparProduto(
          produtos: produtos,
          qtdPorProduto: {
            for (final p in produtos)
              p.codigo:
                  _caixasAtuais.where((c) => c.produtoId == p.codigo).length,
          },
          onExcluirProduto: (codigo) {
            Navigator.pop(ctx);
            _limparPorProduto(codigo);
          },
          onLimparTudo: () {
            Navigator.pop(ctx);
            _confirmarLimparTudo();
          },
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

  void _confirmarLimparTudo() {
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

    // Nome e cor vêm do catálogo quando ele já chegou; senão, do que a própria
    // linha já tinha no banco. Essa segunda fonte importa porque o catálogo
    // agora carrega depois da cena: salvar dentro dessa janela sem ela gravaria
    // o código no lugar do nome e cinza no lugar da cor.
    final itens = _caixasAtuais.map((c) {
      final produto = _produtoPorCodigo[c.produtoId];
      return CaixaLayout(
        gondolaNum:    _gondolaAtual,
        andar:         c.andar,
        produtoCodigo: c.produtoId,
        produtoNome:   produto?.nome ?? _nomesDoLayout[c.produtoId] ?? c.produtoId,
        posX:          c.x,
        posZ:          c.z,
        corHex:        produto?.corHex ?? _hexDoLayout[c.produtoId] ?? '#888888',
      );
    }).toList();

    // Produtos que estavam no layout PERSISTIDO e saíram nesta edição: os
    // endereços ZERADOS deles nesta gôndola são apagados junto (quantidades
    // > 0 são estoque contado e só somem pela lixeira do dialog).
    //
    // Tem de ser o layout persistido, não `_caixasAtuais`: este último é a
    // edição em curso, e comparado consigo mesmo nunca acusaria remoção
    // nenhuma. O cache do serviço guarda exatamente as linhas persistidas, daí
    // dar para pular a releitura quando ele está quente.
    final persistido = TursoService().layoutEmCache(_gondolaAtual) ??
        await TursoService().fetchLayout(_gondolaAtual);
    final antes = persistido.map((c) => c.produtoCodigo).toSet();

    final ok = await TursoService().salvarLayout(_gondolaAtual, itens);
    if (ok) {
      final depois = itens.map((i) => i.produtoCodigo).toSet();
      for (final codigo in antes.difference(depois)) {
        await EstoqueLocalizadoService().deleteEnderecosZerados(
          produtoCodigo: codigo,
          localTipo:     'gondola',
          localNum:      _gondolaAtual,
        );
      }
    }
    if (!mounted) return;
    setState(() => _salvando = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Layout salvo ✓' : 'Erro ao salvar'),
      backgroundColor: ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _sincronizar() async {
    if (_sincronizando) return;
    setState(() => _sincronizando = true);
    final ok = await TursoService().sincronizar();
    if (!mounted) return;
    setState(() => _sincronizando = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Sincronizado com o banco online ✓'
          : 'Não foi possível sincronizar — '
              '${TursoService().ultimoErroSync ?? 'verifique a conexão'}'),
      backgroundColor: ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: Duration(seconds: ok ? 2 : 6),
    ));
    // A recarga pós-sync NÃO é feita aqui: sincronizar() incrementa
    // dataRevision, e o listener _aoAtualizarDados já descarta os layouts em
    // memória e recarrega tudo (edições não salvas são substituídas). Chamar
    // _inicializar também, como antes, fazia cada consulta rodar duas vezes.
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

    // Consulta gôndolas e estantes em paralelo: corta pela metade a latência
    // do caso em que o produto só existe numa estante.
    final resultados = await Future.wait([
      TursoService().buscarProduto(produto.codigo),
      TursoService().buscarProdutoEstante(produto.codigo),
    ]);
    if (!mounted) return;
    final encontrado = resultados[0] as CaixaLayout?;
    final naEstante  = resultados[1] as CaixaLayoutEstante?;

    if (encontrado == null) {
      if (naEstante != null) {
        final nivProduto = niveisProdutoPara(naEstante.estanteNum);
        final maxColunas = numColunasPara(naEstante.estanteNum);
        final nivelNomes =
            List.generate(nivProduto, (i) => 'Nível ${i + 1}');
        final colNomes   =
            List.generate(maxColunas, (i) => 'Col. ${i + 1}');
        final col = naEstante.coluna.clamp(0, maxColunas - 1);
        final niv = naEstante.nivel.clamp(0, nivProduto - 1);
        // No palete o endereço é uma posição só (1–15) e o slot é sempre 0, então
        // decompor em Col./Nível/Slot não diria nada ao usuário: ele procura pela
        // etiqueta no chão.
        final locEstante = ehPalete(naEstante.estanteNum)
            ? '📦 ${produto.nome}\n'
                'Palete ${naEstante.estanteNum} · posição '
                '${letraEstanteCelula(naEstante.estanteNum, col, niv)}'
            : '📦 ${produto.nome}\n'
                'Estante ${naEstante.estanteNum} · ${colNomes[col]} · '
                '${nivelNomes[niv]} · Slot ${naEstante.slot + 1}';
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
    final andar     = encontrado.andar.clamp(0, 2);
    final andarNome = ['Base', 'Meio', 'Topo'][andar];
    final face      = faceFromPos(encontrado.posX, encontrado.posZ);
    setState(() {
      // Via _aplicarLayout para as cores/nomes da linha entrarem junto — sem
      // isso, saltar direto da busca para outra gôndola deixaria a cena com o
      // mapa de cores da anterior.
      _aplicarLayout(encontrado.gondolaNum, layouts);
      // A caixa destacada tem de ser a MESMA instância que foi para _caixas:
      // CaixaColocada não sobrescreve ==, e _produtoNoEnderecoSelecionado
      // confere a seleção com `_caixasAtuais.contains(...)`.
      CaixaColocada? caixaEncontrada;
      for (final c in _caixas[encontrado.gondolaNum] ?? const <CaixaColocada>[]) {
        if (c.produtoId == produto.codigo &&
            c.andar == andar &&
            faceFromPos(c.x, c.z) == face) {
          caixaEncontrada = c;
          break;
        }
      }
      _destacadoCodigo  = produto.codigo;
      _faceSelecionada  = face;
      _andarSelecionado = andar;
      _caixaSelecionada = caixaEncontrada;
      _faceParaCamera   = face;
      _resultadoBusca   =
          '📍 ${produto.nome}\nGôndola ${encontrado.gondolaNum} · Face $face · Andar $andarNome';
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        '📍 ${produto.nome} → Gôndola ${encontrado.gondolaNum}, Face $face, Andar $andarNome',
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
      _faceSelecionada      = null;
      _andarSelecionado     = null;
      _caixaSelecionada     = null;
      _faceParaCamera       = null;
      _destacadosCodigos    = widget.codigosConferencia ?? {};
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
          if (_dbConectado)
            IconButton(
              icon: _sincronizando
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF4a9d6a),
                      ),
                    )
                  : const Icon(Icons.sync, color: Color(0xFF8a9aa8), size: 22),
              tooltip: 'Sincronizar com o banco online',
              onPressed: _sincronizando ? null : _sincronizar,
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
          child: Stack(children: [
            GondolaScene(
              gondolaAtual:         _gondolaAtual,
              caixas:               _caixasAtuais,
              produtoSelecionadoId: _produtoSelecionadoId,
              corPorProduto:        _corPorProduto,
              onTapAndar:           _onTapAndar,
              destacadoCodigo:      _destacadoCodigo,
              faceSelecionada:      _faceSelecionada,
              onFaceTap:            _onFaceTap,
              faceParaCamera:       _faceParaCamera,
              desatualizados:       _desatualizados,
              divergentes:          _divergentes,
              divergentesPositivas: _divergentesPositivas,
              destacadosCodigos:    _destacadosCodigos,
            ),
            if (_faceSelecionada != null)
              Positioned(
                top:  10,
                left: 12,
                child: _EnderecoChip(
                  endereco: _andarSelecionado != null
                      ? 'G$_gondolaAtual · F$_faceSelecionada · A${_andarSelecionado! + 1}'
                      : 'G$_gondolaAtual · F$_faceSelecionada',
                  produtoNome: _produtoNoEnderecoSelecionado?.nome,
                  produtoCor:  _produtoNoEnderecoSelecionado?.cor,
                ),
              ),
          ]),
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
          )
        else if (_catalogoAindaChegando(_ctrl1.text))
          const _AvisoCatalogoCarregando(),
      ],
    );
  }

  /// True quando não há sugestão a mostrar só porque o catálogo ainda não
  /// chegou — e não porque a busca realmente não deu resultado.
  bool _catalogoAindaChegando(String texto) =>
      _carregandoProdutos && _dbConectado && texto.length >= 2;

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
          )
        else if (_catalogoAindaChegando(_ctrl2.text))
          const _AvisoCatalogoCarregando(),
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

/// Aviso no lugar da lista de sugestões enquanto o catálogo ainda está sendo
/// carregado.
///
/// O catálogo passou a chegar DEPOIS da cena (a cena não depende dele para
/// pintar). Nessa janela, quem digitasse no autocomplete veria uma lista vazia
/// — indistinguível de "produto não existe". Isto diz que é só esperar.
class _AvisoCatalogoCarregando extends StatelessWidget {
  const _AvisoCatalogoCarregando();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161b22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2a3441)),
      ),
      child: Row(children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFF8a9aa8)),
        ),
        const SizedBox(width: 10),
        const Text('Carregando catálogo...',
            style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 12)),
      ]),
    );
  }
}

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

// ── Chip de endereço + produto selecionado (gôndola e estante) ────────────────

class _EnderecoChip extends StatelessWidget {
  final String  endereco;
  final String? produtoNome;
  final Color?  produtoCor;

  const _EnderecoChip({
    required this.endereco,
    this.produtoNome,
    this.produtoCor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      constraints: const BoxConstraints(maxWidth: 250),
      decoration: BoxDecoration(
        color: const Color(0xEE16171A),
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            endereco,
            style: const TextStyle(
              color:         Color(0xFFe87722),
              fontSize:      14,
              fontWeight:    FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          if (produtoNome != null) ...[
            const SizedBox(height: 5),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width:  10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: produtoCor ?? const Color(0xFF888888),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    produtoNome!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color:    Colors.white,
                      fontSize: 12,
                      height:   1.25,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
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
  final int          estanteInicial;
  final ProdutoLoja? produtoDestacado;
  // Modo Conferência (Fase 3): códigos pendentes de hoje que moram nesta
  // estante, vindos do mapa — acende todas as caixas de uma vez.
  final Set<String>? codigosConferencia;

  const EstantePage({
    super.key,
    this.estanteInicial  = 1,
    this.produtoDestacado,
    this.codigosConferencia,
  });

  @override
  State<EstantePage> createState() => _EstantePageState();
}

class _EstantePageState extends State<EstantePage> {
  int     _estanteAtual        = 1;
  String? _produtoSelecionadoId;
  String? _destacadoCodigo;
  Timer?  _highlightTimer;

  // Endereço selecionado na cena: célula (coluna, nível) e slot da caixa
  // tocada — alimenta o chip de endereço com o nome do produto.
  int? _colunaSelecionada;
  int? _nivelSelecionado;
  int? _slotSelecionado;

  final Map<int, List<CaixaColocadaEstante>> _caixas = {};

  // Endereços desatualizados (Fase 2) — carregado uma vez ao abrir a página
  // e recarregado após salvar no dialog de quantidade.
  Set<String> _desatualizados = {};

  // Endereços com divergência de contagem — carregado junto com os
  // desatualizados; badge vermelho (espelhado do âmbar).
  Set<String> _divergentes = {};

  // Subconjunto de _divergentes cuja divergência é positiva (contado maior
  // que o sistema) — pintado de azul escuro em vez de vermelho.
  Set<String> _divergentesPositivas = {};

  // Códigos acesos pelo Modo Conferência (Fase 3), vindos do mapa.
  late Set<String> _destacadosCodigos;

  List<Produto> _produtos           = [];
  bool          _dbConectado        = false;
  bool          _carregandoProdutos = false;
  bool          _carregandoLayout   = false;
  bool          _salvando           = false;
  bool          _sincronizando      = false;

  int? _expanderAberto;

  final _ctrl1 = TextEditingController();
  List<Produto> _sugestoes1 = [];
  Produto? _produtoChip;

  final _ctrl2 = TextEditingController();
  List<Produto> _sugestoes2 = [];

  // ── Helpers ────────────────────────────────────────────────────────────────

  // Ver a nota do gêmeo em _GondolaPageState: com banco conectado o catálogo
  // chega depois da cena, e o mock nessa janela pintaria códigos falsos.
  List<Produto> get _catalogoAtual => _produtos.isNotEmpty
      ? _produtos
      : (_dbConectado ? const <Produto>[] : _catalogoMock);

  List<CaixaColocadaEstante> get _caixasAtuais =>
      _caixas[_estanteAtual] ?? const [];

  // Cor e nome vindos das próprias linhas de estante_layout — ver o gêmeo em
  // _GondolaPageState.
  Map<String, String> _hexDoLayout   = const {};
  Map<String, String> _nomesDoLayout = const {};

  Map<String, Color>   _corPorProduto    = const {};
  Map<String, Produto> _produtoPorCodigo = const {};

  void _recomputarCatalogoDerivado() {
    final catalogo = _catalogoAtual;
    _corPorProduto = mesclarCores(
      {for (final e in _hexDoLayout.entries) e.key: corDeHex(e.value)},
      catalogo,
    );
    _produtoPorCodigo = {for (final p in catalogo) p.codigo: p};
  }

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
    _estanteAtual      = widget.estanteInicial;
    _destacadoCodigo   = widget.produtoDestacado?.produtoCodigo;
    _destacadosCodigos = widget.codigosConferencia ?? {};
    _inicializar();
    TursoService().dataRevision.addListener(_aoAtualizarDados);
  }

  @override
  void dispose() {
    TursoService().dataRevision.removeListener(_aoAtualizarDados);
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

    if (!conectado) {
      setState(() {
        _produtos           = [];
        _carregandoProdutos = false;
        _recomputarCatalogoDerivado();
      });
      return;
    }

    // Só o layout é esperado — ver a nota do gêmeo em _GondolaPageState.
    await _carregarLayout(_estanteAtual);
    unawaited(_carregarDesatualizados());
    unawaited(_carregarCatalogo());
  }

  Future<void> _carregarCatalogo() async {
    final produtos = await TursoService().fetchProdutos();
    if (!mounted) return;
    setState(() {
      _produtos           = produtos;
      _carregandoProdutos = false;
      _recomputarCatalogoDerivado();
      if (_ctrl1.text.length >= 2) _sugestoes1 = _filtrarProdutos(_ctrl1.text);
      if (_ctrl2.text.length >= 2) _sugestoes2 = _filtrarProdutos(_ctrl2.text);
    });
  }

  // Recarrega a cena quando uma sincronização (carga inicial em segundo plano
  // ou botão Sincronizar) traz dados novos, sem travar a abertura. É o ÚNICO
  // caminho de recarga pós-sync — ver a nota do gêmeo em _GondolaPageState.
  void _aoAtualizarDados() {
    if (!mounted) return;
    _caixas.removeWhere((k, _) => k != _estanteAtual);
    _carregarLayout(_estanteAtual);
    unawaited(_carregarDesatualizados(forceRefresh: true));
    unawaited(_carregarCatalogo());
  }

  Future<void> _carregarDesatualizados({bool forceRefresh = false}) async {
    final servico = EstoqueLocalizadoService();
    final resultados = await Future.wait([
      servico.fetchEnderecosDesatualizados(forceRefresh: forceRefresh),
      servico.fetchEnderecosDivergentes(forceRefresh: forceRefresh),
    ]);
    if (!mounted) return;
    setState(() {
      _desatualizados       = resultados[0];
      _divergentes          = resultados[1];
      // Lido do cache preenchido pela fetchEnderecosDivergentes acima.
      _divergentesPositivas = servico.divergentesPositivas;
    });
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  // Índice da estante atual na ordem do carrossel; -1 se ela saiu da
  // navegação (ex.: dados antigos das estantes 3/4 achados pela busca).
  int get _idxNavegacao => ordemNavegacaoEstantes.indexOf(_estanteAtual);

  void _trocarEstante(int delta) {
    final idx  = _idxNavegacao;
    final nova = idx == -1
        ? ordemNavegacaoEstantes.first
        : ordemNavegacaoEstantes[
            (idx + delta).clamp(0, ordemNavegacaoEstantes.length - 1)];
    setState(() {
      _estanteAtual     = nova;
      // Com layout em cache, mostra na hora e atualiza em silêncio por trás;
      // a barra de progresso só aparece na primeira visita à estante.
      final semeou = _semearDoCache(nova);
      _carregandoLayout =
          !semeou && _dbConectado && !_caixas.containsKey(nova);
      // Células mudam de geometria entre estantes: seleção antiga não vale.
      _colunaSelecionada = null;
      _nivelSelecionado  = null;
      _slotSelecionado   = null;
    });
    if (_dbConectado) _carregarLayout(nova);
  }

  /// Preenche a estante a partir do cache do serviço, se ela já tiver sido
  /// lida. Ver o gêmeo em _GondolaPageState. Chamar de dentro de setState.
  bool _semearDoCache(int estanteNum) {
    final cache = TursoService().layoutEstanteEmCache(estanteNum);
    if (cache == null) return false;
    _aplicarLayout(estanteNum, cache);
    return true;
  }

  /// Aplica as linhas do banco à cena, junto com as cores e nomes que vêm
  /// nelas. Chamar de dentro de setState.
  void _aplicarLayout(int estanteNum, List<CaixaLayoutEstante> layouts) {
    _caixas[estanteNum] = layouts
        .map((l) => CaixaColocadaEstante(
              coluna:    l.coluna,
              nivel:     l.nivel,
              slot:      l.slot,
              produtoId: l.produtoCodigo,
            ))
        .toList();
    if (estanteNum == _estanteAtual) {
      _hexDoLayout   = {for (final l in layouts) l.produtoCodigo: l.corHex};
      _nomesDoLayout = {for (final l in layouts) l.produtoCodigo: l.produtoNome};
      _recomputarCatalogoDerivado();
      _carregandoLayout = false;
    }
  }

  Future<void> _carregarLayout(int estanteNum) async {
    final layouts = await TursoService().fetchLayoutEstante(estanteNum);
    if (!mounted) return;
    setState(() => _aplicarLayout(estanteNum, layouts));
  }

  ({int maxSlots, double xMin, double wCaixa, double gap}) _geometriaCelula(
      int coluna, int nivel) {
    if (ehEstanteEdr300(_estanteAtual)) {
      final geo = Edr300Geometry(
          showFloor: false, colunas: numColunasPara(_estanteAtual));
      final celula = geo.cells
          .firstWhere((c) => c.coluna == coluna && c.nivel == nivel);
      return (
        maxSlots: Edr300Geometry.slotsPorCelula(celula),
        xMin:     celula.xMin,
        wCaixa:   Edr300Geometry.wCaixa,
        gap:      Edr300Geometry.gap,
      );
    }
    if (_estanteAtual == expositorMagnojetNum) {
      const geo = ExpositorMagnojetGeometry();
      final celula = geo.cells
          .firstWhere((c) => c.coluna == coluna && c.linha == nivel);
      // Um produto por endereço (gancho ou espaço da base): slot sempre 0.
      final w = celula.ehBase
          ? ExpositorMagnojetGeometry.wCaixa
          : ExpositorMagnojetGeometry.wPacote;
      return (
        maxSlots: 1,
        xMin:     celula.xCenter - w / 2,
        wCaixa:   w,
        gap:      0.0,
      );
    }
    if (_estanteAtual == expositorNelloreNum) {
      const geo = ExpositorNelloreGeometry();
      final celula = geo.cells
          .firstWhere((c) => c.coluna == coluna && c.nivel == nivel);
      // Um produto por endereço: slot sempre 0.
      return (
        maxSlots: 1,
        xMin:     celula.xCenter - ExpositorNelloreGeometry.wCaixa / 2,
        wCaixa:   ExpositorNelloreGeometry.wCaixa,
        gap:      0.0,
      );
    }
    if (_estanteAtual == expositorMonitorNum) {
      const geo = ExpositorMonitorGeometry();
      final celula = geo.cells
          .firstWhere((c) => c.coluna == coluna && c.nivel == nivel);
      // Um produto por endereço: slot sempre 0.
      return (
        maxSlots: 1,
        xMin:     celula.xCenter - ExpositorMonitorGeometry.wCaixa / 2,
        wCaixa:   ExpositorMonitorGeometry.wCaixa,
        gap:      0.0,
      );
    }
    // Palete: uma caixa por posição, slot sempre 0. Precisa de entrada própria
    // aqui (como cada uma das outras geometrias) porque o fallback lá embaixo
    // usa EstanteGeometry, que tem 3 colunas fixas e estouraria no firstWhere
    // nas colunas 3 e 4 do palete.
    if (ehPalete(_estanteAtual)) {
      final celula = PaleteGeometry.celulas()
          .firstWhere((c) => c.coluna == coluna && c.nivel == nivel);
      return (
        maxSlots: 1,
        xMin:     celula.xCenter - PaleteGeometry.wCaixa / 2,
        wCaixa:   PaleteGeometry.wCaixa,
        gap:      0.0,
      );
    }
    if (ehEstanteParede(_estanteAtual)) {
      final celula = EstanteParedeGeometry.celulas()
          .firstWhere((c) => c.coluna == coluna && c.nivel == nivel);
      // xMin do slot 0 (não da célula): os slots são centralizados na coluna.
      return (
        maxSlots: EstanteParedeGeometry.maxSlots,
        xMin:     EstanteParedeGeometry.xSlot0(celula),
        wCaixa:   EstanteParedeGeometry.wCaixa,
        gap:      EstanteParedeGeometry.gap,
      );
    }
    final celula = EstanteGeometry.celulasPara(_estanteAtual)
        .firstWhere((c) => c.coluna == coluna && c.nivel == nivel);
    return (
      maxSlots: EstanteGeometry.slotsPorCelula(celula),
      xMin:     celula.xMin,
      wCaixa:   EstanteGeometry.wCaixa,
      gap:      EstanteGeometry.gap,
    );
  }

  // Fora do modo de edição: acha a caixa existente mais próxima do toque
  // dentro da célula (coluna, nivel) e abre o dialog de quantidade.
  void _onTapCelulaVisualizar(int coluna, int nivel, double hx) {
    final ocupantes =
        _caixasAtuais.where((c) => c.coluna == coluna && c.nivel == nivel).toList();
    if (ocupantes.isEmpty) {
      // Célula vazia: só marca o endereço no chip, sem produto.
      setState(() {
        _colunaSelecionada = coluna;
        _nivelSelecionado  = nivel;
        _slotSelecionado   = null;
      });
      return;
    }

    final geo = _geometriaCelula(coluna, nivel);
    final slotEstimado = ((hx - geo.xMin) / (geo.wCaixa + geo.gap))
        .floor()
        .clamp(0, geo.maxSlots - 1);
    ocupantes.sort(
        (a, b) => (a.slot - slotEstimado).abs().compareTo((b.slot - slotEstimado).abs()));
    final caixa = ocupantes.first;

    setState(() {
      _colunaSelecionada = coluna;
      _nivelSelecionado  = nivel;
      _slotSelecionado   = caixa.slot;
    });

    _abrirQuantidade(
      produtoCodigo: caixa.produtoId,
      localTipo:     'estante',
      localNum:      _estanteAtual,
      faceOuColuna:  coluna,
      andarOuNivel:  nivel,
    );
  }

  // Produto da caixa no endereço selecionado (célula + slot) — alimenta o
  // nome exibido no chip de endereço para o usuário saber qual produto tocou.
  Produto? get _produtoNoEnderecoSelecionado {
    if (_slotSelecionado == null) return null;
    final matches = _caixasAtuais.where((c) =>
        c.coluna == _colunaSelecionada &&
        c.nivel  == _nivelSelecionado &&
        c.slot   == _slotSelecionado);
    if (matches.isEmpty) return null;
    final caixa = matches.first;
    final doCatalogo = _produtoPorCodigo[caixa.produtoId];
    if (doCatalogo != null) return doCatalogo;
    // Produto fora do catálogo carregado (ou catálogo ainda a caminho): usa o
    // nome e a cor que vieram na própria linha do layout.
    return Produto(
      codigo:    caixa.produtoId,
      nome:      _nomesDoLayout[caixa.produtoId] ?? caixa.produtoId,
      categoria: '',
      corHex:    _hexDoLayout[caixa.produtoId] ?? '#888888',
    );
  }

  String get _enderecoSelecionadoTexto {
    final letra = letraEstanteCelula(
        _estanteAtual, _colunaSelecionada!, _nivelSelecionado!);
    // No palete o prefixo é P (não E) e não há slot a mostrar — uma caixa por
    // posição —, então o chip fica só 'P102 · 7', igual à etiqueta no chão.
    if (ehPalete(_estanteAtual)) return 'P$_estanteAtual · $letra';
    // Na parede o chip mostra também a posição global P1–P12 (derivada),
    // ex.: 'E15 · AH · Slot 2 (P6)'.
    final sufixoParede = ehEstanteParede(_estanteAtual)
        ? ' (P${posicaoGlobalParede(_estanteAtual, _colunaSelecionada!)})'
        : '';
    return _slotSelecionado != null
        ? 'E$_estanteAtual · $letra · Slot ${_slotSelecionado! + 1}$sufixoParede'
        : 'E$_estanteAtual · $letra$sufixoParede';
  }

  Future<void> _abrirQuantidade({
    required String produtoCodigo,
    required String localTipo,
    required int localNum,
    required int faceOuColuna,
    required int andarOuNivel,
  }) async {
    final produtoNome = _produtoPorCodigo[produtoCodigo]?.nome ??
        _nomesDoLayout[produtoCodigo] ??
        produtoCodigo;
    await mostrarQuantidadeDialog(
      context,
      produtoCodigo: produtoCodigo,
      produtoNome:   produtoNome,
      localTipo:     localTipo,
      localNum:      localNum,
      faceOuColuna:  faceOuColuna,
      andarOuNivel:  andarOuNivel,
    );
    // O dialog pode ter alterado atualizado_em de algum endereço: recarrega
    // o conjunto de desatualizados pro badge refletir o estado atual.
    _carregarDesatualizados();
  }

  void _onTapCelula(int coluna, int nivel, double hx) {
    if (_produtoSelecionadoId == null) return;

    final geo = _geometriaCelula(coluna, nivel);
    final maxSlots = geo.maxSlots;

    final offsetNaCelula = hx - geo.xMin;
    var slotDesejado =
        (offsetNaCelula / (geo.wCaixa + geo.gap))
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
      _colunaSelecionada = coluna;
      _nivelSelecionado  = nivel;
      _slotSelecionado   = slotDesejado;
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
    final produtos = produtosComCaixa(
      idsComCaixa: _caixasAtuais.map((c) => c.produtoId),
      catalogo:    _catalogoAtual,
    );

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
        content: _DialogLimparProduto(
          produtos: produtos,
          qtdPorProduto: {
            for (final p in produtos)
              p.codigo:
                  _caixasAtuais.where((c) => c.produtoId == p.codigo).length,
          },
          onExcluirProduto: (codigo) {
            Navigator.pop(ctx);
            _limparEstantePorProduto(codigo);
          },
          onLimparTudo: () {
            Navigator.pop(ctx);
            _confirmarLimparTudoEstante();
          },
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

  void _confirmarLimparTudoEstante() {
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

    // Nome e cor do catálogo quando já chegou; senão, do que a linha já tinha.
    // Ver a nota do gêmeo em _GondolaPageState._salvarLayout.
    final itens = _caixasAtuais.map((c) {
      final produto = _produtoPorCodigo[c.produtoId];
      return CaixaLayoutEstante(
        estanteNum:    _estanteAtual,
        coluna:        c.coluna,
        nivel:         c.nivel,
        slot:          c.slot,
        produtoCodigo: c.produtoId,
        produtoNome:   produto?.nome ?? _nomesDoLayout[c.produtoId] ?? c.produtoId,
        corHex:        produto?.corHex ?? _hexDoLayout[c.produtoId] ?? '#888888',
      );
    }).toList();

    // Produtos que estavam no layout PERSISTIDO e saíram nesta edição: os
    // endereços ZERADOS deles nesta estante são apagados junto (quantidades
    // > 0 são estoque contado e só somem pela lixeira do dialog). Tem de ser o
    // persistido, não `_caixasAtuais` — ver a nota do gêmeo em
    // _GondolaPageState._salvarLayout.
    final persistido = TursoService().layoutEstanteEmCache(_estanteAtual) ??
        await TursoService().fetchLayoutEstante(_estanteAtual);
    final antes = persistido.map((c) => c.produtoCodigo).toSet();

    final ok = await TursoService().salvarLayoutEstante(_estanteAtual, itens);
    if (ok) {
      final depois = itens.map((i) => i.produtoCodigo).toSet();
      for (final codigo in antes.difference(depois)) {
        await EstoqueLocalizadoService().deleteEnderecosZerados(
          produtoCodigo: codigo,
          localTipo:     'estante',
          localNum:      _estanteAtual,
        );
      }
    }
    if (!mounted) return;
    setState(() => _salvando = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Layout salvo ✓' : 'Erro ao salvar'),
      backgroundColor:
          ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _sincronizar() async {
    if (_sincronizando) return;
    setState(() => _sincronizando = true);
    final ok = await TursoService().sincronizar();
    if (!mounted) return;
    setState(() => _sincronizando = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Sincronizado com o banco online ✓'
          : 'Não foi possível sincronizar — '
              '${TursoService().ultimoErroSync ?? 'verifique a conexão'}'),
      backgroundColor: ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: Duration(seconds: ok ? 2 : 6),
    ));
    // A recarga pós-sync é feita só pelo listener _aoAtualizarDados (disparado
    // pelo dataRevision que sincronizar() incrementa) — ver a nota do gêmeo em
    // _GondolaPageState._sincronizar.
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

    // Consulta estantes e gôndolas em paralelo: corta pela metade a latência
    // do caso em que o produto só existe numa gôndola.
    final resultados = await Future.wait([
      TursoService().buscarProdutoEstante(produto.codigo),
      TursoService().buscarProduto(produto.codigo),
    ]);
    if (!mounted) return;
    final encontrado = resultados[0] as CaixaLayoutEstante?;
    final naGondola  = resultados[1] as CaixaLayout?;

    if (encontrado == null) {
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
      // Via _aplicarLayout para as cores/nomes da linha entrarem junto — sem
      // isso, saltar da busca para outra estante deixaria a cena com o mapa de
      // cores da anterior.
      _aplicarLayout(encontrado.estanteNum, layouts);
      _destacadoCodigo   = produto.codigo;
      _colunaSelecionada = encontrado.coluna
          .clamp(0, numColunasPara(encontrado.estanteNum) - 1);
      _nivelSelecionado  = encontrado.nivel
          .clamp(0, niveisProdutoPara(encontrado.estanteNum) - 1);
      _slotSelecionado   = encontrado.slot;
    });

    final nivProduto  = niveisProdutoPara(encontrado.estanteNum);
    final maxColunas  = numColunasPara(encontrado.estanteNum);
    final nivelNomes  = List.generate(nivProduto, (i) => 'Nível ${i + 1}');
    // Na parede a coluna é anunciada pela posição global P1–P12.
    final colNomes    = List.generate(
        maxColunas,
        (i) => ehEstanteParede(encontrado.estanteNum)
            ? 'P${posicaoGlobalParede(encontrado.estanteNum, i)}'
            : 'Col. ${i + 1}');
    final nivelNome   = nivelNomes[encontrado.nivel.clamp(0, nivProduto - 1)];
    final colNome     = colNomes[encontrado.coluna.clamp(0, maxColunas - 1)];
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
      _colunaSelecionada    = null;
      _nivelSelecionado     = null;
      _slotSelecionado      = null;
      _destacadosCodigos    = widget.codigosConferencia ?? {};
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
          if (_dbConectado)
            IconButton(
              icon: _sincronizando
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF4a9d6a),
                      ),
                    )
                  : const Icon(Icons.sync, color: Color(0xFF8a9aa8), size: 22),
              tooltip: 'Sincronizar com o banco online',
              onPressed: _sincronizando ? null : _sincronizar,
            ),
          if (ehEstanteEdr300(_estanteAtual))
            IconButton(
              icon: const Icon(Icons.view_in_ar_outlined,
                  color: Color(0xFFe0772b), size: 22),
              tooltip: 'Ver modelo 3D',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const EstanteEdr300Page())),
            ),
          if (_estanteAtual == expositorMagnojetNum)
            IconButton(
              icon: const Icon(Icons.view_in_ar_outlined,
                  color: Color(0xFFe0772b), size: 22),
              tooltip: 'Ver modelo 3D',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const ExpositorMagnojetPage())),
            ),
          if (_estanteAtual == expositorNelloreNum)
            IconButton(
              icon: const Icon(Icons.view_in_ar_outlined,
                  color: Color(0xFFe0772b), size: 22),
              tooltip: 'Ver modelo 3D',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const ExpositorNellorePage())),
            ),
          if (_estanteAtual == expositorMonitorNum)
            IconButton(
              icon: const Icon(Icons.view_in_ar_outlined,
                  color: Color(0xFFe0772b), size: 22),
              tooltip: 'Ver modelo 3D',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const ExpositorMonitorPage())),
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
          onPrev: _idxNavegacao > 0 ? () => _trocarEstante(-1) : null,
          onNext: _idxNavegacao < ordemNavegacaoEstantes.length - 1
              ? () => _trocarEstante(1)
              : null,
        ),

        Expanded(
          child: Stack(children: [
            ehEstanteEdr300(_estanteAtual)
                ? Edr300Scene(
                    geometry:            Edr300Geometry(
                        showFloor: false,
                        colunas:   numColunasPara(_estanteAtual)),
                    estanteNum:          _estanteAtual,
                    autoRotate:          false,
                    caixas:              _caixasAtuais,
                    produtoSelecionadoId: _produtoSelecionadoId,
                    corPorProduto:       _corPorProduto,
                    onTapCelula:         _onTapCelula,
                    onTapCelulaVisualizar: _onTapCelulaVisualizar,
                    destacadoCodigo:     _destacadoCodigo,
                    desatualizados:      _desatualizados,
                    divergentes:         _divergentes,
                    divergentesPositivas: _divergentesPositivas,
                    destacadosCodigos:   _destacadosCodigos,
                  )
                : _estanteAtual == expositorMagnojetNum
                    ? ExpositorMagnojetScene(
                        geometry:            const ExpositorMagnojetGeometry(showFloor: false),
                        autoRotate:          false,
                        caixas:              _caixasAtuais,
                        produtoSelecionadoId: _produtoSelecionadoId,
                        corPorProduto:       _corPorProduto,
                        onTapGancho:           (c, l) => _onTapCelula(c, l, 0),
                        onTapGanchoVisualizar: (c, l) => _onTapCelulaVisualizar(c, l, 0),
                        destacadoCodigo:     _destacadoCodigo,
                        desatualizados:      _desatualizados,
                        divergentes:         _divergentes,
                        divergentesPositivas: _divergentesPositivas,
                        destacadosCodigos:   _destacadosCodigos,
                      )
                : _estanteAtual == expositorNelloreNum
                    ? ExpositorNelloreScene(
                        geometry:            const ExpositorNelloreGeometry(showFloor: false),
                        autoRotate:          false,
                        caixas:              _caixasAtuais,
                        produtoSelecionadoId: _produtoSelecionadoId,
                        corPorProduto:       _corPorProduto,
                        onTapCelula:           (c, n) => _onTapCelula(c, n, 0),
                        onTapCelulaVisualizar: (c, n) => _onTapCelulaVisualizar(c, n, 0),
                        destacadoCodigo:     _destacadoCodigo,
                        desatualizados:      _desatualizados,
                        divergentes:         _divergentes,
                        divergentesPositivas: _divergentesPositivas,
                        destacadosCodigos:   _destacadosCodigos,
                      )
                : _estanteAtual == expositorMonitorNum
                    ? ExpositorMonitorScene(
                        geometry:            const ExpositorMonitorGeometry(showFloor: false),
                        autoRotate:          false,
                        caixas:              _caixasAtuais,
                        produtoSelecionadoId: _produtoSelecionadoId,
                        corPorProduto:       _corPorProduto,
                        onTapCelula:           (c, n) => _onTapCelula(c, n, 0),
                        onTapCelulaVisualizar: (c, n) => _onTapCelulaVisualizar(c, n, 0),
                        destacadoCodigo:     _destacadoCodigo,
                        desatualizados:      _desatualizados,
                        divergentes:         _divergentes,
                        divergentesPositivas: _divergentesPositivas,
                        destacadosCodigos:   _destacadosCodigos,
                      )
                : ehEstanteParede(_estanteAtual)
                    ? EstanteParedeScene(
                        estanteAtual:         _estanteAtual,
                        caixas:               _caixasAtuais,
                        produtoSelecionadoId: _produtoSelecionadoId,
                        corPorProduto:        _corPorProduto,
                        onTapCelula:          _onTapCelula,
                        onTapCelulaVisualizar: _onTapCelulaVisualizar,
                        destacadoCodigo:      _destacadoCodigo,
                        desatualizados:       _desatualizados,
                        divergentes:          _divergentes,
                        divergentesPositivas: _divergentesPositivas,
                        destacadosCodigos:    _destacadosCodigos,
                      )
                : ehPalete(_estanteAtual)
                    ? PaleteScene(
                        estanteAtual:         _estanteAtual,
                        caixas:               _caixasAtuais,
                        produtoSelecionadoId: _produtoSelecionadoId,
                        corPorProduto:        _corPorProduto,
                        onTapCelula:          _onTapCelula,
                        onTapCelulaVisualizar: _onTapCelulaVisualizar,
                        destacadoCodigo:      _destacadoCodigo,
                        desatualizados:       _desatualizados,
                        divergentes:          _divergentes,
                        divergentesPositivas: _divergentesPositivas,
                        destacadosCodigos:    _destacadosCodigos,
                      )
                : EstanteScene(
                    estanteAtual:         _estanteAtual,
                    caixas:               _caixasAtuais,
                    produtoSelecionadoId: _produtoSelecionadoId,
                    corPorProduto:        _corPorProduto,
                    onTapCelula:          _onTapCelula,
                    onTapCelulaVisualizar: _onTapCelulaVisualizar,
                    destacadoCodigo:      _destacadoCodigo,
                    desatualizados:       _desatualizados,
                    divergentes:          _divergentes,
                    divergentesPositivas: _divergentesPositivas,
                    destacadosCodigos:    _destacadosCodigos,
                  ),
            if (_colunaSelecionada != null && _nivelSelecionado != null)
              Positioned(
                top:  10,
                left: 12,
                child: _EnderecoChip(
                  endereco:    _enderecoSelecionadoTexto,
                  produtoNome: _produtoNoEnderecoSelecionado?.nome,
                  produtoCor:  _produtoNoEnderecoSelecionado?.cor,
                ),
              ),
          ]),
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
          )
        else if (_catalogoAindaChegando(_ctrl1.text))
          const _AvisoCatalogoCarregando(),
      ],
    );
  }

  /// True quando não há sugestão a mostrar só porque o catálogo ainda não
  /// chegou — e não porque a busca realmente não deu resultado.
  bool _catalogoAindaChegando(String texto) =>
      _carregandoProdutos && _dbConectado && texto.length >= 2;

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
          )
        else if (_catalogoAindaChegando(_ctrl2.text))
          const _AvisoCatalogoCarregando(),
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

  // O palete não tem geometria própria no mapa, então o apelido é a única
  // pista de QUAL palete da loja é este — vai no subtítulo. O rótulo "PALETE"
  // já está no título, então aqui entra só o apelido; sem apelido, fica a
  // contagem pura em vez de mostrar um separador solto.
  static String _subtituloPalete(int num) {
    final apelido = PaleteRegistry().byNum(num)?.apelido ?? '';
    final base    = 'de ${ordemNavegacaoEstantes.length}';
    return apelido.isEmpty ? base : '$base · $apelido';
  }

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
            // O carrossel mistura estantes e paletes: o título acompanha o que
            // está na tela, senão um palete aparece rotulado como "ESTANTE".
            Text(
              ehPalete(estanteAtual) ? 'PALETE' : 'ESTANTE',
              style: const TextStyle(
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
            Text(
              ehEstanteParede(estanteAtual)
                  ? 'de ${ordemNavegacaoEstantes.length} · PAREDE '
                      'P${posicaoGlobalParede(estanteAtual, 0)}–'
                      'P${posicaoGlobalParede(estanteAtual, colunasParede - 1)}'
                  : estanteAtual == estanteEdr300TriplaNum
                      ? 'de ${ordemNavegacaoEstantes.length} · 3× EDR-300'
                      : ehPalete(estanteAtual)
                          ? _subtituloPalete(estanteAtual)
                          : 'de ${ordemNavegacaoEstantes.length}',
              style: const TextStyle(
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
              estanteNum: estanteEdr300Num,
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

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorMagnojetPage — modelo 3D interativo do Expositor MagnoJet
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMagnojetPage extends StatefulWidget {
  const ExpositorMagnojetPage({super.key});

  @override
  State<ExpositorMagnojetPage> createState() => _ExpositorMagnojetPageState();
}

class _ExpositorMagnojetPageState extends State<ExpositorMagnojetPage> {
  int    _colunas      = 4;
  int    _linhas       = 6;
  bool   _intercalados = true;
  double _height       = 1.70;
  double _width        = 1.05;
  bool   _autoRot      = true;
  bool   _showCesto    = true;
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

  ExpositorMagnojetGeometry get _geo => ExpositorMagnojetGeometry(
    colunas:      _colunas,
    linhas:       _linhas,
    intercalados: _intercalados,
    height:       _height,
    width:        _width,
    showCesto:    _showCesto,
    showFloor:    _showFloor,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: ExpositorMagnojetScene(
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
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text('Expositor',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          letterSpacing: 2, color: _txtDim)),
                    const SizedBox(height: 2),
                    Text.rich(TextSpan(
                      style: const TextStyle(fontSize: 22,
                          fontWeight: FontWeight.bold, color: _txt),
                      children: const [
                        TextSpan(text: 'MagnoJet · '),
                        TextSpan(text: 'Painel canaletado',
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
                    _slider('Colunas', _colunas.toDouble(), 3, 5, 1,
                      (v) => setState(() => _colunas = v.round()),
                      fmt: (v) => '${v.round()}'),
                    _slider('Linhas', _linhas.toDouble(), 4, 8, 1,
                      (v) => setState(() => _linhas = v.round()),
                      fmt: (v) => '${v.round()}'),
                    _slider('Altura (cm)', _height * 100, 120, 210, 2,
                      (v) => setState(() => _height = v / 100),
                      fmt: (v) => '${v.round()}'),
                    _slider('Largura (cm)', _width * 100, 70, 140, 2,
                      (v) => setState(() => _width = v / 100),
                      fmt: (v) => '${v.round()}'),
                    const SizedBox(height: 4),
                    _sectionLabel('Exibição'),
                    Row(children: [
                      _toggle('Girar',  _autoRot,
                        () => setState(() => _autoRot   = !_autoRot)),
                      const SizedBox(width: 8),
                      _toggle('Cesto',  _showCesto,
                        () => setState(() => _showCesto = !_showCesto)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      _toggle('Piso',    _showFloor,
                        () => setState(() => _showFloor = !_showFloor)),
                      const SizedBox(width: 8),
                      _toggle('Aramado', _wireframe,
                        () => setState(() => _wireframe = !_wireframe)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      _toggle('Ganchos +', _intercalados,
                        () => setState(() => _intercalados = !_intercalados)),
                    ]),
                    const SizedBox(height: 14),
                    const Divider(color: _line),
                    const SizedBox(height: 10),
                    Text.rich(TextSpan(
                      style: const TextStyle(fontSize: 12,
                          color: _txtDim, height: 1.8),
                      children: [
                        const TextSpan(text: 'MagnoJet',
                            style: TextStyle(
                                color: _txt, fontWeight: FontWeight.bold)),
                        TextSpan(
                            text: ' · ${_geo.colunasPorLinha} × $_linhas ganchos'
                                '${_intercalados ? " (com intercalados)" : ""}\n'),
                        const TextSpan(text: 'Painel canaletado · '),
                        const TextSpan(text: '1 produto/gancho',
                            style: TextStyle(
                                color: _txt, fontWeight: FontWeight.bold)),
                        const TextSpan(
                            text: '\nSacolinhas empilhadas no pino de arame'),
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

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorNellorePage — modelo 3D interativo do Expositor Nellore
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorNellorePage extends StatefulWidget {
  const ExpositorNellorePage({super.key});

  @override
  State<ExpositorNellorePage> createState() => _ExpositorNellorePageState();
}

class _ExpositorNellorePageState extends State<ExpositorNellorePage> {
  double _height     = 2.05;
  double _width      = 1.10;
  bool   _autoRot    = true;
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

  ExpositorNelloreGeometry get _geo => ExpositorNelloreGeometry(
    height:    _height,
    width:     _width,
    showFloor: _showFloor,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: ExpositorNelloreScene(
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
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text('Expositor',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          letterSpacing: 2, color: _txtDim)),
                    const SizedBox(height: 2),
                    Text.rich(TextSpan(
                      style: const TextStyle(fontSize: 22,
                          fontWeight: FontWeight.bold, color: _txt),
                      children: const [
                        TextSpan(text: 'Nellore Isoflex · '),
                        TextSpan(text: 'Avant',
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
                    _slider('Altura (cm)', _height * 100, 160, 240, 2,
                      (v) => setState(() => _height = v / 100),
                      fmt: (v) => '${v.round()}'),
                    _slider('Largura (cm)', _width * 100, 80, 140, 2,
                      (v) => setState(() => _width = v / 100),
                      fmt: (v) => '${v.round()}'),
                    const SizedBox(height: 4),
                    _sectionLabel('Exibição'),
                    Row(children: [
                      _toggle('Girar', _autoRot,
                        () => setState(() => _autoRot   = !_autoRot)),
                      const SizedBox(width: 8),
                      _toggle('Piso',  _showFloor,
                        () => setState(() => _showFloor = !_showFloor)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      _toggle('Aramado', _wireframe,
                        () => setState(() => _wireframe = !_wireframe)),
                    ]),
                    const SizedBox(height: 14),
                    const Divider(color: _line),
                    const SizedBox(height: 10),
                    const Text.rich(TextSpan(
                      style: TextStyle(fontSize: 12,
                          color: _txtDim, height: 1.8),
                      children: [
                        TextSpan(text: 'Nellore Isoflex / Avant',
                            style: TextStyle(
                                color: _txt, fontWeight: FontWeight.bold)),
                        TextSpan(text: ' · 6 níveis · 28 endereços\n'),
                        TextSpan(text: '2 fileiras de 5 ganchos · 4 cestos\n'),
                        TextSpan(text: '2 prateleiras de 5 · base com deck'),
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

// ─────────────────────────────────────────────────────────────────────────────
// ExpositorMonitorPage — modelo 3D interativo do Expositor Monitor
// ─────────────────────────────────────────────────────────────────────────────

class ExpositorMonitorPage extends StatefulWidget {
  const ExpositorMonitorPage({super.key});

  @override
  State<ExpositorMonitorPage> createState() => _ExpositorMonitorPageState();
}

class _ExpositorMonitorPageState extends State<ExpositorMonitorPage> {
  double _height     = 1.52;
  double _width      = 1.14;
  bool   _autoRot    = true;
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

  ExpositorMonitorGeometry get _geo => ExpositorMonitorGeometry(
    height:    _height,
    width:     _width,
    showFloor: _showFloor,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: ExpositorMonitorScene(
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
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text('Expositor',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          letterSpacing: 2, color: _txtDim)),
                    const SizedBox(height: 2),
                    Text.rich(TextSpan(
                      style: const TextStyle(fontSize: 22,
                          fontWeight: FontWeight.bold, color: _txt),
                      children: const [
                        TextSpan(text: 'Monitor · '),
                        TextSpan(text: 'Produtos Agropecuários',
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
                    _slider('Altura (cm)', _height * 100, 120, 200, 2,
                      (v) => setState(() => _height = v / 100),
                      fmt: (v) => '${v.round()}'),
                    _slider('Largura (cm)', _width * 100, 90, 140, 2,
                      (v) => setState(() => _width = v / 100),
                      fmt: (v) => '${v.round()}'),
                    const SizedBox(height: 4),
                    _sectionLabel('Exibição'),
                    Row(children: [
                      _toggle('Girar', _autoRot,
                        () => setState(() => _autoRot   = !_autoRot)),
                      const SizedBox(width: 8),
                      _toggle('Piso',  _showFloor,
                        () => setState(() => _showFloor = !_showFloor)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      _toggle('Aramado', _wireframe,
                        () => setState(() => _wireframe = !_wireframe)),
                    ]),
                    const SizedBox(height: 14),
                    const Divider(color: _line),
                    const SizedBox(height: 10),
                    const Text.rich(TextSpan(
                      style: TextStyle(fontSize: 12,
                          color: _txtDim, height: 1.8),
                      children: [
                        TextSpan(text: 'Monitor Produtos Agropecuários',
                            style: TextStyle(
                                color: _txt, fontWeight: FontWeight.bold)),
                        TextSpan(text: ' · 4 níveis · 20 endereços\n'),
                        TextSpan(text: '3 prateleiras de 5 · base com deck\n'),
                        TextSpan(text: 'Profundidade crescente de cima pra baixo'),
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
