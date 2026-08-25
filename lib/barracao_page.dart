import 'dart:async';

import 'package:flutter/material.dart';

import 'barracao_config.dart';
import 'barracao_scene.dart' show BarracaoScene, corCamdaBarracao;
import 'barracao_service.dart';
import 'galpao_page.dart'
    show LancamentoRecente, PainelEnderecoGalpao;
import 'galpao_scene.dart' show RackGalpao, ToqueGalpao;
import 'models.dart' show Produto, pluralizar;
import 'turso_service.dart';

/// Mapa 3D do BARRACÃO da CAMDA.
///
/// O fluxo de uso é o MESMO do galpão — tocar um endereço, buscar o produto
/// pelo nome/código, atribuir e corrigir a quantidade —, e por isso o painel
/// inferior é literalmente o do galpão ([PainelEnderecoGalpao]), com os
/// rótulos do barracão. O que muda é só a forma do endereço: aqui o palete É o
/// endereço e leva um produto só, então não há pilha, nível nem renumeração.
///
/// A ponte entre os dois é a dupla [ToqueGalpao]/[RackGalpao]: cada endereço
/// do barracão vira uma "posição" de um nível só (`ordem: 1`), o que deixa o
/// painel funcionar sem saber de qual prédio o endereço veio. É a costura mais
/// barata que existia: a alternativa era um painel paralelo — a mesma tela
/// mantida em dois lugares, que é exatamente o que não se quer.
class BarracaoPage extends StatefulWidget {
  /// Endereços e catálogo iniciais. Quando informados, a página NÃO consulta o
  /// banco — é a costura dos testes e do uso offline. Null = carrega tudo do
  /// Turso e grava lá as mudanças.
  final List<EnderecoBarracao>? enderecosIniciais;
  final List<Produto>?          catalogoInicial;

  /// Código do produto que veio da busca: TODOS os paletes dele acendem em
  /// laranja.
  final String? codigoDestacado;

  const BarracaoPage({
    super.key,
    this.enderecosIniciais,
    this.catalogoInicial,
    this.codigoDestacado,
  });

  @override
  State<BarracaoPage> createState() => _BarracaoPageState();
}

class _BarracaoPageState extends State<BarracaoPage> {
  /// A lista é SUBSTITUÍDA, nunca editada no lugar: a cena memoiza as faces
  /// por identidade da lista (ver BarracaoGeometry.buildFaces), e mutá-la
  /// deixaria o desenho preso no quadro anterior.
  List<EnderecoBarracao> _enderecos = const [];

  List<Produto>      _catalogo           = const [];
  Map<String, Color> _corPorProduto      = const {};
  bool               _carregandoCatalogo = false;
  bool               _carregandoEnderecos = false;

  final List<LancamentoRecente> _recentes = [];
  static const int _maxRecentes = 4;

  /// Endereço aberto no painel (id da linha), ou null sem seleção.
  int? _selecionadoId;

  /// Produto aceso no barracão inteiro (busca ou o botão do painel).
  String? _destacadoCodigo;

  /// True quando a página fala com o banco. Com endereços semeados por
  /// parâmetro (testes, uso offline) tudo fica em memória.
  bool get _persistindo => widget.enderecosIniciais == null;

  @override
  void initState() {
    super.initState();
    // Código vazio (endereço gravado sem código) não destaca nada — senão o
    // destaque casaria com todos os paletes livres.
    final destaque = widget.codigoDestacado;
    _destacadoCodigo =
        destaque != null && destaque.isNotEmpty ? destaque : null;

    final sementeEnderecos = widget.enderecosIniciais;
    if (sementeEnderecos != null) {
      _enderecos = List.unmodifiable(sementeEnderecos);
    } else {
      unawaited(_carregarEnderecos());
    }

    final sementeCatalogo = widget.catalogoInicial;
    if (sementeCatalogo != null) {
      _aplicarCatalogo(sementeCatalogo);
    } else {
      unawaited(_carregarCatalogo());
    }

    // Uma sincronização traz paletes endereçados em outro aparelho — o mesmo
    // gancho que as outras telas usam para se atualizar sem reabrir.
    TursoService().dataRevision.addListener(_aoAtualizarDados);
  }

  @override
  void dispose() {
    TursoService().dataRevision.removeListener(_aoAtualizarDados);
    super.dispose();
  }

  void _aoAtualizarDados() {
    if (!mounted || !_persistindo) return;
    unawaited(_carregarEnderecos());
    unawaited(_carregarCatalogo());
  }

  Future<void> _carregarEnderecos() async {
    setState(() => _carregandoEnderecos = true);
    await BarracaoService().garantirSeed();
    final enderecos = await BarracaoService().carregarEnderecos();
    if (!mounted) return;
    setState(() {
      _enderecos = List.unmodifiable(enderecos);
      _carregandoEnderecos = false;
      // Endereço aberto que sumiu do cadastro (palete retirado em outro
      // aparelho) não pode continuar com o painel em pé: ele mostraria um
      // lugar que não existe mais no chão.
      if (_selecionadoId != null && _porId(_selecionadoId!) == null) {
        _selecionadoId = null;
      }
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

  EnderecoBarracao? _porId(int id) {
    for (final e in _enderecos) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Troca UM endereço, devolvendo uma lista nova (ver a nota em
  /// [_enderecos]).
  void _substituir(EnderecoBarracao novo) {
    _enderecos = List.unmodifiable([
      for (final e in _enderecos) e.id == novo.id ? novo : e,
    ]);
  }

  // ── Gravação ───────────────────────────────────────────────────────────────

  /// Grava um produto e uma quantidade no palete.
  ///
  /// Escreve na tela primeiro e no banco em seguida (UI otimista), como o
  /// galpão: o barracão é usado em pé, com carga chegando, e esperar a ida ao
  /// banco a cada palete travaria o ritmo. Se a gravação falhar, o estado
  /// local volta atrás e o aviso é explícito — nunca fica um palete
  /// "endereçado" só na tela.
  Future<void> _gravar(
    int id, {
    required String codigo,
    required String nome,
    required double quantidade,
  }) async {
    final antes = _porId(id);
    if (antes == null) return;

    setState(() => _substituir(antes.comProduto(
          produtoCodigo: codigo,
          produtoNome:   nome,
          quantidade:    quantidade,
        )));
    if (!_persistindo) return;

    final gravado = await BarracaoService().atribuir(
      id:            id,
      produtoCodigo: codigo,
      produtoNome:   nome,
      quantidade:    quantidade,
    );
    if (!mounted) return;
    if (gravado == null) {
      setState(() => _substituir(antes));
      _avisar('Não deu para gravar no banco — confira a conexão em ⚙️.');
    } else {
      setState(() => _substituir(gravado));
    }
  }

  /// Lança um produto num palete livre.
  ///
  /// O painel fecha: no fluxo de carga o próximo gesto é tocar o próximo
  /// palete, e o produto recém-lançado fica nos últimos lançados — o atalho
  /// de quando chega carga e o mesmo produto vai para vários endereços
  /// seguidos.
  Future<void> _lancar(int id, Produto produto, double quantidade) async {
    setState(() {
      _recentes.removeWhere((r) => r.produto.codigo == produto.codigo);
      _recentes.insert(
          0, LancamentoRecente(produto: produto, quantidade: quantidade));
      if (_recentes.length > _maxRecentes) _recentes.removeLast();
      _selecionadoId = null;
    });
    await _gravar(id,
        codigo: produto.codigo, nome: produto.nome, quantidade: quantidade);
  }

  /// Corrige a quantidade de um palete que já tem produto — mesmo palete,
  /// mesmo produto, número novo. É a mesma gravação do lançamento (no
  /// barracão não existe empilhar por cima: o palete tem um produto e um
  /// número, e mudar qualquer um dos dois é reescrever a linha).
  ///
  /// Ao contrário de [_lancar], NÃO mexe nos últimos lançados nem fecha o
  /// painel: corrigir uma contagem não é distribuir carga, e quem acabou de
  /// corrigir quer ver o número novo no lugar.
  Future<void> _ajustar(int id, double quantidade) async {
    final atual = _porId(id);
    if (atual == null || !atual.ocupado || quantidade <= 0) return;
    if (quantidade == atual.quantidade) return;
    await _gravar(id,
        codigo:     atual.produtoCodigo,
        nome:       atual.produtoNome,
        quantidade: quantidade);
  }

  Future<void> _esvaziar(int id) async {
    final antes = _porId(id);
    if (antes == null) return;
    setState(() {
      _substituir(antes.vazio);
      _selecionadoId = null;
    });
    if (!_persistindo) return;

    final gravado = await BarracaoService().esvaziar(id: id);
    if (!mounted) return;
    if (gravado == null) {
      setState(() => _substituir(antes));
      _avisar('Não deu para esvaziar no banco — confira a conexão em ⚙️.');
    } else {
      setState(() => _substituir(gravado));
    }
  }

  // ── Destaque ───────────────────────────────────────────────────────────────

  void _alternarDestaque(String codigo) {
    setState(() =>
        _destacadoCodigo = _destacadoCodigo == codigo ? null : codigo);
  }

  int get _ocupados =>
      _enderecos.where((e) => e.ocupado).length;

  int get _livres => _enderecos.length - _ocupados;

  void _avisar(String mensagem) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(mensagem),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── Costura com o painel do galpão ─────────────────────────────────────────

  /// O endereço aberto, traduzido para o vocabulário do painel: uma posição de
  /// um nível só. Ver a nota na doc da classe.
  ToqueGalpao? get _toque {
    final id = _selecionadoId;
    if (id == null) return null;
    final e = _porId(id);
    if (e == null) return null;
    return ToqueGalpao(posicao: e.id, ordem: 1, ocupado: e.ocupado);
  }

  /// Os endereços ocupados como "pilhas" de um rack — é o que o painel lê para
  /// achar o produto do endereço aberto E para contar em quantos paletes o
  /// produto está (o botão de destaque).
  ///
  /// Recalculado a cada build de propósito: são ~100 entradas, e um mapa
  /// guardado em campo teria de ser invalidado em toda gravação.
  Map<int, List<RackGalpao>> get _pilhas => {
        for (final e in _enderecos)
          if (e.ocupado)
            e.id: [
              RackGalpao(
                posicao:       e.id,
                ordem:         1,
                produtoCodigo: e.produtoCodigo,
                produtoNome:   e.produtoNome,
                quantidade:    e.quantidade,
              ),
            ],
      };

  @override
  Widget build(BuildContext context) {
    final toque = _toque;
    final aberto = toque == null ? null : _porId(toque.posicao);

    return Scaffold(
      backgroundColor: const Color(0xFF0b0c0e),
      body: Stack(
        children: [
          BarracaoScene(
            enderecos:       _enderecos,
            corPorProduto:   _corPorProduto,
            selecionadoId:   _selecionadoId,
            destacadoCodigo: _destacadoCodigo,
            onTapEndereco: (e) =>
                setState(() => _selecionadoId = e?.id),
          ),

          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BotaoVoltar(
                        onTap: () => Navigator.of(context).maybePop()),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Barracão',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:      Colors.white,
                              fontSize:   15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _carregandoEnderecos
                                ? 'Carregando endereços…'
                                : '${pluralizar(_livres, 'palete livre',
                                    'paletes livres')} de '
                                  '${_enderecos.length}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:    Colors.white.withValues(alpha: 0.45),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (_destacadoCodigo != null)
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 68, 12, 0),
                  child: _FaixaDestaqueBarracao(
                    nome:     _nomeDestacado,
                    paletes:  _paletesComDestaque,
                    onLimpar: () =>
                        setState(() => _destacadoCodigo = null),
                  ),
                ),
              ),
            ),

          if (toque != null && aberto != null)
            Positioned(
              left: 16, right: 16, bottom: 16,
              child: SafeArea(
                top: false,
                child: PainelEnderecoGalpao(
                  // A key troca o estado interno (busca, quantidade) ao mudar
                  // de endereço — resto de digitação de um endereço não pode
                  // vazar para o outro.
                  key: ValueKey('bar-${aberto.id}-${aberto.ocupado}'),
                  toque:              toque,
                  pilhas:             _pilhas,
                  catalogo:           _catalogo,
                  recentes:           _recentes,
                  carregandoCatalogo: _carregandoCatalogo,
                  destacadoCodigo:    _destacadoCodigo,
                  onAlternarDestaque: _alternarDestaque,
                  rotuloEndereco:     aberto.rotulo,
                  subtitulo:          _subtituloDoEndereco(aberto),
                  textoVagaLivre:
                      'Palete livre — o produto lançado aqui fica neste '
                      'endereço, sozinho.',
                  onFechar: () => setState(() => _selecionadoId = null),
                  onLancar: (produto, quantidade) =>
                      _lancar(aberto.id, produto, quantidade),
                  onEsvaziar:          () => _esvaziar(aberto.id),
                  onAjustarQuantidade: (quantidade) =>
                      _ajustar(aberto.id, quantidade),
                ),
              ),
            )
          else
            Positioned(
              left: 16, right: 16, bottom: 20,
              // IgnorePointer: o parágrafo aceita hit na caixa inteira, e sem
              // isso a dica roubava o toque dos paletes desenhados perto do
              // rodapé (a fileira mais próxima da câmera).
              child: IgnorePointer(
                child: SafeArea(
                  top: false,
                  child: Text(
                    'Toque num palete para ver o endereço. '
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

  /// A linha cinza ao lado do rótulo: onde o palete está na planta. Fileira 1
  /// é a encostada na parede do fundo — o mesmo sentido em que os endereços
  /// são numerados.
  String _subtituloDoEndereco(EnderecoBarracao e) {
    final fileira =
        ((BarracaoConfig.interiorZ1 - BarracaoConfig.paleteZ / 2 - e.z) /
                BarracaoConfig.passoZ)
            .round();
    return 'Fileira ${fileira + 1} · a ${(e.z / 100).toStringAsFixed(1)} m '
        'da parede das aberturas';
  }

  /// Nome do produto destacado, lido dos próprios endereços (o catálogo pode
  /// ainda estar carregando). Cai no código quando o palete foi gravado sem
  /// nome.
  String get _nomeDestacado {
    final codigo = _destacadoCodigo;
    if (codigo == null) return '';
    for (final e in _enderecos) {
      if (e.produtoCodigo == codigo && e.produtoNome.isNotEmpty) {
        return e.produtoNome;
      }
    }
    return codigo;
  }

  int get _paletesComDestaque {
    final codigo = _destacadoCodigo;
    if (codigo == null) return 0;
    return _enderecos.where((e) => e.produtoCodigo == codigo).length;
  }
}

// ── Faixa do produto destacado ───────────────────────────────────────────────

/// Gêmea da faixa do galpão: diz o que está aceso no mapa e como apagar.
class _FaixaDestaqueBarracao extends StatelessWidget {
  final String       nome;
  final int          paletes;
  final VoidCallback onLimpar;

  const _FaixaDestaqueBarracao({
    required this.nome,
    required this.paletes,
    required this.onLimpar,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
      decoration: BoxDecoration(
        color:        corCamdaBarracao.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: corCamdaBarracao.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lightbulb, size: 14, color: corCamdaBarracao),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  nome,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color:      Colors.white,
                    fontSize:   12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  paletes == 0
                      ? 'nenhum palete no barracão'
                      : 'em ${pluralizar(paletes, 'palete')}',
                  style: const TextStyle(
                      color: corCamdaBarracao, fontSize: 11),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onLimpar,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.close, size: 16, color: Color(0xFF8a9aa8)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Botão de voltar ──────────────────────────────────────────────────────────

class _BotaoVoltar extends StatelessWidget {
  final VoidCallback onTap;

  const _BotaoVoltar({required this.onTap});

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
        child: const Icon(Icons.arrow_back,
            color: Color(0xFF8a877f), size: 20),
      ),
    );
  }
}
