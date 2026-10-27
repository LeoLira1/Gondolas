import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'barracao_busca.dart';
import 'estocados_busca.dart';
import 'estocados_sheet.dart';
import 'barracao_config.dart';
import 'barracao_scene.dart'
    show BarracaoScene, ToqueBarracao, corCamdaBarracao;
import 'barracao_service.dart';
import 'fila_gravacao.dart';
import 'fila_gravacao_ui.dart';
import 'gravacao_lote.dart';
import 'galpao_page.dart'
    show LancamentoRecente, PainelEnderecoGalpao;
import 'galpao_scene.dart' show RackGalpao, ToqueGalpao;
import 'modo_conferencia_service.dart';
import 'models.dart' show Produto, corConferenciaCiano, pluralizar;
import 'outbox.dart' show gerarUuidV4;
import 'turso_service.dart';

/// Mapa 3D do BARRACÃO da CAMDA.
///
/// O fluxo de uso é o MESMO do galpão — tocar um endereço, buscar o produto
/// pelo nome/código, atribuir e corrigir a quantidade —, e por isso o painel
/// inferior é literalmente o do galpão ([PainelEnderecoGalpao]), com os
/// rótulos do barracão. E como no galpão, cada endereço leva uma PILHA de até
/// [BarracaoConfig.gaiolasMax] gaiolas: a nova entra no topo, e tirar uma de
/// qualquer nível faz as de cima descerem.
///
/// A ponte entre os dois é a dupla [ToqueGalpao]/[RackGalpao]: cada endereço
/// do barracão vira uma "posição" e cada gaiola um "rack" com `ordem` igual ao
/// nível, o que deixa o painel funcionar sem saber de qual prédio o endereço
/// veio. É a costura mais
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
  final int? enderecoInicialId;
  final bool conferenciaAoAbrir;
  final ModoConferenciaResultado? conferenciaInicial;

  const BarracaoPage({
    super.key,
    this.enderecosIniciais,
    this.catalogoInicial,
    this.codigoDestacado,
    this.enderecoInicialId,
    this.conferenciaAoAbrir = false,
    this.conferenciaInicial,
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

  /// Busca de paletes (onde está o produto X). Os resultados saem da lista de
  /// endereços em memória; ver barracao_busca.dart.
  final _buscaCtrl = TextEditingController();
  List<ResultadoBuscaBarracao> _resultadosBusca = const [];

  final List<LancamentoRecente> _recentes = [];
  static const int _maxRecentes = 4;

  /// Endereço aberto no painel (id da linha), ou null sem seleção.
  int? _selecionadoId;

  /// Nível aberto na pilha do endereço selecionado (1 = a gaiola do chão).
  /// Pode ser o próximo nível livre: é a vaga em que se vai empilhar.
  int _selecionadoNivel = 1;

  /// Produto aceso no barracão inteiro (busca ou o botão do painel).
  String? _destacadoCodigo;
  bool _modoConferencia = false;
  bool _carregandoConferencia = false;
  ModoConferenciaResultado? _conferencia;

  /// True quando a página fala com o banco. Com endereços semeados por
  /// parâmetro (testes, uso offline) tudo fica em memória.
  bool get _persistindo => widget.enderecosIniciais == null;
  bool get _consultandoConferencia => widget.conferenciaInicial == null;

  @override
  void initState() {
    super.initState();
    unawaited(_carregarEstocados());
    // Código vazio (endereço gravado sem código) não destaca nada — senão o
    // destaque casaria com todos os paletes livres.
    final destaque = widget.codigoDestacado;
    _destacadoCodigo =
        destaque != null && destaque.isNotEmpty ? destaque : null;

    final sementeEnderecos = widget.enderecosIniciais;
    if (sementeEnderecos != null) {
      _enderecos = List.unmodifiable(sementeEnderecos);
      if (widget.enderecoInicialId != null &&
          _porId(widget.enderecoInicialId!) != null) {
        _abrir(widget.enderecoInicialId!);
      }
    } else {
      // Antes da leitura: o que ficou na fila entra por cima do banco.
      _fila.addListener(_aoMudarFila);
      _eventosFila = _fila.eventos.listen(_aoEventoFila);
      _filaTinhaPendentes = _temPendentesBarracao;
      unawaited(_fila.carregar().then((_) {
        if (mounted) unawaited(_carregarEnderecos());
      }));
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
    _conferencia = widget.conferenciaInicial;
    if (widget.conferenciaAoAbrir) {
      _modoConferencia = true;
      if (_consultandoConferencia) unawaited(_carregarConferencia());
    }
  }

  @override
  void dispose() {
    TursoService().dataRevision.removeListener(_aoAtualizarDados);
    if (_persistindo) _fila.removeListener(_aoMudarFila);
    unawaited(_eventosFila?.cancel());
    _recargaAposFila?.cancel();
    _recargaPorAviso?.cancel();
    _buscaCtrl.dispose();
    super.dispose();
  }

  // Os avisos de dados novos chegam em rajada (uma volta ao app relê várias
  // consultas); um respiro junta todos numa recarga só — o mesmo do galpão.
  Timer? _recargaPorAviso;

  void _aoAtualizarDados() {
    if (!mounted || !_persistindo) return;
    _recargaPorAviso?.cancel();
    _recargaPorAviso = Timer(
      const Duration(milliseconds: 800),
      _recarregarPorAviso,
    );
  }

  void _recarregarPorAviso() {
    if (!mounted) return;
    unawaited(_carregarEnderecos());
    unawaited(_carregarCatalogo());
    unawaited(_carregarEstocados());
    if (_modoConferencia && _consultandoConferencia) {
      unawaited(_carregarConferencia());
    }
  }

  Future<void> _carregarEnderecos() async {
    final versao = _versaoEnderecos;
    setState(() => _carregandoEnderecos = true);
    // Lê primeiro (cópia local responde na hora); o seed só entra quando o
    // cadastro está vazio, que é o único caso em que há o que semear.
    var enderecos = await BarracaoService().carregarEnderecos();
    if (enderecos.isEmpty && await BarracaoService().garantirSeed()) {
      enderecos = await BarracaoService().carregarEnderecos();
    }
    if (!mounted) return;
    if (versao != _versaoEnderecos) {
      // Gravação confirmada no meio da leitura (ver galpão): a recarga do fim
      // da fila traz o estado certo.
      setState(() => _carregandoEnderecos = false);
      return;
    }
    _aplicarEnderecosDoBanco(enderecos);
  }

  /// O banco + o que ainda está na fila, por cima.
  void _aplicarEnderecosDoBanco(List<EnderecoBarracao> doBanco) {
    final enderecos = aplicarPendentesBarracao(doBanco, _fila.pendentes);
    setState(() {
      _enderecos = List.unmodifiable(enderecos);
      _carregandoEnderecos = false;
      _resultadosBusca = buscarPaletesBarracao(_buscaCtrl.text, _enderecos);
      // Endereço aberto que sumiu do cadastro (palete retirado em outro
      // aparelho) não pode continuar com o painel em pé: ele mostraria um
      // lugar que não existe mais no chão.
      if (_selecionadoId != null && _porId(_selecionadoId!) == null) {
        _selecionadoId = null;
      }
      final inicial = widget.enderecoInicialId;
      if (_selecionadoId == null && inicial != null && _porId(inicial) != null) {
        _abrir(inicial);
      }
    });
    _baixarEstocadosEntregues();
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

  /// Estocados (material de cooperado) como produtos lançáveis. Entram na
  /// busca do painel do endereço e no mapa, mas NÃO no saldo (ver
  /// `prefixoEstocado`).
  List<Produto> _estocados = const [];

  void _aplicarCatalogo(List<Produto> produtos) {
    final base = produtos.where((p) => !codigoEhEstocado(p.codigo));
    _catalogo = [...base, ..._estocados];
    _corPorProduto = {for (final p in _catalogo) p.codigo: p.cor};
  }

  Future<void> _carregarEstocados() async {
    try {
      final itens = await carregarEstocados();
      if (!mounted) return;
      setState(() {
        _itensEstocados = itens;
        _estocados = itens.map(produtoDeEstocado).toList();
        _aplicarCatalogo(_catalogo);
      });
      _baixarEstocadosEntregues();
    } catch (_) {
      // Sem a lista, o painel segue com o catálogo da loja — e sem baixa
      // automática: sem saber o saldo, nenhum palete sai.
    }
  }

  /// Abre o endereço [id] no painel, no nível do produto destacado (quem
  /// chegou pela busca quer ver a gaiola dele) ou no topo da pilha.
  void _abrir(int id) {
    final e = _porId(id);
    if (e == null) return;
    final chave = _destacadoCodigo;
    var nivel = math.max(e.niveis, 1);
    if (chave != null) {
      for (final g in e.gaiolas) {
        if (chaveDestaque(g.codigo, g.nome) == chave) {
          nivel = g.nivel;
          break;
        }
      }
    }
    _selecionadoId = id;
    _selecionadoNivel = nivel;
  }

  /// A lista de `materiais_terceiros` (saldo > 0). Null até a primeira
  /// leitura dar certo.
  List<ItemEstocado>? _itensEstocados;

  /// Baixa automática do estocado entregue (ver o galpão): palete "EST:" cujo
  /// item saiu da lista é esvaziado sozinho, como no "Esvaziar" do painel.
  void _baixarEstocadosEntregues() {
    final itens = _itensEstocados;
    if (!_persistindo || itens == null || _carregandoEnderecos) return;
    // Um por nível: no barracão a pilha tem gaiolas, cada uma com o seu produto.
    final niveis = [
      for (final e in _enderecos)
        for (final g in e.gaiolas)
          (id: e.id, rotulo: e.rotulo, nivel: g.nivel, codigo: g.codigo, nome: g.nome),
    ];
    final entregues = paletesEstocadosEntregues(
      comSaldo: itens,
      paletes: niveis,
      codigo: (g) => g.codigo,
      nome: (g) => g.nome,
    )
      // De cima para baixo: esvaziar um nível desce os de cima, e o nível dos
      // de baixo continua valendo.
      ..sort((a, b) => b.nivel.compareTo(a.nivel));
    if (entregues.isEmpty) return;
    for (final g in entregues) {
      _esvaziar(g.id, g.nivel);
    }
    _avisar(avisoBaixaEstocados([
      for (final g in entregues.reversed)
        (
          nome: g.nome.isEmpty ? g.codigo : g.nome,
          endereco: g.nivel == 1 ? g.rotulo : '${g.rotulo} · N${g.nivel}',
        ),
    ]));
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
  //
  // Como no galpão: aplica na tela e põe na FilaGravacao, que leva ao banco em
  // UMA requisição por palete e reenvia sozinha se a rede falhar. Só o que o
  // banco recusa de verdade volta atrás, com aviso.

  final FilaGravacao _fila = FilaGravacao();
  StreamSubscription<EventoFila>? _eventosFila;
  bool _filaTinhaPendentes = false;
  Timer? _recargaAposFila;

  /// Muda quando uma gravação do barracão é confirmada — leitura iniciada
  /// antes disso é descartada.
  int _versaoEnderecos = 0;

  static bool _doBarracao(OperacaoPendente op) => op.tipo.doBarracao;

  bool get _temPendentesBarracao => _fila.pendentes.any(_doBarracao);

  void _aoMudarFila() {
    if (!mounted) return;
    final tem = _temPendentesBarracao;
    if (_filaTinhaPendentes && !tem) {
      _recargaAposFila?.cancel();
      _recargaAposFila = Timer(
        const Duration(milliseconds: 800),
        () => unawaited(_recarregarDoBanco()),
      );
    }
    _filaTinhaPendentes = tem;
    setState(() {});
  }

  void _aoEventoFila(EventoFila evento) {
    if (!mounted || !_doBarracao(evento.operacao)) return;
    _versaoEnderecos++;
    if (evento.gravada) return;
    _avisar(mensagemFalhaFila(evento));
    unawaited(_recarregarDoBanco());
  }

  Future<void> _recarregarDoBanco() async {
    final versao = _versaoEnderecos;
    final enderecos = await BarracaoService().recarregarEnderecos();
    if (!mounted || enderecos == null || versao != _versaoEnderecos) return;
    _aplicarEnderecosDoBanco(enderecos);
  }

  /// Põe a gravação na fila (na tela ela já foi aplicada por quem chama).
  void _enfileirar(
    EnderecoBarracao antes,
    TipoOperacao tipo, {
    String? uuid,
    String? gaiolaUuid,
    String codigo = '',
    String nome = '',
    double quantidade = 0,
    double? quantidadeAnterior,
    int nivel = 1,
  }) {
    if (!_persistindo) return;
    unawaited(_fila.enfileirar(OperacaoPendente(
      uuid:          uuid ?? gerarUuidV4(),
      tipo:          tipo,
      banco:         TursoService().identidadeAtiva ?? '',
      criadaEm:      DateTime.now(),
      local:         antes.id,
      rackUuid:      gaiolaUuid,
      produtoCodigo: codigo,
      produtoNome:   nome,
      quantidade:    quantidade,
      quantidadeAnterior: quantidadeAnterior,
      rotulo:        nivel > 1 ? '${antes.rotulo} · N$nivel' : antes.rotulo,
    )));
  }

  /// Lança um produto na vaga aberta: no chão de um palete livre, ou numa
  /// gaiola nova no TOPO da pilha.
  ///
  /// O painel fecha: no fluxo de carga o próximo gesto é tocar o próximo
  /// palete, e o produto recém-lançado fica nos últimos lançados — o atalho
  /// de quando chega carga e o mesmo produto vai para vários endereços
  /// seguidos.
  void _lancar(int id, Produto produto, double quantidade) {
    final antes = _porId(id);
    if (antes == null) return;
    // O UUID nasce aqui: é ele que o lote grava em gaiola_uuid, e é com ele
    // que um ajuste feito logo depois, ainda offline, acha a gaiola certa.
    final uuid = gerarUuidV4();
    final depois = antes.comGaiolaNoTopo(
      gaiolaUuid:    uuid,
      produtoCodigo: produto.codigo,
      produtoNome:   produto.nome,
      quantidade:    quantidade,
    );
    if (depois == null) return; // pilha cheia — a tela não oferece vaga
    setState(() {
      _recentes.removeWhere((r) => r.produto.codigo == produto.codigo);
      _recentes.insert(
          0, LancamentoRecente(produto: produto, quantidade: quantidade));
      if (_recentes.length > _maxRecentes) _recentes.removeLast();
      _selecionadoId = null;
      _substituir(depois);
    });
    _enfileirar(
      antes,
      antes.ocupado
          ? TipoOperacao.barracaoEmpilhar
          : TipoOperacao.barracaoAtribuir,
      uuid:       uuid,
      codigo:     produto.codigo,
      nome:       produto.nome,
      quantidade: quantidade,
      nivel:      depois.niveis,
    );
  }

  /// Corrige a quantidade de uma gaiola que já está lá — mesma gaiola, mesmo
  /// produto, número novo. Na do chão é a mesma gravação do lançamento (a
  /// linha do endereço é reescrita); numa empilhada, a gaiola é achada pelo
  /// UUID.
  ///
  /// Ao contrário de [_lancar], NÃO mexe nos últimos lançados nem fecha o
  /// painel: corrigir uma contagem não é distribuir carga, e quem acabou de
  /// corrigir quer ver o número novo no lugar.
  void _ajustar(int id, int nivel, double quantidade) {
    final atual = _porId(id);
    if (atual == null || nivel > atual.niveis || quantidade <= 0) return;
    final g = atual.gaiolas[nivel - 1];
    if (quantidade == g.quantidade) return;
    setState(() => _substituir(atual.comQuantidadeNoNivel(nivel, quantidade)));
    _enfileirar(
      atual,
      nivel == 1
          ? TipoOperacao.barracaoAtribuir
          : TipoOperacao.barracaoAjustarGaiola,
      gaiolaUuid:         atual.uuidDoNivel(nivel),
      codigo:             g.codigo,
      nome:               g.nome,
      quantidade:         quantidade,
      quantidadeAnterior: g.quantidade,
      nivel:              nivel,
    );
  }

  /// Tira a gaiola do nível [nivel] e a pilha DESCE: as de cima descem um
  /// nível cada (a do nível 2 vira a do chão quando sai a de baixo).
  void _esvaziar(int id, int nivel) {
    final antes = _porId(id);
    if (antes == null || nivel > antes.niveis) return;
    final g = antes.gaiolas[nivel - 1];
    setState(() {
      _substituir(antes.semNivel(nivel));
      _selecionadoId = null;
    });
    _enfileirar(
      antes,
      nivel == 1
          ? TipoOperacao.barracaoEsvaziar
          : TipoOperacao.barracaoEsvaziarGaiola,
      gaiolaUuid:         antes.uuidDoNivel(nivel),
      codigo:             g.codigo,
      nome:               g.nome,
      quantidadeAnterior: g.quantidade,
      nivel:              nivel,
    );
  }

  // ── Busca de paletes ───────────────────────────────────────────────────────

  void _aoDigitarBusca(String q) {
    setState(() => _resultadosBusca = buscarPaletesBarracao(q, _enderecos));
  }

  /// Escolher um resultado acende o produto em TODOS os paletes dele e abre o
  /// palete escolhido — o mesmo que a busca da loja faz ao chegar aqui.
  void _escolherResultado(ResultadoBuscaBarracao r) {
    FocusScope.of(context).unfocus();
    setState(() {
      _destacadoCodigo  = chaveDestaque(r.produtoCodigo, r.produtoNome);
      _selecionadoId    = r.id;
      _selecionadoNivel = r.nivel;
      _buscaCtrl.clear();
      _resultadosBusca = const [];
    });
  }

  // ── Destaque ───────────────────────────────────────────────────────────────

  void _alternarDestaque(String codigo) {
    setState(() =>
        _destacadoCodigo = _destacadoCodigo == codigo ? null : codigo);
  }

  Future<void> _toggleConferencia() async {
    if (_modoConferencia) {
      setState(() {
        _modoConferencia = false;
        if (_consultandoConferencia) _conferencia = null;
      });
      return;
    }
    setState(() => _modoConferencia = true);
    if (_consultandoConferencia) await _carregarConferencia(forcar: true);
  }

  /// [forcar]: ligar o modo e o botão de atualizar leem o banco na hora; os
  /// outros pedidos (aviso de dados novos, abertura pelo banner) aceitam a
  /// conferência de menos de um minuto que o serviço guarda.
  Future<void> _carregarConferencia({bool forcar = false}) async {
    setState(() => _carregandoConferencia = true);
    final resultado = await ModoConferenciaService().buscarConferenciaDoDia(
      forcar: forcar,
    );
    if (!mounted) return;
    setState(() {
      _conferencia = resultado;
      _carregandoConferencia = false;
    });
  }

  Map<int, int> get _contagemConferencia {
    final r = _conferencia;
    if (!_modoConferencia || r == null) return const {};
    return {for (final p in r.barracao.values) p.posicao: p.itens.length};
  }

  Set<String> get _codigosConferencia {
    final r = _conferencia;
    return !_modoConferencia || r == null ? const {} : r.codigosBarracao;
  }

  int get _ocupados =>
      _enderecos.where((e) => e.ocupado).length;

  int get _livres => _enderecos.length - _ocupados;

  void _avisar(String mensagem) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(mensagem),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
    ));
  }

  // ── Costura com o painel do galpão ─────────────────────────────────────────

  /// Nível aberto no endereço [e], já conferido contra a pilha de agora: a
  /// pilha pode ter descido (gravação de outro aparelho, gaiola tirada) ou
  /// enchido depois do toque. Fica entre 1 e a vaga de cima — ou o topo, se
  /// a pilha está cheia.
  int _nivelAberto(EnderecoBarracao e) {
    final teto = e.cheio ? e.niveis : e.niveis + 1;
    return _selecionadoNivel.clamp(1, math.max(teto, 1));
  }

  /// O endereço aberto, traduzido para o vocabulário do painel: a posição e a
  /// ordem na pilha. Ver a nota na doc da classe.
  ToqueGalpao? get _toque {
    final id = _selecionadoId;
    if (id == null) return null;
    final e = _porId(id);
    if (e == null) return null;
    final nivel = _nivelAberto(e);
    return ToqueGalpao(posicao: e.id, ordem: nivel, ocupado: nivel <= e.niveis);
  }

  /// As pilhas de gaiolas no vocabulário do painel — é o que ele lê para
  /// achar o produto do nível aberto E para contar em quantos paletes o
  /// produto está (o botão de destaque).
  ///
  /// Recalculado a cada build de propósito: são ~100 entradas, e um mapa
  /// guardado em campo teria de ser invalidado em toda gravação.
  Map<int, List<RackGalpao>> get _pilhas => {
        for (final e in _enderecos)
          if (e.ocupado)
            e.id: [
              for (final g in e.gaiolas)
                RackGalpao(
                  rackUuid:      e.uuidDoNivel(g.nivel),
                  posicao:       e.id,
                  ordem:         g.nivel,
                  produtoCodigo: g.codigo,
                  produtoNome:   g.nome,
                  quantidade:    g.quantidade,
                ),
            ],
      };

  @override
  Widget build(BuildContext context) {
    final toque = _toque;
    final aberto = toque == null ? null : _porId(toque.posicao);

    return Scaffold(
      bottomNavigationBar: _persistindo && !_fila.vazia
          ? BarraFilaGravacao(fila: _fila)
          : null,
      backgroundColor: const Color(0xFF0b0c0e),
      body: Stack(
        children: [
          BarracaoScene(
            enderecos:       _enderecos,
            corPorProduto:   _corPorProduto,
            selecionadoId:   _selecionadoId,
            selecionadoNivel: aberto == null ? 1 : _nivelAberto(aberto),
            destacadoCodigo: _modoConferencia ? null : _destacadoCodigo,
            modoConferencia: _modoConferencia,
            codigosConferencia: _codigosConferencia,
            contagemConferencia: _contagemConferencia,
            onTapEndereco: (ToqueBarracao? t) => setState(() {
              _selecionadoId    = t?.endereco.id;
              _selecionadoNivel = t?.nivel ?? 1;
            }),
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
                    _ToggleConferenciaBarracao(
                      ativo: _modoConferencia,
                      onTap: _toggleConferencia,
                    ),
                    const SizedBox(width: 8),
                    const BotaoEstocados(),
                  ],
                ),
              ),
            ),
          ),

          // Com o painel de um palete aberto o campo some: o painel tem o seu
          // próprio (catálogo), e dois campos de busca na tela confundem.
          if (!_modoConferencia && toque == null)
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 68, 12, 0),
                  child: _BuscaPaletesBarracao(
                    controller:  _buscaCtrl,
                    resultados:  _resultadosBusca,
                    onChanged:   _aoDigitarBusca,
                    onEscolher:  _escolherResultado,
                  ),
                ),
              ),
            ),

          if (_destacadoCodigo != null && !_modoConferencia)
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      12, toque == null ? 124 : 68, 12, 0),
                  child: _FaixaDestaqueBarracao(
                    nome:     _nomeDestacado,
                    paletes:  _paletesComDestaque,
                    onLimpar: () =>
                        setState(() => _destacadoCodigo = null),
                  ),
                ),
              ),
            ),

          if (_modoConferencia)
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 68, 12, 0),
                  child: _BannerConferenciaBarracao(
                    carregando: _carregandoConferencia,
                    resultado: _conferencia,
                    onRefresh: _carregandoConferencia || !_consultandoConferencia
                        ? null
                        : () => _carregarConferencia(forcar: true),
                  ),
                ),
              ),
            ),

          if (toque != null && aberto != null)
            Positioned(
              left: 16, right: 16, bottom: 16,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Os níveis da pilha à mão: de cima, a vaga sobre a pilha
                    // fica quase toda atrás da gaiola de baixo, e tocar nela
                    // seria mira de precisão. Palete livre só tem o chão.
                    if (aberto.ocupado) ...[
                      _SeletorNiveis(
                        endereco:   aberto,
                        nivel:      toque.ordem,
                        onEscolher: (n) =>
                            setState(() => _selecionadoNivel = n),
                      ),
                      const SizedBox(height: 8),
                    ],
                    PainelEnderecoGalpao(
                      // A key troca o estado interno (busca, quantidade) ao
                      // mudar de endereço ou de nível — resto de digitação de
                      // uma gaiola não pode vazar para a outra.
                      key: ValueKey(
                          'bar-${aberto.id}-${toque.ordem}-${toque.ocupado}'),
                      toque:              toque,
                      pilhas:             _pilhas,
                      catalogo:           _catalogo,
                      recentes:           _recentes,
                      carregandoCatalogo: _carregandoCatalogo,
                      codigosConferencia: _codigosConferencia,
                      destacadoCodigo:    _destacadoCodigo,
                      onAlternarDestaque:
                          _modoConferencia ? null : _alternarDestaque,
                      rotuloEndereco: toque.ordem > 1
                          ? '${aberto.rotulo} · N${toque.ordem}'
                          : aberto.rotulo,
                      subtitulo:      _subtituloDoEndereco(aberto),
                      textoVagaLivre: toque.ordem == 1
                          ? 'Palete livre — a gaiola lançada aqui fica no '
                            'chão, e as próximas empilham em cima dela (até '
                            '${BarracaoConfig.gaiolasMax}).'
                          : 'Vaga no topo da pilha — a gaiola lançada aqui '
                            'entra no nível ${toque.ordem} de '
                            '${BarracaoConfig.gaiolasMax}.',
                      onFechar: () => setState(() => _selecionadoId = null),
                      onLancar: (produto, quantidade) =>
                          _lancar(aberto.id, produto, quantidade),
                      onEsvaziar: () => _esvaziar(aberto.id, toque.ordem),
                      onAjustarQuantidade: (quantidade) =>
                          _ajustar(aberto.id, toque.ordem, quantidade),
                    ),
                  ],
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
                    _modoConferencia
                        ? 'Paletes em ciano guardam produto para conferir hoje — '
                          'toque num deles para ver o que contar.'
                        : 'Toque num palete para ver o endereço. '
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
    var fileira = 0;
    var menor = double.infinity;
    for (var i = 0; i < BarracaoConfig.fileiras; i++) {
      final d = (BarracaoConfig.zDaFileira(i) - e.z).abs();
      if (d < menor) { menor = d; fileira = i; }
    }
    return 'Fileira ${fileira + 1} · a ${(e.z / 100).toStringAsFixed(1)} m '
        'da parede das aberturas · ${e.niveis} de '
        '${BarracaoConfig.gaiolasMax} na pilha';
  }

  /// Nome do produto destacado, lido dos próprios endereços (o catálogo pode
  /// ainda estar carregando). Cai no código quando o palete foi gravado sem
  /// nome.
  String get _nomeDestacado {
    final codigo = _destacadoCodigo;
    if (codigo == null) return '';
    for (final e in _enderecos) {
      for (final g in e.gaiolas) {
        if (chaveDestaque(g.codigo, g.nome) == codigo && g.nome.isNotEmpty) {
          return g.nome;
        }
      }
    }
    return codigo;
  }

  int get _paletesComDestaque {
    final codigo = _destacadoCodigo;
    if (codigo == null) return 0;
    return _enderecos
        .where((e) =>
            e.gaiolas.any((g) => chaveDestaque(g.codigo, g.nome) == codigo))
        .length;
  }
}

// ── Níveis da pilha ──────────────────────────────────────────────────────────

/// Uma pastilha por gaiola da pilha (N1 = a do chão) e, com vaga, a de
/// empilhar no topo. A aberta fica em laranja.
class _SeletorNiveis extends StatelessWidget {
  final EnderecoBarracao  endereco;
  final int               nivel;
  final ValueChanged<int> onEscolher;

  const _SeletorNiveis({
    required this.endereco,
    required this.nivel,
    required this.onEscolher,
  });

  @override
  Widget build(BuildContext context) {
    final vaga = endereco.cheio ? null : endereco.niveis + 1;
    return Wrap(
      spacing:    6,
      runSpacing: 6,
      children: [
        for (var n = 1; n <= endereco.niveis; n++)
          _pastilha('N$n', n, Icons.inventory_2_outlined),
        if (vaga != null) _pastilha('Empilhar', vaga, Icons.add),
      ],
    );
  }

  Widget _pastilha(String texto, int n, IconData icone) {
    final ativo = n == nivel;
    return GestureDetector(
      onTap: () => onEscolher(n),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: ativo
              ? corCamdaBarracao.withValues(alpha: 0.22)
              : const Color(0xEE141518),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: ativo
                ? corCamdaBarracao
                : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icone,
                size: 14,
                color: ativo ? corCamdaBarracao : const Color(0xFF8a9aa8)),
            const SizedBox(width: 5),
            Text(
              texto,
              style: TextStyle(
                color:      ativo ? Colors.white : const Color(0xFFb8c2cc),
                fontSize:   12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Busca de paletes ─────────────────────────────────────────────────────────

/// Campo + lista de resultados. Cada linha é um PALETE (rótulo, produto e
/// quantidade), porque o mesmo produto costuma estar em vários.
class _BuscaPaletesBarracao extends StatelessWidget {
  final TextEditingController          controller;
  final List<ResultadoBuscaBarracao>         resultados;
  final ValueChanged<String>                 onChanged;
  final ValueChanged<ResultadoBuscaBarracao> onEscolher;

  const _BuscaPaletesBarracao({
    required this.controller,
    required this.resultados,
    required this.onChanged,
    required this.onEscolher,
  });

  @override
  Widget build(BuildContext context) {
    final digitando = controller.text.trim().length >= 2;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 46,
          child: TextField(
            controller: controller,
            onChanged:  onChanged,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Onde está o produto? Nome ou código…',
              hintStyle: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 13),
              prefixIcon: const Icon(Icons.search,
                  size: 18, color: Color(0xFF8a9aa8)),
              filled: true,
              fillColor: const Color(0xEE141518),
              contentPadding: EdgeInsets.zero,
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
            ),
          ),
        ),
        if (resultados.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: const Color(0xF2141518),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final e in resultados)
                  InkWell(
                    onTap: () => onEscolher(e),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
                      child: Row(
                        children: [
                          Text(e.rotulo,
                              style: const TextStyle(
                                color: corCamdaBarracao,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              )),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(e.produtoNome.isEmpty
                                    ? e.produtoCodigo
                                    : e.produtoNome,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12)),
                          ),
                          const SizedBox(width: 8),
                          Text('${e.quantidade % 1 == 0
                                  ? e.quantidade.toInt()
                                  : e.quantidade}',
                              style: const TextStyle(
                                  color: Color(0xFF8a9aa8), fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          )
        else if (digitando)
          const Padding(
            padding: EdgeInsets.only(top: 8, left: 4),
            child: Text('Nenhum palete com esse produto.',
                style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 11)),
          ),
      ],
    );
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

class _ToggleConferenciaBarracao extends StatelessWidget {
  final bool ativo;
  final VoidCallback onTap;
  const _ToggleConferenciaBarracao({required this.ativo, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 46, width: 46,
      decoration: BoxDecoration(
        color: ativo ? corConferenciaCiano.withValues(alpha: 0.18)
            : const Color(0xEE141518),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ativo ? corConferenciaCiano
            : Colors.white.withValues(alpha: 0.10)),
      ),
      child: Icon(ativo ? Icons.fact_check : Icons.fact_check_outlined,
        color: ativo ? corConferenciaCiano : const Color(0xFF8a877f), size: 20),
    ),
  );
}

class _BannerConferenciaBarracao extends StatelessWidget {
  final bool carregando;
  final ModoConferenciaResultado? resultado;
  final VoidCallback? onRefresh;
  const _BannerConferenciaBarracao({required this.carregando,
    required this.resultado, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final r = resultado;
    final vazio = !carregando && (r == null || r.barracaoVazioHoje);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xE60d2226),
        border: Border.all(color: corConferenciaCiano.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(vazio ? Icons.celebration_outlined : Icons.fact_check_outlined,
          color: corConferenciaCiano, size: 15),
        const SizedBox(width: 8),
        Expanded(child: Text(
          carregando ? 'Carregando conferência do dia…'
              : vazio ? 'Nenhum pendente no barracão hoje 🎉'
              : 'Conferência do dia: '
                '${pluralizar(r!.totalProdutosBarracao, 'produto')} em '
                '${pluralizar(r.totalPosicoesBarracao, 'palete')}',
          maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        )),
        if (onRefresh != null) IconButton(
          icon: const Icon(Icons.refresh, size: 16, color: Color(0xFF8a9aa8)),
          onPressed: onRefresh, padding: EdgeInsets.zero,
          constraints: const BoxConstraints(), tooltip: 'Atualizar'),
      ]),
    );
  }
}
