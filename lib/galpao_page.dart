import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'embalagem.dart';
import 'estoque_localizado_service.dart';
import 'galpao_busca.dart';
import 'galpao_config.dart';
import 'galpao_pilhas.dart';
import 'galpao_saldo.dart';
import 'galpao_scene.dart';
import 'galpao_service.dart';
import 'gondola_scene.dart'
    show corEnderecoDivergente, corEnderecoDivergentePositiva;
import 'modo_conferencia_service.dart';
import 'models.dart' show Produto, corConferenciaCiano, pluralizar;
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

  /// Código do produto que veio da busca: TODAS as posições dele acendem em
  /// laranja, não só [posicaoInicial]. O mesmo produto costuma ocupar vários
  /// paletes em ruas diferentes, e a pergunta de quem buscou é "onde ele
  /// está", no plural — igual às estantes, que já acendem todas as caixas do
  /// produto procurado.
  final String? codigoDestacado;

  /// Abrir já com o Modo Conferência ligado — é por onde o banner do mapa da
  /// loja entra quando há pendentes com rack no galpão.
  final bool conferenciaAoAbrir;

  /// Conferência do dia já pronta. Como [pilhasIniciais], informá-la desliga
  /// as consultas ao banco (testes e uso offline).
  final ModoConferenciaResultado? conferenciaInicial;

  /// Saldos (sistema × endereçado) já prontos, por código de produto. Como
  /// [pilhasIniciais], informá-los desliga a consulta ao banco.
  final Map<String, SaldoProduto>? saldosIniciais;

  /// Abrir com a leitura de saldo desligada — o galpão nas cores de
  /// categoria. Ligada é o padrão: a pergunta de quem está distribuindo carga
  /// é justamente o que ainda falta endereçar.
  final bool saldoAoAbrir;

  const GalpaoPage({
    super.key,
    this.pilhasIniciais,
    this.catalogoInicial,
    this.posicaoInicial,
    this.codigoDestacado,
    this.conferenciaAoAbrir = false,
    this.conferenciaInicial,
    this.saldosIniciais,
    this.saldoAoAbrir = true,
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

  /// Produto aceso no mapa inteiro (busca da loja ou o botão do painel).
  /// Null = ninguém destacado, cores normais de produto.
  String? _destacadoCodigo;

  // Modo Conferência: a mesma função do mapa da loja, aplicada aos racks —
  // pendente de hoje acende em ciano, o resto do galpão apaga. A lista de
  // pendentes é a MESMA (contagem_itens), então os dois prédios sempre falam
  // do mesmo dia de contagem.
  bool                      _modoConferencia       = false;
  bool                      _carregandoConferencia = false;
  ModoConferenciaResultado? _conferencia;

  // Saldo por produto: quanto o sistema diz que existe contra quanto já está
  // endereçado. Ligado, pinta de vermelho o rack de produto com carga ainda
  // por endereçar e de azul o que passou do sistema — a mesma convenção das
  // gôndolas e estantes.
  late bool                 _mostrarSaldo = widget.saldoAoAbrir;
  Map<String, SaldoProduto> _saldos       = const {};

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

  /// True quando os saldos vêm do banco. Semeados por parâmetro (testes, uso
  /// offline), a página não consulta nada.
  bool get _consultandoSaldos =>
      widget.saldosIniciais == null && _persistindo;

  bool _carregandoPilhas = false;

  @override
  void initState() {
    super.initState();
    // Código vazio (rack gravado sem código) não destaca nada — senão o
    // destaque casaria com todos os outros racks sem código.
    final destaque = widget.codigoDestacado;
    _destacadoCodigo =
        destaque != null && destaque.isNotEmpty ? destaque : null;
    final semente = widget.catalogoInicial;
    if (semente != null) {
      _aplicarCatalogo(semente);
    } else {
      _carregarCatalogo();
    }
    _saldos = {...?widget.saldosIniciais};
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
    // Depois das pilhas de propósito: a consulta de saldo se apoia nos
    // códigos que estão em galpao_racks, e recarregá-la junto mantém as duas
    // leituras do mesmo instante.
    unawaited(_carregarSaldos());
  }

  /// Relê os saldos do banco. Silencioso: sem conexão o mapa volta vazio e o
  /// galpão simplesmente fica nas cores de categoria — a leitura de saldo é
  /// informação a mais, nunca um bloqueio para lançar carga.
  Future<void> _carregarSaldos() async {
    if (!_consultandoSaldos) return;
    final saldos = await GalpaoService().carregarSaldos();
    if (!mounted) return;
    setState(() => _saldos = saldos);
  }

  /// Saldo de um produto para o painel, mesmo que ele ainda não tenha rack
  /// nenhum no galpão — é o número que interessa na hora de lançar ("o
  /// sistema tem 145, já endereçei 100").
  ///
  /// O mapa em memória responde primeiro; só um produto de fora dele (nunca
  /// endereçado, ou catálogo recém-aberto) custa as duas consultas.
  Future<SaldoProduto?> _saldoDoProduto(String codigo) async {
    final emMemoria = _saldos[codigo];
    if (emMemoria != null) return emMemoria;
    if (!_consultandoSaldos) return null;
    final servico = EstoqueLocalizadoService();
    final info = await servico.buscarInfoMestre(codigo);
    if (info == null) return null;
    return SaldoProduto(
      codigo:     codigo,
      qtdSistema: info.qtdSistema,
      enderecado: await servico.totalProduto(codigo),
    );
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
    // Isolar a rua só faz sentido enquanto todas as posições do produto
    // destacado estão nela. Espalhado por duas ruas, o filtro apagaria da
    // tela exatamente as posições que a busca acabou de acender — quem
    // procurou o herbicida veria um palete e concluiria que é o único.
    final ruasDoProduto = _ruasComDestaque;
    setState(() {
      _ruasVisiveis =
          ruasDoProduto.length > 1 ? null : {posicao.rua.numero};
      _selecionado = ToqueGalpao(
        posicao: numero,
        ordem:   pilha.isEmpty ? 1 : pilha.length,
        ocupado: pilha.isNotEmpty,
      );
    });
  }

  // ── Destaque de produto (busca) ────────────────────────────────────────────

  /// Racks do produto destacado, no galpão inteiro. Vazio sem destaque.
  List<RackGalpao> get _racksDestacados {
    final codigo = _destacadoCodigo;
    if (codigo == null) return const [];
    return [
      for (final pilha in _pilhas.values)
        for (final rack in pilha)
          if (rack.produtoCodigo == codigo) rack,
    ];
  }

  /// Posições (1–85) que guardam o produto destacado.
  Set<int> get _posicoesComDestaque =>
      {for (final rack in _racksDestacados) rack.posicao};

  /// Ruas que guardam o produto destacado — vira um ponto laranja no chip da
  /// rua, pelo mesmo motivo do ponto ciano da conferência: com uma rua
  /// isolada, os racks acesos das outras somem da tela.
  Set<int> get _ruasComDestaque {
    final ruas = <int>{};
    for (final numero in _posicoesComDestaque) {
      final rua = GalpaoConfig.ruaDe(numero);
      if (rua != null) ruas.add(rua.numero);
    }
    return ruas;
  }

  /// Nome do produto destacado, lido dos próprios racks (o catálogo pode
  /// ainda estar carregando). Cai no código quando o rack foi gravado sem
  /// nome.
  String get _nomeDestacado {
    final racks = _racksDestacados;
    for (final rack in racks) {
      if (rack.produtoNome.isNotEmpty) return rack.produtoNome;
    }
    return _destacadoCodigo ?? '';
  }

  /// Liga/desliga o destaque de um produto. Ligar não mexe no filtro de rua
  /// já escolhido pelo usuário: os pontos nos chips dizem onde estão as
  /// outras posições, e trocar o filtro por baixo dele seria o mapa se mexer
  /// sozinho.
  void _alternarDestaque(String codigo) {
    setState(() =>
        _destacadoCodigo = _destacadoCodigo == codigo ? null : codigo);
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
      // O saldo do produto acompanha o lançamento na hora: o cubo que acabou
      // de entrar não pode continuar vermelho esperando a releitura do banco.
      _saldos = saldosComDelta(_saldos,
          codigo: produto.codigo, delta: quantidade);
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
      setState(() {
        _pilhas[posicao] = antes;
        _saldos = saldosComDelta(_saldos,
            codigo: produto.codigo, delta: -quantidade);
      });
      _avisar('Não deu para gravar o lançamento — confira a conexão com o '
          'banco em ⚙️.');
    } else {
      // A pilha do banco manda: se outra pessoa lançou nesta posição no meio
      // do caminho, o rack novo entrou num nível acima do previsto.
      setState(() => _pilhas[posicao] = gravada);
      // E o saldo do banco também: o delta otimista acima ignora o que outro
      // aparelho lançou enquanto isso.
      unawaited(_carregarSaldos());
    }
  }

  Future<void> _onEsvaziar(int posicao, int ordem) async {
    final antes = _pilhas[posicao] ?? const <RackGalpao>[];
    // O rack que sai: o que ele levava embora deixa de estar endereçado, e o
    // saldo do produto tem de refletir isso no mesmo frame da descida.
    final saindo = ordem >= 1 && ordem <= antes.length
        ? antes[ordem - 1]
        : null;
    setState(() {
      _pilhas[posicao] = pilhaAposEsvaziar(antes, ordem);
      if (saindo != null) {
        _saldos = saldosComDelta(_saldos,
            codigo: saindo.produtoCodigo, delta: -saindo.quantidade);
      }
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
      setState(() {
        _pilhas[posicao] = antes;
        if (saindo != null) {
          _saldos = saldosComDelta(_saldos,
              codigo: saindo.produtoCodigo, delta: saindo.quantidade);
        }
      });
      _avisar('Não deu para esvaziar no banco — confira a conexão em ⚙️.');
    } else {
      setState(() => _pilhas[posicao] = gravada);
      unawaited(_carregarSaldos());
    }
  }

  /// Códigos com rack no galpão — a base do resumo de saldo (um produto em
  /// oito paletes conta uma vez).
  Iterable<String> get _codigosComRack => [
        for (final pilha in _pilhas.values)
          for (final rack in pilha) rack.produtoCodigo,
      ];

  /// Quantos produtos do galpão estão com falta e quantos com sobra. Vazio
  /// com a leitura desligada (ou no Modo Conferência, que manda nas cores).
  ({int comFalta, int comSobra}) get _resumoSaldo =>
      _mostrarSaldo && !_modoConferencia
          ? resumoSaldos(_saldos, _codigosComRack)
          : (comFalta: 0, comSobra: 0);

  void _toggleSaldo() => setState(() => _mostrarSaldo = !_mostrarSaldo);

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
    // Uma vez por frame: a conta percorre os racks todos, e a faixa a consulta
    // em três lugares.
    final resumoSaldo = _resumoSaldo;

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
            destacadoCodigo:     _destacadoCodigo,
            onTapEndereco:       _onTapEndereco,
            descida:             _descida,
            ruasVisiveis:        _ruasVisiveis,
            modoConferencia:     _modoConferencia,
            codigosConferencia:  _codigosConferencia,
            contagemConferencia: _contagemConferencia,
            mostrarSaldo:        _mostrarSaldo,
            saldos:              _saldos,
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
                    // Sem o botão de saldo durante a conferência: ali as
                    // cores são da rota do dia, e um botão que não muda nada
                    // na tela é pior que botão nenhum.
                    if (!_modoConferencia) ...[
                      _ToggleSaldoGalpao(
                        ativo: _mostrarSaldo,
                        onTap: _toggleSaldo,
                      ),
                      const SizedBox(width: 8),
                    ],
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
                      comDestaque: _modoConferencia
                          ? const {}
                          : _ruasComDestaque,
                    ),
                    // Enquanto a conferência está ligada ela manda nas cores,
                    // então o destaque de busca não aparece — nem a faixa.
                    if (_destacadoCodigo != null && !_modoConferencia)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: _FaixaDestaqueProduto(
                          nome:      _nomeDestacado,
                          posicoes:  _posicoesComDestaque.length,
                          racks:     _racksDestacados.length,
                          onLimpar:  () =>
                              setState(() => _destacadoCodigo = null),
                          onVerTodas: _ruasVisiveis == null
                              ? null
                              : () => _filtrarRua(null),
                        ),
                      ),
                    if (resumoSaldo.comFalta > 0 || resumoSaldo.comSobra > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: _FaixaSaldo(
                          comFalta: resumoSaldo.comFalta,
                          comSobra: resumoSaldo.comSobra,
                        ),
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
                  destacadoCodigo:     _destacadoCodigo,
                  saldos:              _saldos,
                  onConsultarSaldo:    _saldoDoProduto,
                  onAlternarDestaque:  _modoConferencia
                      ? null
                      : _alternarDestaque,
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

  /// Ruas com o produto destacado pela busca — ponto laranja no chip. Sem
  /// ele, isolar uma rua esconderia as outras posições do produto sem dizer
  /// para onde ir procurá-las.
  final Set<int>           comDestaque;

  const _BarraDeRuas({
    required this.visiveis,
    required this.onSelecionar,
    this.comPendencia = const {},
    this.comDestaque  = const {},
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
              destacada: comDestaque.contains(rua.numero),
            ),
        ],
      ),
    );
  }

  Widget _chip(String texto, bool ativo, VoidCallback onTap,
          {bool pendente = false, bool destacada = false}) =>
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
                if (destacada) ...[
                  const SizedBox(width: 5),
                  Container(
                    width: 6, height: 6,
                    decoration: const BoxDecoration(
                      color: corCamda,
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

// ── Faixa do produto destacado ───────────────────────────────────────────────

/// Diz o que está aceso no mapa e em quantos lugares: o destaque é a resposta
/// da busca, e sem essa linha o usuário veria vários cubos laranja sem saber
/// se são todos do mesmo produto — nem quantos ainda estão fora da tela por
/// causa do filtro de rua.
class _FaixaDestaqueProduto extends StatelessWidget {
  final String        nome;
  final int           posicoes;
  final int           racks;
  final VoidCallback  onLimpar;

  /// Tirar o filtro de rua para ver o produto no galpão inteiro. Null quando
  /// já está em 'Todas'.
  final VoidCallback? onVerTodas;

  const _FaixaDestaqueProduto({
    required this.nome,
    required this.posicoes,
    required this.racks,
    required this.onLimpar,
    this.onVerTodas,
  });

  @override
  Widget build(BuildContext context) {
    // Racks e posições são coisas diferentes — dois racks empilhados na mesma
    // posição são dois paletes e um lugar só —, então a linha diz os dois
    // quando eles não coincidem.
    final resumo = posicoes == 0
        ? 'nenhuma posição no galpão'
        : racks == posicoes
            ? pluralizar(posicoes, 'posição', 'posições')
            : '${pluralizar(posicoes, 'posição', 'posições')} · '
              '${pluralizar(racks, 'rack')}';

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
      decoration: BoxDecoration(
        color:        corCamda.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: corCamda.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 14, color: corCamda),
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
                      fontWeight: FontWeight.w600),
                ),
                Text(
                  'aceso em $resumo',
                  style: const TextStyle(color: corCamda, fontSize: 11),
                ),
              ],
            ),
          ),
          if (onVerTodas != null)
            TextButton(
              onPressed: onVerTodas,
              style: TextButton.styleFrom(
                foregroundColor: corCamda,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Ver todas as ruas',
                  style: TextStyle(fontSize: 11)),
            ),
          GestureDetector(
            onTap: onLimpar,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.close, size: 16, color: corCamda),
            ),
          ),
        ],
      ),
    );
  }
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

  /// Produto aceso no mapa agora (busca), para o botão do painel saber se
  /// oferece ligar ou desligar o destaque.
  final String?                    destacadoCodigo;

  /// Ligar/desligar o destaque do produto deste rack no galpão inteiro.
  /// Null esconde o botão (Modo Conferência manda nas cores).
  final ValueChanged<String>?      onAlternarDestaque;

  /// Saldos já conhecidos (sistema × endereçado), por código de produto —
  /// os mesmos que pintam os cubos.
  final Map<String, SaldoProduto>  saldos;

  /// Busca o saldo de um produto que não está em [saldos] — é o caso do
  /// produto escolhido para lançar, que pode nunca ter tido endereço. Null
  /// (testes, uso offline) mostra só o que já veio em [saldos].
  final Future<SaldoProduto?> Function(String codigo)? onConsultarSaldo;

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
    this.destacadoCodigo,
    this.onAlternarDestaque,
    this.saldos             = const {},
    this.onConsultarSaldo,
  });

  @override
  State<PainelEnderecoGalpao> createState() => _PainelEnderecoGalpaoState();
}

class _PainelEnderecoGalpaoState extends State<PainelEnderecoGalpao> {
  final _buscaCtrl = TextEditingController();
  final _qtdCtrl   = TextEditingController();

  List<Produto> _resultados  = const [];
  Produto?      _produtoSel;

  /// Saldo do produto em foco: o do rack, num endereço ocupado, ou o do
  /// produto escolhido para lançar numa vaga livre. Null enquanto não se sabe
  /// (produto fora do estoque_mestre, ou consulta ainda a caminho).
  SaldoProduto? _saldo;

  /// Sequência das consultas de saldo: trocar de produto invalida a resposta
  /// da anterior, que pode chegar depois e mostrar o número do produto errado.
  int _saldoSeq = 0;

  @override
  void initState() {
    super.initState();
    final rack = _rackDoToque;
    if (rack != null) _focarSaldo(rack.produtoCodigo);
  }

  /// O rack sob o endereço tocado, ou null numa vaga livre.
  RackGalpao? get _rackDoToque {
    final t     = widget.toque;
    final pilha = widget.pilhas[t.posicao] ?? const <RackGalpao>[];
    return t.ocupado && t.ordem <= pilha.length ? pilha[t.ordem - 1] : null;
  }

  /// Põe o saldo de [codigo] em foco. O mapa em memória responde na hora; se
  /// o produto não estiver nele, a consulta assíncrona preenche depois.
  ///
  /// NÃO chama setState de propósito: os dois chamadores (initState e o
  /// setState de [_selecionarProduto]) já estão num ponto em que a tela vai
  /// ser construída em seguida. A resposta assíncrona, essa sim, avisa a tela.
  void _focarSaldo(String codigo) {
    final seq = ++_saldoSeq;
    _saldo = widget.saldos[codigo];
    if (_saldo != null) return;
    final consulta = widget.onConsultarSaldo;
    if (consulta == null) return;
    unawaited(() async {
      final saldo = await consulta(codigo);
      if (!mounted || seq != _saldoSeq) return;
      setState(() => _saldo = saldo);
    }());
  }

  @override
  void didUpdateWidget(PainelEnderecoGalpao old) {
    super.didUpdateWidget(old);
    // Saldo relido do banco (ou mexido por um lançamento em outro endereço)
    // com o painel aberto: a tarja acompanha, sem setState — a tela já está
    // sendo reconstruída aqui.
    if (identical(old.saldos, widget.saldos)) return;
    final codigo = _produtoSel?.codigo ?? _rackDoToque?.produtoCodigo;
    if (codigo == null) return;
    final novo = widget.saldos[codigo];
    if (novo != null) _saldo = novo;
  }

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
      _focarSaldo(p.codigo);
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
    final blocoSaldo = _blocoSaldo(rack.produtoNome);

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
        if (blocoSaldo != null) ...[
          const SizedBox(height: 10),
          blocoSaldo,
        ],
        if (widget.onAlternarDestaque != null) ...[
          const SizedBox(height: 10),
          _botaoDestaque(rack),
        ],
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

  /// O saldo do produto em foco, em uma tarja: o que o sistema tem, o que já
  /// está endereçado e a diferença entre os dois.
  ///
  /// É a leitura que explica a cor do cubo — vermelho falta endereçar, azul
  /// passou do sistema —, e é também o número de que quem está distribuindo
  /// carga precisa antes de digitar a quantidade: "o sistema tem 145, já pus
  /// 100, faltam 45".
  ///
  /// Devolve null quando não há saldo conhecido (produto fora do
  /// estoque_mestre, sem conexão, ou consulta a caminho) — melhor nada do que
  /// um número inventado.
  Widget? _blocoSaldo(String nomeProduto) {
    final saldo = _saldo;
    if (saldo == null) return null;

    // As quantidades vão para a tela na unidade de manuseio do produto
    // (baldes/caixas), a mesma do resto do painel — quem confere carga não
    // conta litros.
    String fmt(double valor) =>
        quantidadeEmbalada(nomeProduto, valor) ?? formatarNumero(valor);

    final cor = saldo.falta
        ? corEnderecoDivergente
        : saldo.sobra
            ? corEnderecoDivergentePositiva
            : const Color(0xFF6fcf97);
    final icone = saldo.falta
        ? Icons.report_problem_outlined
        : saldo.sobra
            ? Icons.unfold_more
            : Icons.check_circle_outline;
    final titulo = saldo.falta
        ? 'Faltam ${fmt(saldo.quantoFalta)} por endereçar'
        : saldo.sobra
            ? 'Sobram ${fmt(saldo.quantoSobra)} endereçados'
            : 'Tudo endereçado';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color:        cor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        border:       Border.all(color: cor.withValues(alpha: 0.55)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 13, color: cor),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  titulo,
                  style: TextStyle(
                      color:      cor,
                      fontSize:   11,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'Sistema ${fmt(saldo.qtdSistema)} · '
                  'endereçado ${fmt(saldo.enderecado)}',
                  style: const TextStyle(
                      color: Color(0xFF8a9aa8), fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Acende (ou apaga) todas as posições deste produto no mapa. É a mesma
  /// leitura que a busca da loja entrega ao abrir o galpão — só que a partir
  /// de um rack que a pessoa já tem na mão.
  Widget _botaoDestaque(RackGalpao rack) {
    final quantas = _posicoesDoProduto(rack.produtoCodigo);
    final aceso   = widget.destacadoCodigo == rack.produtoCodigo;

    return GestureDetector(
      onTap: () => widget.onAlternarDestaque?.call(rack.produtoCodigo),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: aceso
              ? corCamda.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: aceso
                ? corCamda
                : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              aceso ? Icons.lightbulb : Icons.lightbulb_outline,
              size: 13,
              color: aceso ? corCamda : const Color(0xFF8a9aa8),
            ),
            const SizedBox(width: 6),
            Text(
              aceso
                  ? 'Apagar destaque · '
                    '${pluralizar(quantas, 'posição', 'posições')}'
                  : 'Destacar ${pluralizar(quantas, 'posição', 'posições')} '
                    'deste produto',
              style: TextStyle(
                color: aceso ? corCamda : const Color(0xFF8a9aa8),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Em quantas posições do galpão este produto está — racks empilhados na
  /// mesma posição contam uma vez só, que é como quem vai buscar conta.
  int _posicoesDoProduto(String codigo) {
    var total = 0;
    for (final pilha in widget.pilhas.values) {
      if (pilha.any((r) => r.produtoCodigo == codigo)) total++;
    }
    return total;
  }

  // ── Endereço vazio: lançar ─────────────────────────────────────────────────

  Widget _buildVazio(ToqueGalpao t) {
    final produto = _produtoSel;
    // Saldo do produto escolhido: quanto ainda falta endereçar é justamente o
    // que decide a quantidade a lançar neste palete.
    final blocoSaldo = produto == null ? null : _blocoSaldo(produto.nome);

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
                    _saldo = null;
                    _saldoSeq++;
                  }),
                  child: const Icon(Icons.close,
                      size: 14, color: Color(0xFF8a9aa8)),
                ),
              ],
            ),
          ),
          if (blocoSaldo != null) ...[
            const SizedBox(height: 8),
            blocoSaldo,
          ],
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
/// Liga/desliga a leitura de saldo do galpão: com ela ligada, o rack de um
/// produto que ainda tem carga por endereçar fica vermelho e o de um produto
/// endereçado além do sistema fica azul — as mesmas cores das gôndolas.
///
/// Existe como botão (e não como estado fixo) porque as duas leituras
/// competem: a cor de saldo cobre a cor da categoria, que é como se acha um
/// produto no mapa de longe. Desligar devolve o galpão às categorias.
class _ToggleSaldoGalpao extends StatelessWidget {
  final bool         ativo;
  final VoidCallback onTap;

  const _ToggleSaldoGalpao({required this.ativo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        width:  46,
        decoration: BoxDecoration(
          color: ativo
              ? corCamda.withValues(alpha: 0.18)
              : const Color(0xEE141518),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: ativo
                ? corCamda
                : Colors.white.withValues(alpha: 0.10),
          ),
        ),
        child: Icon(
          ativo ? Icons.balance : Icons.balance_outlined,
          color: ativo ? corCamda : const Color(0xFF8a877f),
          size: 20,
        ),
      ),
    );
  }
}

/// Faixa de resumo do saldo: quantos produtos do galpão estão com carga por
/// endereçar e quantos passaram do sistema.
///
/// Sem ela, os cubos vermelhos e azuis seriam duas cores novas sem legenda —
/// e, com uma rua isolada pelo filtro, não haveria como saber que existem
/// outros produtos fora da tela na mesma situação.
class _FaixaSaldo extends StatelessWidget {
  final int comFalta;
  final int comSobra;

  const _FaixaSaldo({required this.comFalta, required this.comSobra});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color:        const Color(0xEE141518),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          // Ícone contornado, o mesmo do botão apagado: o botão da barra fica
          // sólido quando a leitura está ligada, e duas balanças sólidas na
          // tela ao mesmo tempo confundem qual delas é o interruptor.
          const Icon(Icons.balance_outlined,
              size: 13, color: Color(0xFF8a877f)),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 12,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (comFalta > 0)
                  _legenda(
                    corEnderecoDivergente,
                    '${pluralizar(comFalta, 'produto')} por endereçar',
                  ),
                if (comSobra > 0)
                  _legenda(
                    corEnderecoDivergentePositiva,
                    '${pluralizar(comSobra, 'produto')} acima do sistema',
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _legenda(Color cor, String texto) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: cor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            texto,
            style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
          ),
        ],
      );
}

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
                    : 'Conferência do dia: '
                      '${pluralizar(r!.totalProdutosGalpao, 'produto')} em '
                      '${pluralizar(r.totalPosicoesGalpao, 'posição', 'posições')}',
            // O banner fica sobre a cena: duas linhas é o teto, senão ele
            // cobre os racks que acabou de acender.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
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
