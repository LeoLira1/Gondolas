import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'estocados_busca.dart';
import 'estocados_sheet.dart';
import 'fila_gravacao.dart';
import 'fila_gravacao_ui.dart';
import 'gravacao_lote.dart';
import 'galpao_busca.dart';
import 'baixa_por_contagem.dart';
import 'baixa_por_contagem_service.dart';
import 'baixa_por_contagem_ui.dart';
import 'galpao_config.dart';
import 'galpao_pilhas.dart';
import 'galpao_saldo.dart';
import 'galpao_scene.dart';
import 'galpao_service.dart';
import 'gondola_scene.dart'
    show corEnderecoDivergente, corEnderecoDivergentePositiva;
import 'modo_conferencia_service.dart';
import 'models.dart' show Produto, corConferenciaCiano, pluralizar;
import 'outbox.dart' show gerarUuidV4;
import 'turso_service.dart';
import 'unidades.dart';

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
  final List<Produto>? catalogoInicial;

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
  final double quantidade;

  const LancamentoRecente({required this.produto, required this.quantidade});
}

class _GalpaoPageState extends State<GalpaoPage> {
  late final Map<int, List<RackGalpao>> _pilhas = {...?widget.pilhasIniciais};

  List<Produto> _catalogo = const [];
  Map<String, Color> _corPorProduto = const {};
  bool _carregandoCatalogo = false;

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
  bool _modoConferencia = false;
  bool _carregandoConferencia = false;
  ModoConferenciaResultado? _conferencia;

  // Saldo por produto: quanto o sistema diz que existe contra quanto já está
  // endereçado. Ligado, pinta de vermelho o rack de produto com carga ainda
  // por endereçar e de azul o que passou do sistema — a mesma convenção das
  // gôndolas e estantes.
  late bool _mostrarSaldo = widget.saldoAoAbrir;
  Map<String, SaldoProduto> _saldos = const {};

  // Baixa automática do que foi vendido (ver baixa_por_contagem.dart): roda
  // ao abrir o galpão e, quando tira quantidade de algum rack, deixa a faixa
  // que diz o que saiu. Null = não rodou ainda, ou não havia o que baixar.
  ResumoBaixa? _resumoBaixa;

  DescidaPilha? _descida;
  int _descidaSeq = 0;

  /// Parte do galpão aberta no mapa: 1 ou 2. O galpão são dois blocos
  /// separados, e a tela mostra um de cada vez — ver GalpaoConfig.
  int _parte = 1;

  /// Ruas visíveis: null = Todas as da parte aberta. Isolar uma rua tira as
  /// outras do desenho E da lista de alvos do toque (a cena reconstrói os
  /// alvos).
  Set<int>? _ruasVisiveis;

  final _irParaCtrl = TextEditingController();

  @override
  void dispose() {
    TursoService().dataRevision.removeListener(_aoAtualizarDados);
    if (_persistindo) _fila.removeListener(_aoMudarFila);
    unawaited(_eventosFila?.cancel());
    _recargaAposFila?.cancel();
    _irParaCtrl.dispose();
    super.dispose();
  }

  /// Troca a parte desenhada. Volta o filtro para `Todas` (um R3 guardado da
  /// parte 1 esconderia o galpão inteiro na parte 2, que só tem R9–R12) e
  /// fecha o painel de um endereço que ficou no outro bloco — ele mostraria um
  /// endereço que não está mais na tela, do mesmo jeito que o filtro de rua.
  void _trocarParte(int parte) {
    if (parte == _parte) return;
    setState(() {
      _parte = parte;
      _ruasVisiveis = null;
      final sel = _selecionado;
      if (sel != null && GalpaoConfig.parteDe(sel.posicao) != parte) {
        _selecionado = null;
      }
    });
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

  /// "Ir para o número": abre a parte do número, isola a rua da posição e
  /// marca o endereço — o rack do topo se houver pilha, senão a vaga do chão.
  ///
  /// O número é global (1–138), então digitar 100 leva à parte 2 sem precisar
  /// trocar de bloco antes: quem tem o endereço na mão não pensa em parte.
  void _irParaPosicao(String texto) {
    final numero = int.tryParse(texto.trim());
    final posicao = numero == null ? null : GalpaoConfig.porNumero(numero);
    if (posicao == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Posição $texto não existe — são 1 a '
            '${GalpaoConfig.totalPosicoes}.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final pilha = _pilhas[posicao.numero] ?? const <RackGalpao>[];
    setState(() {
      _parte = posicao.parte;
      _ruasVisiveis = {posicao.rua.numero};
      _selecionado = ToqueGalpao(
        posicao: posicao.numero,
        ordem: pilha.isEmpty ? 1 : pilha.length,
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
  bool get _consultandoSaldos => widget.saldosIniciais == null && _persistindo;

  bool _carregandoPilhas = false;

  @override
  void initState() {
    super.initState();
    unawaited(_carregarEstocados());
    // Código vazio (rack gravado sem código) não destaca nada — senão o
    // destaque casaria com todos os outros racks sem código.
    final destaque = widget.codigoDestacado;
    _destacadoCodigo = destaque != null && destaque.isNotEmpty
        ? destaque
        : null;
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
      // Antes das pilhas: o que ficou na fila (desta sessão ou de antes de o
      // app fechar) entra por cima do que vier do banco.
      _fila.addListener(_aoMudarFila);
      _eventosFila = _fila.eventos.listen(_aoEventoFila);
      _filaTinhaPendentes = _temPendentesGalpao;
      // A fila primeiro (é leitura local, já feita na abertura do app quase
      // sempre): pilhas que chegassem do cache antes dela sairiam sem o que
      // ficou pendente da sessão anterior.
      unawaited(_fila.carregar().then((_) {
        if (mounted) _carregarPilhas();
      }));
      // Depois de _carregarPilhas, não antes: a baixa avisa por dataRevision
      // quando muda alguma coisa, e é esse aviso que traz as pilhas já
      // corrigidas. Abrir o galpão é o momento certo — é aqui que o rack
      // azul de produto vendido aparecia.
      //
      // E depois do primeiro frame: a passada decodifica o estoque_localizado
      // inteiro na thread da interface, e no initState isso cai justamente em
      // cima do primeiro paint da cena 3D — o mapa abria engasgado.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_rodarBaixaAutomatica());
      });
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
    // A lista de estocados também muda (entrega no app Estocados): é ela que
    // dispara a baixa automática do palete entregue.
    unawaited(_carregarEstocados());
    // Uma sincronização também traz as confirmações feitas no app de contagem:
    // rack conferido no meio do caminho tem de apagar sem o usuário pedir.
    if (_modoConferencia && _consultandoConferencia) {
      unawaited(_carregarConferencia());
    }
  }

  Future<void> _carregarPilhas() async {
    final versao = _versaoPilhas;
    setState(() => _carregandoPilhas = true);
    unawaited(GalpaoService().garantirSeed());
    final pilhas = await GalpaoService().carregarPilhas();
    if (!mounted) return;
    if (versao != _versaoPilhas) {
      // Uma gravação foi confirmada enquanto esta leitura estava no ar: ela
      // saiu da fila e pode não estar nas linhas lidas. A recarga do fim da
      // fila é que traz o estado certo.
      setState(() => _carregandoPilhas = false);
      return;
    }
    _aplicarPilhasDoBanco(pilhas);
    _marcarPosicaoInicial();
    // Depois das pilhas de propósito: a consulta de saldo se apoia nos
    // códigos que estão em galpao_racks, e recarregá-la junto mantém as duas
    // leituras do mesmo instante.
    unawaited(_carregarSaldos());
  }

  /// Roda a baixa automática da contagem e mostra a faixa quando ela tirou
  /// quantidade de algum endereço.
  ///
  /// As pilhas NÃO são recarregadas aqui: a baixa incrementa o dataRevision
  /// quando grava, e o listener que já existe faz a releitura — chamar as
  /// duas coisas carregaria o galpão inteiro duas vezes.
  Future<void> _rodarBaixaAutomatica() async {
    final resumo = await BaixaPorContagemService().rodarSeAutomatica();
    if (!mounted || resumo.semBaixas) return;
    setState(() => _resumoBaixa = resumo);
  }

  /// Relê os saldos do banco. Silencioso: sem conexão o mapa volta vazio e o
  /// galpão simplesmente fica nas cores de categoria — a leitura de saldo é
  /// informação a mais, nunca um bloqueio para lançar carga.
  Future<void> _carregarSaldos() async {
    if (!_consultandoSaldos) return;
    // Com gravação na fila, o banco ainda não sabe dela e a leitura apagaria
    // o delta que a tela já aplicou. A recarga do fim da fila lê o saldo.
    if (_temPendentesGalpao) return;
    final mudancas = _mudancasLocais;
    final saldos = await GalpaoService().carregarSaldos();
    if (!mounted || mudancas != _mudancasLocais || _temPendentesGalpao) return;
    setState(() => _saldos = saldos);
  }

  /// Saldo de um produto para o painel, mesmo que ele ainda não tenha rack
  /// nenhum no galpão — é o número que interessa na hora de lançar ("o
  /// sistema tem 145, já endereçei 100").
  ///
  /// O mapa em memória responde primeiro; só um produto de fora dele (nunca
  /// endereçado, ou catálogo recém-aberto) custa a consulta. Ela é a MESMA de
  /// [GalpaoService.carregarSaldos] — inclusive na soma dos códigos irmãos do
  /// produto —, para o painel nunca mostrar um número diferente do da tarja
  /// que já estava na tela.
  Future<SaldoProduto?> _saldoDoProduto(String codigo) async {
    final emMemoria = _saldos[codigo];
    if (emMemoria != null) return emMemoria;
    if (!_consultandoSaldos) return null;
    return GalpaoService().carregarSaldo(codigo);
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
      // A parte é a do endereço escolhido, mesmo com o produto espalhado pelos
      // dois blocos: o mapa mostra um de cada vez, e o ponto laranja no chip
      // da outra parte é o que diz que há mais paletes lá.
      _parte = posicao.parte;
      _ruasVisiveis = ruasDoProduto.length > 1 ? null : {posicao.rua.numero};
      _selecionado = ToqueGalpao(
        posicao: numero,
        ordem: pilha.isEmpty ? 1 : pilha.length,
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
          if (rack.contem(codigo)) rack,
    ];
  }

  /// Posições (1–138) que guardam o produto destacado.
  Set<int> get _posicoesComDestaque => {
    for (final rack in _racksDestacados) rack.posicao,
  };

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

  /// Partes que guardam o produto destacado — ponto laranja no chip da parte,
  /// pelo mesmo motivo do ponto dos chips de rua: o mapa desenha um bloco de
  /// cada vez, e sem essa marca os paletes do outro bloco simplesmente não
  /// existiriam para quem está olhando.
  Set<int> get _partesComDestaque {
    final partes = <int>{};
    for (final numero in _posicoesComDestaque) {
      final parte = GalpaoConfig.parteDe(numero);
      if (parte != null) partes.add(parte);
    }
    return partes;
  }

  /// Nome do produto destacado, lido dos próprios racks (o catálogo pode
  /// ainda estar carregando). Cai no código quando o rack foi gravado sem
  /// nome.
  String get _nomeDestacado {
    final racks = _racksDestacados;
    for (final rack in racks) {
      for (final p in rack.produtos) {
        if (p.produtoCodigo == _destacadoCodigo && p.produtoNome.isNotEmpty) {
          return p.produtoNome;
        }
      }
    }
    return _destacadoCodigo ?? '';
  }

  /// Liga/desliga o destaque de um produto. Ligar não mexe no filtro de rua
  /// já escolhido pelo usuário: os pontos nos chips dizem onde estão as
  /// outras posições, e trocar o filtro por baixo dele seria o mapa se mexer
  /// sozinho.
  void _alternarDestaque(String codigo) {
    setState(
      () => _destacadoCodigo = _destacadoCodigo == codigo ? null : codigo,
    );
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

  /// A lista de `materiais_terceiros` (saldo > 0) como veio do banco. Null
  /// até a primeira leitura dar certo.
  List<ItemEstocado>? _itensEstocados;

  /// Baixa automática do estocado entregue: o palete "EST:" cujo item saiu da
  /// lista (saldo zerado, o cooperado levou) sai do endereço sozinho, pela
  /// mesma operação do "Retirar do endereço". Roda quando as pilhas e a lista
  /// estão as duas na mão, em qualquer ordem que cheguem.
  void _baixarEstocadosEntregues() {
    final itens = _itensEstocados;
    if (!_persistindo || itens == null || _carregandoPilhas) return;
    final racks = [
      for (final pilha in _pilhas.values)
        for (final r in pilha)
          if (!r.misto && r.rackUuid != null) r,
    ];
    final entregues = paletesEstocadosEntregues<RackGalpao>(
      comSaldo: itens,
      paletes: racks,
      codigo: (r) => r.produtoCodigo,
      nome: (r) => r.produtoNome,
    )
      // De cima para baixo: esvaziar desce a pilha, e o nível dos de baixo
      // continua valendo.
      ..sort((a, b) => b.ordem.compareTo(a.ordem));
    if (entregues.isEmpty) return;
    for (final r in entregues) {
      _onEsvaziar(r.posicao, r.ordem);
    }
    _avisar(avisoBaixaEstocados([
      for (final r in entregues.reversed)
        (
          nome: r.produtoNome.isEmpty ? r.produtoCodigo : r.produtoNome,
          endereco: 'Galpão ${r.posicao} · N${r.ordem}',
        ),
    ]));
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
      _conferencia = resultado;
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

  /// Partes que têm posição pendente hoje — ponto ciano no chip da parte, o
  /// análogo de [_ruasComPendencia] entre os dois blocos.
  Set<int> get _partesComPendencia {
    final contagem = _contagemConferencia;
    if (contagem.isEmpty) return const {};
    final partes = <int>{};
    for (final numero in contagem.keys) {
      final parte = GalpaoConfig.parteDe(numero);
      if (parte != null) partes.add(parte);
    }
    return partes;
  }

  // ── Gravação ──────────────────────────────────────────────────────────────
  //
  // Na tela primeiro, no banco depois — e o "depois" é da FilaGravacao, não
  // desta página. O galpão é usado em pé, com carga chegando: cada toque
  // aplica na hora e entra na fila, e a pessoa já pode tocar a próxima vaga
  // (antes, um lançamento feito enquanto o anterior ia ao banco era ignorado
  // em silêncio). A fila manda um lote por vez, em UMA requisição cada, e
  // reenvia sozinha se a rede falhar; só o que o banco recusa de verdade
  // (pilha que encheu em outro aparelho, rack que já saiu) volta atrás, com
  // aviso.

  final FilaGravacao _fila = FilaGravacao();
  StreamSubscription<EventoFila>? _eventosFila;
  bool _filaTinhaPendentes = false;
  Timer? _recargaAposFila;

  /// Muda quando uma gravação é CONFIRMADA: leitura do banco iniciada antes
  /// disso é descartada (ver [_carregarPilhas]).
  int _versaoPilhas = 0;

  /// Muda a cada gravação feita na tela: leitura de saldo iniciada antes
  /// disso não pode apagar o delta otimista.
  int _mudancasLocais = 0;

  bool get _temPendentesGalpao => _fila.pendentes.any((o) => o.tipo.doGalpao);

  /// O banco + o que ainda está na fila, por cima.
  void _aplicarPilhasDoBanco(Map<int, List<RackGalpao>> doBanco) {
    final pilhas = aplicarPendentesGalpao(doBanco, _fila.pendentes);
    setState(() {
      _pilhas
        ..clear()
        ..addAll(pilhas);
      _carregandoPilhas = false;
    });
    _baixarEstocadosEntregues();
  }

  void _aoMudarFila() {
    if (!mounted) return;
    final tem = _temPendentesGalpao;
    // A fila do galpão acabou (confirmada, recusada ou descartada): relê o
    // banco uma vez, para trazer o que outro aparelho fez no meio tempo e o
    // saldo de verdade. Um respiro curto junta as confirmações em rajada.
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
    if (!mounted || !evento.operacao.tipo.doGalpao) return;
    _versaoPilhas++;
    if (evento.gravada) return;
    _avisar(mensagemFalhaFila(evento));
    // A tela tinha aplicado a operação; agora ela saiu da fila, e o banco
    // (com o resto da fila por cima) é o que vale.
    unawaited(_recarregarDoBanco());
  }

  Future<void> _recarregarDoBanco() async {
    final versao = _versaoPilhas;
    final pilhas = await GalpaoService().recarregarPilhas();
    if (!mounted || pilhas == null || versao != _versaoPilhas) return;
    _aplicarPilhasDoBanco(pilhas);
    unawaited(_carregarSaldos());
  }

  void _enfileirar(OperacaoPendente op) {
    _mudancasLocais++;
    unawaited(_fila.enfileirar(op));
  }

  OperacaoPendente _operacao(
    TipoOperacao tipo, {
    required int posicao,
    required int ordem,
    String? uuid,
    String? rackUuid,
    String? itemUuid,
    String produtoCodigo = '',
    String produtoNome = '',
    double quantidade = 0,
    double? quantidadeAnterior,
  }) => OperacaoPendente(
    uuid: uuid ?? gerarUuidV4(),
    tipo: tipo,
    banco: TursoService().identidadeAtiva ?? '',
    criadaEm: DateTime.now(),
    local: posicao,
    rackUuid: rackUuid,
    itemUuid: itemUuid,
    produtoCodigo: produtoCodigo,
    produtoNome: produtoNome,
    quantidade: quantidade,
    quantidadeAnterior: quantidadeAnterior,
    rotulo: '$posicao · N$ordem',
  );

  void _onLancar(int posicao, Produto produto, double quantidade) {
    final antes = _pilhas[posicao] ?? const <RackGalpao>[];
    // O UUID do rack nasce aqui: é ele que o lote grava em rack_uuid, e é com
    // ele que um ajuste feito antes de o lançamento chegar ao banco acha o
    // rack certo.
    final uuid = _persistindo ? gerarUuidV4() : null;
    final nova = pilhaAposLancar(
      antes,
      posicao: posicao,
      produtoCodigo: produto.codigo,
      produtoNome: produto.nome,
      quantidade: quantidade,
      rackUuid: uuid,
    );
    if (nova == null) return; // pilha cheia — a UI não oferece, guarda dupla
    setState(() {
      _pilhas[posicao] = nova;
      // O saldo do produto acompanha o lançamento na hora: o cubo que acabou
      // de entrar não pode continuar vermelho esperando o banco.
      _saldos = saldosComDelta(
        _saldos,
        codigo: produto.codigo,
        delta: quantidade,
      );
      _recentes.removeWhere((r) => r.produto.codigo == produto.codigo);
      _recentes.insert(
        0,
        LancamentoRecente(produto: produto, quantidade: quantidade),
      );
      if (_recentes.length > _maxRecentes) _recentes.removeLast();
      // Fecha o painel: no fluxo de carga o próximo gesto é tocar a próxima
      // vaga, e o produto recém-lançado está nos recentes.
      _selecionado = null;
    });
    if (!_persistindo) return;
    _enfileirar(
      _operacao(
        TipoOperacao.galpaoLancar,
        uuid: uuid,
        posicao: posicao,
        ordem: nova.length,
        produtoCodigo: produto.codigo,
        produtoNome: produto.nome,
        quantidade: quantidade,
      ),
    );
  }

  /// Corrige a quantidade de um rack que já está lá — mesmo palete, mesmo
  /// produto, número novo.
  ///
  /// O painel NÃO fecha aqui (ao contrário de [_onLancar]): quem acabou de
  /// corrigir quer ver a tarja de saldo fechar na hora — é a confirmação de
  /// que o número agora bate com o sistema.
  void _onAjustar(int posicao, int ordem, double quantidade) {
    final antes = _pilhas[posicao] ?? const <RackGalpao>[];
    final rack = ordem >= 1 && ordem <= antes.length ? antes[ordem - 1] : null;
    if (rack == null || quantidade <= 0) return;
    final delta = quantidade - rack.quantidade;
    if (delta == 0) return;
    if (_persistindo && rack.rackUuid == null) {
      _avisar('Esse rack ainda não tem identidade no banco — reabra o galpão.');
      return;
    }
    setState(() {
      _pilhas[posicao] = pilhaAposAjustar(antes, ordem, quantidade);
      _saldos = saldosComDelta(
        _saldos,
        codigo: rack.produtoCodigo,
        delta: delta,
      );
    });
    if (!_persistindo) return;
    _enfileirar(
      _operacao(
        TipoOperacao.galpaoAjustar,
        posicao: posicao,
        ordem: ordem,
        rackUuid: rack.rackUuid,
        produtoCodigo: rack.produtoCodigo,
        produtoNome: rack.produtoNome,
        quantidade: quantidade,
        quantidadeAnterior: rack.quantidade,
      ),
    );
  }

  void _onEsvaziar(int posicao, int ordem) {
    final antes = _pilhas[posicao] ?? const <RackGalpao>[];
    // O rack que sai: o que ele levava embora deixa de estar endereçado, e o
    // saldo do produto tem de refletir isso no mesmo frame da descida.
    final saindo = ordem >= 1 && ordem <= antes.length
        ? antes[ordem - 1]
        : null;
    if (_persistindo && saindo?.rackUuid == null) {
      _avisar('Esse rack ainda não tem identidade no banco — reabra o galpão.');
      return;
    }
    setState(() {
      _pilhas[posicao] = pilhaAposEsvaziar(antes, ordem);
      for (final p in saindo?.produtos ?? const <ProdutoNoRack>[]) {
        _saldos = saldosComDelta(
          _saldos,
          codigo: p.produtoCodigo,
          delta: -p.quantidade,
        );
      }
      _descida = DescidaPilha(
        posicao: posicao,
        aPartirDaOrdem: ordem,
        id: ++_descidaSeq,
      );
      _selecionado = null;
    });
    if (!_persistindo || saindo == null) return;
    _enfileirar(
      _operacao(
        TipoOperacao.galpaoEsvaziar,
        posicao: posicao,
        ordem: ordem,
        rackUuid: saindo.rackUuid,
        produtoCodigo: saindo.produtoCodigo,
        produtoNome: saindo.produtoNome,
        quantidadeAnterior: saindo.quantidade,
      ),
    );
  }

  // ── Rack misto ──────────────────────────────────────────────────────────

  /// O rack de [ordem] em [posicao], pronto para gravar — ou null (com aviso,
  /// quando é falta de identidade).
  RackGalpao? _rackParaGravar(int posicao, int ordem) {
    final pilha = _pilhas[posicao] ?? const <RackGalpao>[];
    final rack = ordem >= 1 && ordem <= pilha.length ? pilha[ordem - 1] : null;
    if (rack == null) return null;
    if (_persistindo && rack.rackUuid == null) {
      _avisar('Esse rack ainda não tem identidade no banco — reabra o galpão.');
      return null;
    }
    return rack;
  }

  /// Mais um produto no mesmo palete. O rack não muda de nível; o painel
  /// fica aberto para ver a lista do rack crescer.
  void _onAdicionarProduto(
    int posicao,
    int ordem,
    Produto produto,
    double quantidade,
  ) {
    final rack = _rackParaGravar(posicao, ordem);
    if (rack == null) return;
    final itemUuid = gerarUuidV4();
    final nova = pilhaAposAdicionarProduto(
      _pilhas[posicao]!,
      ordem,
      itemUuid: itemUuid,
      produtoCodigo: produto.codigo,
      produtoNome: produto.nome,
      quantidade: quantidade,
    );
    if (nova == null) {
      _avisar(
        rack.contem(produto.codigo)
            ? 'Esse produto já está neste rack — corrija a quantidade dele.'
            : 'O rack já tem ${GalpaoConfig.produtosMaxPorRack} produtos.',
      );
      return;
    }
    setState(() {
      _pilhas[posicao] = nova;
      _saldos = saldosComDelta(
        _saldos,
        codigo: produto.codigo,
        delta: quantidade,
      );
      _recentes.removeWhere((r) => r.produto.codigo == produto.codigo);
      _recentes.insert(
        0,
        LancamentoRecente(produto: produto, quantidade: quantidade),
      );
      if (_recentes.length > _maxRecentes) _recentes.removeLast();
    });
    if (!_persistindo) return;
    _enfileirar(
      _operacao(
        TipoOperacao.galpaoAdicionarProduto,
        uuid: itemUuid,
        posicao: posicao,
        ordem: ordem,
        rackUuid: rack.rackUuid,
        produtoCodigo: produto.codigo,
        produtoNome: produto.nome,
        quantidade: quantidade,
      ),
    );
  }

  /// Corrige a quantidade de um produto de rack misto. O principal vai pelo
  /// caminho de sempre ([_onAjustar]).
  void _onAjustarProduto(
    int posicao,
    int ordem,
    ProdutoNoRack produto,
    double quantidade,
  ) {
    if (produto.principal) return _onAjustar(posicao, ordem, quantidade);
    final rack = _rackParaGravar(posicao, ordem);
    if (rack == null || quantidade <= 0) return;
    final delta = quantidade - produto.quantidade;
    if (delta == 0) return;
    setState(() {
      _pilhas[posicao] = pilhaAposAjustarProduto(
        _pilhas[posicao]!,
        ordem,
        produto.itemUuid,
        quantidade,
      );
      _saldos = saldosComDelta(
        _saldos,
        codigo: produto.produtoCodigo,
        delta: delta,
      );
    });
    if (!_persistindo) return;
    _enfileirar(
      _operacao(
        TipoOperacao.galpaoAjustar,
        posicao: posicao,
        ordem: ordem,
        rackUuid: rack.rackUuid,
        itemUuid: produto.itemUuid,
        produtoCodigo: produto.produtoCodigo,
        produtoNome: produto.produtoNome,
        quantidade: quantidade,
        quantidadeAnterior: produto.quantidade,
      ),
    );
  }

  /// Tira UM produto de um rack misto; os outros ficam no palete. Rack com um
  /// produto só não passa por aqui — zerar o único produto é [_onEsvaziar].
  void _onRemoverProduto(int posicao, int ordem, ProdutoNoRack produto) {
    final rack = _rackParaGravar(posicao, ordem);
    if (rack == null) return;
    if (!rack.misto) return _onEsvaziar(posicao, ordem);
    setState(() {
      _pilhas[posicao] = pilhaAposRemoverProduto(
        _pilhas[posicao]!,
        ordem,
        produto.itemUuid,
      );
      _saldos = saldosComDelta(
        _saldos,
        codigo: produto.produtoCodigo,
        delta: -produto.quantidade,
      );
    });
    if (!_persistindo) return;
    _enfileirar(
      _operacao(
        TipoOperacao.galpaoRemoverProduto,
        posicao: posicao,
        ordem: ordem,
        rackUuid: rack.rackUuid,
        itemUuid: produto.itemUuid,
        produtoCodigo: produto.produtoCodigo,
        produtoNome: produto.produtoNome,
        quantidadeAnterior: produto.quantidade,
      ),
    );
  }

  /// Códigos com rack no galpão — a base do resumo de saldo (um produto em
  /// oito paletes conta uma vez). Inclui os produtos dos racks mistos.
  Iterable<String> get _codigosComRack => [
    for (final pilha in _pilhas.values)
      for (final rack in pilha)
        for (final p in rack.produtos) p.produtoCodigo,
  ];

  /// Quantos produtos do galpão estão com falta e quantos com sobra. Vazio
  /// com a leitura desligada (ou no Modo Conferência, que manda nas cores).
  ({int comFalta, int comSobra}) get _resumoSaldo =>
      _mostrarSaldo && !_modoConferencia
      ? resumoSaldos(_saldos, _codigosComRack)
      : (comFalta: 0, comSobra: 0);

  void _toggleSaldo() => setState(() => _mostrarSaldo = !_mostrarSaldo);

  void _avisar(String mensagem) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensagem),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selecionado;
    // Uma vez por frame: a conta percorre os racks todos, e a faixa a consulta
    // em três lugares.
    final resumoSaldo = _resumoSaldo;

    return Scaffold(
      bottomNavigationBar: _persistindo && !_fila.vazia
          ? BarraFilaGravacao(fila: _fila)
          : null,
      backgroundColor: const Color(0xFF0b0c0e),
      body: Stack(
        children: [
          GalpaoScene(
            pilhas: _pilhas,
            corPorProduto: _corPorProduto,
            selecionado: sel == null
                ? null
                : (posicao: sel.posicao, ordem: sel.ordem),
            destacadoCodigo: _destacadoCodigo,
            onTapEndereco: _onTapEndereco,
            descida: _descida,
            parte: _parte,
            ruasVisiveis: _ruasVisiveis,
            modoConferencia: _modoConferencia,
            codigosConferencia: _codigosConferencia,
            contagemConferencia: _contagemConferencia,
            mostrarSaldo: _mostrarSaldo,
            saldos: _saldos,
          ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
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
                          // Uma linha cada, sempre: o título espremido entre
                          // os botões quebrava em duas e empurrava o subtítulo
                          // para CIMA dos chips de rua, que ficam logo abaixo
                          // numa camada própria (top: 68). Reticências em vez
                          // de quebra é o que mantém as duas camadas sem se
                          // atropelar em tela estreita.
                          // 'Galpão', e não 'CAMDA · Galpão': entre o botão
                          // de voltar, os dois interruptores e o campo do
                          // número sobram menos de 100 px para o título em
                          // tela estreita, e a marca aqui só servia para
                          // empurrar o resto para fora.
                          const Text(
                            'Galpão',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _carregandoPilhas
                                ? 'Carregando ocupação…'
                                : resumoOcupacao(
                                    totalVagas: GalpaoConfig.totalEnderecos,
                                    codigos: [
                                      for (final pilha in _pilhas.values)
                                        for (final r in pilha) r.produtoCodigo,
                                    ],
                                  ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
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
                    const SizedBox(width: 8),
                    const BotaoEstocados(),
                    const SizedBox(width: 10),
                    // Ir para o número: digita 52, isola a rua e marca.
                    SizedBox(
                      width: 74,
                      child: TextField(
                        controller: _irParaCtrl,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.go,
                        onSubmitted: _irParaPosicao,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          hintText: 'nº',
                          hintStyle: const TextStyle(
                            color: Color(0x44ffffff),
                            fontSize: 13,
                          ),
                          filled: true,
                          fillColor: const Color(0xEE141518),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Colors.white.withValues(alpha: 0.10),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Colors.white.withValues(alpha: 0.10),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: corCamda,
                              width: 1.4,
                            ),
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
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 68),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _BarraDePartes(
                      parte: _parte,
                      onSelecionar: _trocarParte,
                      comPendencia: _partesComPendencia,
                      comDestaque: _modoConferencia
                          ? const {}
                          : _partesComDestaque,
                    ),
                    _BarraDeRuas(
                      parte: _parte,
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
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        child: _FaixaDestaqueProduto(
                          nome: _nomeDestacado,
                          posicoes: _posicoesComDestaque.length,
                          racks: _racksDestacados.length,
                          onLimpar: () =>
                              setState(() => _destacadoCodigo = null),
                        ),
                      ),
                    // A baixa manda na faixa de cima: ela EXPLICA o mapa que
                    // acabou de mudar, e o resumo de saldo abaixo é a leitura
                    // do resultado. Some no Modo Conferência como as outras.
                    if (_resumoBaixa != null && !_modoConferencia)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        child: FaixaBaixaAutomatica(
                          resumo: _resumoBaixa!,
                          onFechar: () => setState(() => _resumoBaixa = null),
                        ),
                      ),
                    if (resumoSaldo.comFalta > 0 || resumoSaldo.comSobra > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        child: _FaixaSaldo(
                          comFalta: resumoSaldo.comFalta,
                          comSobra: resumoSaldo.comSobra,
                        ),
                      ),
                    if (_modoConferencia)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        child: _BannerConferenciaGalpao(
                          carregando: _carregandoConferencia,
                          resultado: _conferencia,
                          onRefresh:
                              _carregandoConferencia || !_consultandoConferencia
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
              left: 16,
              right: 16,
              bottom: 16,
              child: SafeArea(
                top: false,
                child: PainelEnderecoGalpao(
                  // A key troca o estado interno (busca, quantidade) ao mudar
                  // de endereço — resto de digitação de um endereço não pode
                  // vazar para o outro.
                  key: ValueKey('${sel.posicao}-${sel.ordem}-${sel.ocupado}'),
                  toque: sel,
                  pilhas: _pilhas,
                  catalogo: _catalogo,
                  recentes: _recentes,
                  carregandoCatalogo: _carregandoCatalogo,
                  codigosConferencia: _codigosConferencia,
                  destacadoCodigo: _destacadoCodigo,
                  saldos: _saldos,
                  onConsultarSaldo: _saldoDoProduto,
                  onAlternarDestaque: _modoConferencia
                      ? null
                      : _alternarDestaque,
                  onFechar: () => setState(() => _selecionado = null),
                  onLancar: (produto, quantidade) =>
                      _onLancar(sel.posicao, produto, quantidade),
                  onEsvaziar: () => _onEsvaziar(sel.posicao, sel.ordem),
                  onAjustarQuantidade: (quantidade) =>
                      _onAjustar(sel.posicao, sel.ordem, quantidade),
                  onAdicionarProduto: (produto, quantidade) =>
                      _onAdicionarProduto(
                        sel.posicao,
                        sel.ordem,
                        produto,
                        quantidade,
                      ),
                  onAjustarProduto: (produto, quantidade) => _onAjustarProduto(
                    sel.posicao,
                    sel.ordem,
                    produto,
                    quantidade,
                  ),
                  onRemoverProduto: (produto) =>
                      _onRemoverProduto(sel.posicao, sel.ordem, produto),
                ),
              ),
            )
          else
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
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
                      color: Colors.white.withValues(alpha: 0.35),
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

// ── Seletor de parte ─────────────────────────────────────────────────────────

/// `Parte 1` · `Parte 2`: troca o bloco desenhado no mapa.
///
/// Não é filtro, é troca de planta — os dois blocos ficam longe um do outro no
/// chão, e desenhar os dois juntos deixaria cada rack do tamanho de um pixel.
/// Por isso fica ACIMA dos chips de rua, que passam a ser os da parte aberta.
///
/// Os pontos (ciano de pendência, laranja de destaque) são o que impede a
/// outra parte de sumir do mundo: com um bloco fora da tela, é a marca no chip
/// que diz que o produto procurado — ou a conferência de hoje — também está lá.
class _BarraDePartes extends StatelessWidget {
  final int parte;
  final ValueChanged<int> onSelecionar;
  final Set<int> comPendencia;
  final Set<int> comDestaque;

  const _BarraDePartes({
    required this.parte,
    required this.onSelecionar,
    this.comPendencia = const {},
    this.comDestaque = const {},
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final p in GalpaoConfig.partes)
            _ChipGalpao(
              texto: 'Parte $p',
              ativo: p == parte,
              onTap: () => onSelecionar(p),
              pendente: comPendencia.contains(p),
              destacada: comDestaque.contains(p),
            ),
        ],
      ),
    );
  }
}

// ── Barra de filtro por rua ──────────────────────────────────────────────────

/// `Todas` + as ruas da parte aberta (`R1`…`R8` na parte 1, `R9`…`R12` na
/// parte 2). Isolar uma rua faz as outras sumirem da cena — e, junto com elas,
/// da lista de alvos do toque.
class _BarraDeRuas extends StatelessWidget {
  /// Parte aberta: manda em QUAIS chips existem. Sem isto a barra ofereceria
  /// ruas que não estão desenhadas, e tocá-las esvaziaria a tela.
  final int parte;

  final Set<int>? visiveis;
  final ValueChanged<int?> onSelecionar;

  /// Ruas com pendente de conferência hoje — ganham um ponto ciano no chip.
  final Set<int> comPendencia;

  /// Ruas com o produto destacado pela busca — ponto laranja no chip. Sem
  /// ele, isolar uma rua esconderia as outras posições do produto sem dizer
  /// para onde ir procurá-las.
  final Set<int> comDestaque;

  const _BarraDeRuas({
    required this.parte,
    required this.visiveis,
    required this.onSelecionar,
    this.comPendencia = const {},
    this.comDestaque = const {},
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _ChipGalpao(
            texto: 'Todas',
            ativo: visiveis == null,
            onTap: () => onSelecionar(null),
          ),
          for (final rua in GalpaoConfig.ruasDaParte(parte))
            _ChipGalpao(
              texto: 'R${rua.numero}',
              ativo: visiveis != null && visiveis!.contains(rua.numero),
              onTap: () => onSelecionar(rua.numero),
              pendente: comPendencia.contains(rua.numero),
              destacada: comDestaque.contains(rua.numero),
            ),
        ],
      ),
    );
  }
}

/// O chip das duas barras de cima (parte e rua): mesmo formato, mesmos pontos
/// de pendência e destaque. É um widget só porque as duas barras ficam
/// coladas na tela — dois desenhos parecidos mas diferentes ali seriam lidos
/// como coisas de naturezas diferentes, que não são.
class _ChipGalpao extends StatelessWidget {
  final String texto;
  final bool ativo;
  final VoidCallback onTap;
  final bool pendente;
  final bool destacada;

  const _ChipGalpao({
    required this.texto,
    required this.ativo,
    required this.onTap,
    this.pendente = false,
    this.destacada = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
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
            color: ativo ? corCamda : Colors.white.withValues(alpha: 0.10),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              texto,
              style: TextStyle(
                color: ativo ? corCamda : const Color(0xFF8a877f),
                fontSize: 12,
                fontWeight: ativo ? FontWeight.bold : FontWeight.w500,
              ),
            ),
            if (pendente) ...[
              const SizedBox(width: 5),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: corConferenciaCiano,
                  shape: BoxShape.circle,
                ),
              ),
            ],
            if (destacada) ...[
              const SizedBox(width: 5),
              Container(
                width: 6,
                height: 6,
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
  final String nome;
  final int posicoes;
  final int racks;
  final VoidCallback onLimpar;

  const _FaixaDestaqueProduto({
    required this.nome,
    required this.posicoes,
    required this.racks,
    required this.onLimpar,
  });

  @override
  Widget build(BuildContext context) {
    // Racks e posições são coisas diferentes — dois racks empilhados na mesma
    // posição são dois paletes e um lugar só —, então a linha diz os dois
    // quando eles não coincidem.
    final resumo = posicoes == 0
        ? 'nenhuma posição'
        : racks == posicoes
        ? pluralizar(posicoes, 'posição', 'posições')
        : '${pluralizar(posicoes, 'posição', 'posições')} · '
              '${pluralizar(racks, 'rack')}';

    // Uma linha só: o nome estica e o resumo fica colado nele. A versão de
    // duas linhas empilhava com a faixa de saldo e as duas juntas comiam um
    // quarto da tela por cima do mapa. O atalho 'Ver todas as ruas' saiu
    // daqui: o chip 'Todas' está logo acima, na barra de ruas, fazendo
    // exatamente a mesma coisa.
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      decoration: BoxDecoration(
        color: corCamda.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: corCamda.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 13, color: corCamda),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              nome,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            resumo,
            maxLines: 1,
            style: const TextStyle(color: corCamda, fontSize: 11),
          ),
          GestureDetector(
            onTap: onLimpar,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.close, size: 15, color: corCamda),
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
/// Ocupado: produto, quantidade e saldo. Sem botões de ação embaixo — eram
/// duas barras coloridas ocupando a largura do painel e poluindo a leitura
/// do que importa (o produto e o número). Tirar o palete é digitar 0 no
/// mesmo teclado que corrige a quantidade: a operação é a mesma coisa vista
/// pelo galpão — "não tem mais nada aqui" —, e o 0 já vem com a confirmação
/// e a descida animada da pilha.
///
/// Vazio: busca de produto (qualquer parte do nome, código, dois termos
/// soltos), últimos lançados como atalho, quantidade e Lançar.
///
/// O painel também serve o BARRACÃO (ver barracao_page.dart), que é o outro
/// lugar do app onde se atribui um produto a um endereço e se corrige a
/// quantidade dele. O que muda entre os dois prédios é só COMO o endereço se
/// chama — no galpão '52 · N3', no barracão 'BAR-07' —, e é por isso que os
/// três rótulos abaixo ([rotuloEndereco], [subtitulo], [textoVagaLivre]) são
/// parâmetros com o texto do galpão como padrão: o fluxo é um só, e um painel
/// paralelo no barracão seria a mesma tela mantida em dois lugares.
class PainelEnderecoGalpao extends StatefulWidget {
  final ToqueGalpao toque;
  final Map<int, List<RackGalpao>> pilhas;
  final List<Produto> catalogo;
  final List<LancamentoRecente> recentes;
  final bool carregandoCatalogo;
  final VoidCallback onFechar;
  final void Function(Produto produto, double quantidade)? onLancar;

  /// Tira o palete do endereço. Chamado quando a quantidade nova é 0 — não
  /// há mais botão para isso. Null trava o 0 no teclado de quantidade.
  final VoidCallback? onEsvaziar;

  /// Corrige a quantidade do rack aberto, em unidades. Null esconde o lápis
  /// ao lado do número (testes, uso só de leitura).
  final ValueChanged<double>? onAjustarQuantidade;

  /// Rack misto: mais um produto no mesmo palete. Null esconde o botão — o
  /// barracão, onde o palete É o endereço e leva um produto só, não passa.
  final void Function(Produto produto, double quantidade)? onAdicionarProduto;

  /// Rack misto: corrige a quantidade de UM dos produtos do rack.
  final void Function(ProdutoNoRack produto, double quantidade)?
  onAjustarProduto;

  /// Rack misto: tira UM dos produtos do rack (o 0 no teclado dele). Os
  /// outros ficam no palete.
  final ValueChanged<ProdutoNoRack>? onRemoverProduto;

  /// Códigos pendentes de conferência hoje: o rack cujo produto está aqui
  /// ganha a tarja ciana — quem tocou o cubo aceso precisa ver, no painel, que
  /// foi por isso que ele acendeu.
  final Set<String> codigosConferencia;

  /// Produto aceso no mapa agora (busca), para o botão do painel saber se
  /// oferece ligar ou desligar o destaque.
  final String? destacadoCodigo;

  /// Ligar/desligar o destaque do produto deste rack no galpão inteiro.
  /// Null esconde o botão (Modo Conferência manda nas cores).
  final ValueChanged<String>? onAlternarDestaque;

  /// Saldos já conhecidos (sistema × endereçado), por código de produto —
  /// os mesmos que pintam os cubos.
  final Map<String, SaldoProduto> saldos;

  /// Busca o saldo de um produto que não está em [saldos] — é o caso do
  /// produto escolhido para lançar, que pode nunca ter tido endereço. Null
  /// (testes, uso offline) mostra só o que já veio em [saldos].
  final Future<SaldoProduto?> Function(String codigo)? onConsultarSaldo;

  /// Como o endereço se chama nesta tela. Null usa o do galpão,
  /// '<posição> · N<nível>'.
  final String? rotuloEndereco;

  /// Linha cinza ao lado do endereço. Null usa a do galpão,
  /// 'Rua n · k de 4 na pilha'.
  final String? subtitulo;

  /// Frase verde do endereço livre. Null usa a do galpão, que fala de entrar
  /// no topo da pilha — coisa que só existe lá.
  final String? textoVagaLivre;

  const PainelEnderecoGalpao({
    super.key,
    required this.toque,
    required this.pilhas,
    required this.onFechar,
    this.catalogo = const [],
    this.recentes = const [],
    this.carregandoCatalogo = false,
    this.onLancar,
    this.onEsvaziar,
    this.onAjustarQuantidade,
    this.onAdicionarProduto,
    this.onAjustarProduto,
    this.onRemoverProduto,
    this.codigosConferencia = const {},
    this.destacadoCodigo,
    this.onAlternarDestaque,
    this.saldos = const {},
    this.onConsultarSaldo,
    this.rotuloEndereco,
    this.subtitulo,
    this.textoVagaLivre,
  });

  @override
  State<PainelEnderecoGalpao> createState() => _PainelEnderecoGalpaoState();
}

class _PainelEnderecoGalpaoState extends State<PainelEnderecoGalpao> {
  final _buscaCtrl = TextEditingController();
  final _qtdCtrl = TextEditingController();

  /// Nome do endereço aberto: o que a tela dona do painel passou, ou o do
  /// galpão. Fica num getter só para os cinco lugares que escrevem o endereço
  /// (cabeçalho, botão Lançar, título do teclado e os dois avisos do 0) não
  /// poderem divergir entre si.
  String get _rotulo =>
      widget.rotuloEndereco ??
      '${widget.toque.posicao} · N${widget.toque.ordem}';

  List<Produto> _resultados = const [];
  Produto? _produtoSel;

  /// Escolhendo o produto que vai entrar num rack que já está ocupado.
  bool _adicionando = false;

  /// Produto do rack (misto) cujo saldo está na tarja. Null é o principal.
  String? _focoCodigo;

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
    final t = widget.toque;
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
    // Catálogo que chegou (ou mudou) depois da digitação: refaz a busca em
    // curso, senão a lista ficava vazia até a pessoa redigitar.
    if (!identical(old.catalogo, widget.catalogo) &&
        _buscaCtrl.text.trim().length >= 2) {
      _resultados = buscarProdutosGalpao(_buscaCtrl.text, widget.catalogo);
    }
    if (identical(old.saldos, widget.saldos)) return;
    final codigo =
        _produtoSel?.codigo ?? _focoCodigo ?? _rackDoToque?.produtoCodigo;
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

  /// [quantidade] é o número de UNIDADES — a mesma conta do banco, do campo
  /// e do sistema (ver unidades.dart), então o prefill dos recentes só
  /// formata o que veio.
  void _selecionarProduto(Produto p, {double? quantidade}) {
    setState(() {
      _produtoSel = p;
      _resultados = const [];
      _buscaCtrl.clear();
      _focarSaldo(p.codigo);
      if (quantidade != null) _qtdCtrl.text = formatarNumero(quantidade);
    });
  }

  /// Unidades digitadas — o que vai ao banco, sem conversão nenhuma.
  double? get _quantidadeDigitada {
    final q = double.tryParse(_qtdCtrl.text.replaceAll(',', '.'));
    return q != null && q > 0 ? q : null;
  }

  void _lancar() {
    final produto = _produtoSel;
    final quantidade = _quantidadeDigitada;
    if (produto == null || quantidade == null) return;
    widget.onLancar?.call(produto, quantidade);
  }

  /// Põe o produto escolhido no rack aberto e volta à lista do rack, com o
  /// saldo do produto que acabou de entrar em foco.
  void _adicionar() {
    final produto = _produtoSel;
    final quantidade = _quantidadeDigitada;
    if (produto == null || quantidade == null) return;
    widget.onAdicionarProduto?.call(produto, quantidade);
    setState(() {
      _adicionando = false;
      _produtoSel = null;
      _qtdCtrl.clear();
      _focoCodigo = produto.codigo;
    });
  }

  void _cancelarAdicao() => setState(() {
    _adicionando = false;
    _produtoSel = null;
    _qtdCtrl.clear();
    _resultados = const [];
    _buscaCtrl.clear();
    _focarSaldo(_focoCodigo ?? _rackDoToque?.produtoCodigo ?? '');
  });

  void _focarProduto(String codigo) => setState(() {
    _focoCodigo = codigo;
    _focarSaldo(codigo);
  });

  /// Abre o teclado com a quantidade atual pronta para ser trocada, e devolve
  /// o número novo a quem sabe gravar.
  ///
  /// Zero não é uma quantidade: é o palete saindo do endereço. O dialog só
  /// aceita 0 quando há como esvaziar, avisa em vermelho antes de salvar, e
  /// aqui a chamada vai para [PainelEnderecoGalpao.onEsvaziar] — que é quem
  /// derruba os racks de cima e renumera a pilha.
  Future<void> _abrirAjuste(RackGalpao rack) async {
    final t = widget.toque;
    final pilha = widget.pilhas[t.posicao] ?? const <RackGalpao>[];
    final nova = await showDialog<double>(
      context: context,
      builder: (_) => _DialogAjustarQuantidade(
        rotulo: _rotulo,
        produto: rack.produtos.first,
        saldo: _saldo,
        podeEsvaziar: widget.onEsvaziar != null,
        temAcima: t.ordem < pilha.length,
      ),
    );
    if (!mounted || nova == null || nova == rack.quantidade) return;
    if (nova == 0) {
      widget.onEsvaziar?.call();
      return;
    }
    widget.onAjustarQuantidade?.call(nova);
  }

  /// [_abrirAjuste] para um produto de rack misto: 0 tira só ESTE produto, e
  /// o palete fica com os outros.
  Future<void> _abrirAjusteProduto(ProdutoNoRack produto) async {
    final saldo = widget.saldos[produto.produtoCodigo] ??
        (produto.produtoCodigo == _focoCodigo ? _saldo : null);
    final nova = await showDialog<double>(
      context: context,
      builder: (_) => _DialogAjustarQuantidade(
        rotulo: _rotulo,
        produto: produto,
        saldo: saldo,
        podeEsvaziar: widget.onRemoverProduto != null,
        rackMisto: true,
      ),
    );
    if (!mounted || nova == null || nova == produto.quantidade) return;
    if (nova == 0) {
      if (_focoCodigo == produto.produtoCodigo) _focoCodigo = null;
      widget.onRemoverProduto?.call(produto);
      return;
    }
    widget.onAjustarProduto?.call(produto, nova);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.toque;
    final rua = GalpaoConfig.ruaDe(t.posicao);
    final pilha = widget.pilhas[t.posicao] ?? const <RackGalpao>[];
    final rack = t.ocupado && t.ordem <= pilha.length
        ? pilha[t.ordem - 1]
        : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: const Color(0xF0141a22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF232f3a)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Endereço: no galpão, número global + nível derivado da ordem
              // na pilha; no barracão, o rótulo etiquetado no palete.
              Text(
                _rotulo,
                style: const TextStyle(
                  color: corCamda,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    widget.subtitulo ??
                        (rua == null
                            ? ''
                            : 'Rua ${rua.numero} · ${pilha.length} de '
                                  '${GalpaoConfig.niveisMax} na pilha'),
                    style: const TextStyle(
                      color: Color(0xFF8a9aa8),
                      fontSize: 12,
                    ),
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
          if (rack != null) _buildOcupado(rack) else _buildVazio(t),
        ],
      ),
    );
  }

  // ── Endereço ocupado ───────────────────────────────────────────────────────

  Widget _buildOcupado(RackGalpao rack) {
    if (_adicionando) return _buildAdicionando(rack);
    final pendente = rack.produtos.any(
      (p) => widget.codigosConferencia.contains(p.produtoCodigo),
    );
    final blocoSaldo = _blocoSaldo();
    final foco = rack.contem(_focoCodigo ?? '')
        ? _focoCodigo!
        : rack.produtoCodigo;
    final botaoDestaque = _botaoDestaque(foco);
    final estocado = codigoEhEstocado(rack.produtoCodigo);
    final cabeMais =
        rack.produtos.length < GalpaoConfig.produtosMaxPorRack;

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
                color: corConferenciaCiano.withValues(alpha: 0.55),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.fact_check_outlined,
                  size: 13,
                  color: corConferenciaCiano,
                ),
                SizedBox(width: 6),
                Text(
                  'Conferir hoje',
                  style: TextStyle(
                    color: corConferenciaCiano,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (rack.misto) _listaMisto(rack, foco) else ...[
          Text(
            rack.produtoNome.isEmpty ? rack.produtoCodigo : rack.produtoNome,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // O número é o botão, e é o único caminho de escrita do rack:
              // contar de novo e achar outro valor é a coisa mais comum que
              // acontece com um palete já endereçado, e 0 é o palete saindo.
              InkWell(
                onTap: widget.onAjustarQuantidade == null
                    ? null
                    : () => _abrirAjuste(rack),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        quantidadeEmUnidades(rack.quantidade),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (widget.onAjustarQuantidade != null) ...[
                        const SizedBox(width: 7),
                        const Padding(
                          padding: EdgeInsets.only(bottom: 3),
                          child: Icon(
                            Icons.edit_outlined,
                            size: 15,
                            color: corCamda,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Spacer(),
              Text(
                'cód. ${rack.produtoCodigo}',
                style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
              ),
            ],
          ),
        ],
        if (blocoSaldo != null) ...[const SizedBox(height: 8), blocoSaldo],
        if (widget.onAlternarDestaque != null && botaoDestaque != null) ...[
          const SizedBox(height: 8),
          botaoDestaque,
        ],
        // Só palete de estocado: o cooperado levou a mercadoria, a vaga
        // precisa voltar a ficar livre. Os demais racks seguem com o número
        // como única ação (0 esvazia), como descrito no README.
        if (estocado && widget.onEsvaziar != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _retirarEstocado(rack),
            icon: const Icon(Icons.output_outlined, size: 16),
            label: const Text('Retirar do endereço'),
            style: OutlinedButton.styleFrom(
              foregroundColor: corEnderecoDivergente,
              side: BorderSide(
                color: corEnderecoDivergente.withValues(alpha: 0.5),
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
        // Rack misto: sobrou pouco de um produto e ele vai junto no palete
        // de outro, em vez de ocupar uma gaiola sozinho. Estocado é material
        // de cooperado e não se mistura com o da loja.
        if (widget.onAdicionarProduto != null && !estocado && cabeMais) ...[
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () => setState(() => _adicionando = true),
            icon: const Icon(Icons.add, size: 16),
            label: Text(
              'Adicionar outro produto neste rack '
              '(${rack.produtos.length}/${GalpaoConfig.produtosMaxPorRack})',
            ),
            style: TextButton.styleFrom(
              foregroundColor: corCamda,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  /// Os produtos de um rack misto, um por linha: nome (toque põe o saldo
  /// dele na tarja), quantidade (toque abre o teclado — 0 tira só ele) e
  /// código.
  Widget _listaMisto(RackGalpao rack, String foco) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'RACK MISTO · ${pluralizar(rack.produtos.length, 'produto', 'produtos')}',
          style: const TextStyle(
            color: Color(0xFF8a9aa8),
            fontSize: 10,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        for (final p in rack.produtos)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
            decoration: BoxDecoration(
              color: p.produtoCodigo == foco
                  ? corCamda.withValues(alpha: 0.10)
                  : const Color(0xFF161c22),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: p.produtoCodigo == foco
                    ? corCamda.withValues(alpha: 0.5)
                    : const Color(0xFF232f3a),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _focarProduto(p.produtoCodigo),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.produtoNome.isEmpty
                              ? p.produtoCodigo
                              : p.produtoNome,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          'cód. ${p.produtoCodigo}',
                          style: const TextStyle(
                            color: Color(0xFF8a9aa8),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  onTap: widget.onAjustarProduto == null
                      ? null
                      : () => _abrirAjusteProduto(p),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          quantidadeEmUnidades(p.quantidade),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (widget.onAjustarProduto != null) ...[
                          const SizedBox(width: 5),
                          const Icon(
                            Icons.edit_outlined,
                            size: 14,
                            color: corCamda,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// O rack ocupado escolhendo o produto que vai entrar nele: a mesma busca
  /// do lançamento, sem os produtos que já estão no palete.
  Widget _buildAdicionando(RackGalpao rack) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.add_box_outlined, size: 16, color: corCamda),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mais um produto no mesmo palete — '
                '${rack.produtos.length} de '
                '${GalpaoConfig.produtosMaxPorRack} no rack.',
                style: const TextStyle(color: corCamda, fontSize: 12),
              ),
            ),
            GestureDetector(
              onTap: _cancelarAdicao,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Text(
                  'Cancelar',
                  style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ..._escolhaDeProduto(
          rotuloBotao: 'Adicionar em $_rotulo',
          onConfirmar: _adicionar,
          excluir: {for (final p in rack.produtos) p.produtoCodigo},
        ),
      ],
    );
  }

  /// Tira o palete de estocado do endereço depois de confirmar. A confirmação
  /// existe porque o toque é de um botão solto no painel, e porque, num rack
  /// com outros em cima, a pilha desce (o N2 vira N1).
  Future<void> _retirarEstocado(RackGalpao rack) async {
    final t = widget.toque;
    final pilha = widget.pilhas[t.posicao] ?? const <RackGalpao>[];
    final temAcima = t.ordem < pilha.length;
    final nome = rack.produtoNome.isEmpty ? rack.produtoCodigo : rack.produtoNome;
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1b1d21),
        title: Text(
          'Retirar $_rotulo?',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Text(
          '$nome\n\nA vaga fica livre. O item continua na lista de estocados '
          'do cooperado.'
          '${temAcima ? '\n\nOs paletes de cima descem um nível.' : ''}',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Retirar',
              style: TextStyle(color: corEnderecoDivergente),
            ),
          ),
        ],
      ),
    );
    if (confirmou == true && mounted) widget.onEsvaziar?.call();
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
  Widget? _blocoSaldo() {
    final saldo = _saldo;
    if (saldo == null) return null;

    // Uma unidade só nos dois lados da conta — a mesma do sistema e a mesma
    // que se digita ao lançar (ver unidades.dart).
    String fmt(double valor) => quantidadeEmUnidades(valor);

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

    // Caixa colorida SÓ quando há divergência: é aviso, e aviso que aparece
    // sempre vira moldura. Saldo que fecha é uma linha de texto quieta, com o
    // número do sistema junto — que é o que se quer conferir de relance.
    final alarme = saldo.falta || saldo.sobra;

    return Container(
      width: double.infinity,
      padding: alarme
          ? const EdgeInsets.symmetric(horizontal: 9, vertical: 7)
          : EdgeInsets.zero,
      decoration: alarme
          ? BoxDecoration(
              color: cor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: cor.withValues(alpha: 0.55)),
            )
          : null,
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
                  alarme
                      ? titulo
                      : '$titulo · sistema ${fmt(saldo.qtdSistema)}',
                  style: TextStyle(
                    color: cor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (alarme) ...[
                  const SizedBox(height: 2),
                  // Números crus: a unidade já está no título logo acima, e
                  // repeti-la duas vezes fazia a linha quebrar em duas.
                  Text(
                    'Sistema ${formatarNumero(saldo.qtdSistema)} · '
                    'endereçado ${formatarNumero(saldo.enderecado)}',
                    style: const TextStyle(
                      color: Color(0xFF8a9aa8),
                      fontSize: 11,
                    ),
                  ),
                ],
                // O sistema do produto soma mais de um código: dizer QUAIS é
                // o que faz o número conferir com o app do scanner na mão de
                // quem está olhando — sem isso, "sistema 559" num rack de
                // código US254185 parece número inventado.
                if (saldo.temCodigosSomados)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'códigos somados · ${saldo.codigosSomados.join(' + ')}',
                      style: const TextStyle(
                        color: Color(0xFF6b7a88),
                        fontSize: 10,
                      ),
                    ),
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
  ///
  /// Devolve null quando o produto só está NESTE lugar: acender uma posição
  /// só, com o painel dela já aberto, não mostra nada que não esteja na tela
  /// — e o botão ficava ali em todo rack, cobrando espaço sem servir.
  Widget? _botaoDestaque(String codigo) {
    final quantas = _posicoesDoProduto(codigo);
    final aceso = widget.destacadoCodigo == codigo;
    if (quantas <= 1 && !aceso) return null;

    return GestureDetector(
      onTap: () => widget.onAlternarDestaque?.call(codigo),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: aceso
              ? corCamda.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: aceso ? corCamda : Colors.white.withValues(alpha: 0.12),
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
                  ? 'Apagar destaque'
                  : 'Destacar ${pluralizar(quantas, 'posição', 'posições')}',
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
      if (pilha.any((r) => r.contem(codigo))) total++;
    }
    return total;
  }

  // ── Endereço vazio: lançar ─────────────────────────────────────────────────

  Widget _buildVazio(ToqueGalpao t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.check_box_outline_blank,
              size: 16,
              color: Color(0xFF6fcf97),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.textoVagaLivre ??
                    'Vaga livre — carga nova entra como N${t.ordem}, no topo '
                        'da pilha.',
                style: const TextStyle(color: Color(0xFF6fcf97), fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ..._escolhaDeProduto(
          rotuloBotao: 'Lançar em $_rotulo',
          onConfirmar: _lancar,
        ),
      ],
    );
  }

  /// Busca (ou recentes) → produto escolhido → quantidade → botão. É o miolo
  /// do lançamento numa vaga livre e da entrada de mais um produto num rack
  /// misto; [excluir] tira da lista o que não pode ser escolhido (os
  /// produtos que já estão no rack).
  List<Widget> _escolhaDeProduto({
    required String rotuloBotao,
    required VoidCallback onConfirmar,
    Set<String>? excluir,
  }) {
    final produto = _produtoSel;
    // Saldo do produto escolhido: quanto ainda falta endereçar é justamente o
    // que decide a quantidade a lançar neste palete.
    final blocoSaldo = produto == null ? null : _blocoSaldo();
    // No rack misto, estocado (material de cooperado) também fica de fora:
    // não se mistura com a mercadoria da loja.
    bool pode(Produto p) =>
        excluir == null ||
        (!excluir.contains(p.codigo) && !codigoEhEstocado(p.codigo));
    final resultados = [
      for (final p in _resultados)
        if (pode(p)) p,
    ];
    final recentes = [
      for (final r in widget.recentes)
        if (pode(r.produto)) r,
    ];

    return [
      if (produto == null) ...[
        TextField(
          controller: _buscaCtrl,
          onChanged: _aoDigitarBusca,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: _decoracaoCampo(
            'Buscar produto por nome ou código…',
            Icons.search,
          ),
        ),
        if (resultados.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              children: [
                for (final p in resultados)
                  InkWell(
                    onTap: () => _selecionarProduto(p),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
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
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Text(
                            p.codigo,
                            style: const TextStyle(
                              color: Color(0xFF8a9aa8),
                              fontSize: 10,
                            ),
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
              style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
            ),
          )
        else if (recentes.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              'ÚLTIMOS LANÇADOS',
              style: TextStyle(
                color: Color(0xFF8a9aa8),
                fontSize: 10,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final r in recentes)
                InkWell(
                  onTap: () =>
                      _selecionarProduto(r.produto, quantidade: r.quantidade),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161c22),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF232f3a)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
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
                              color: Colors.white,
                              fontSize: 11,
                            ),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF162416),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF2e6b46)),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
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
                    color: Color(0xFF6fcf97),
                    fontSize: 12,
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
                child: const Icon(
                  Icons.close,
                  size: 14,
                  color: Color(0xFF8a9aa8),
                ),
              ),
            ],
          ),
        ),
        if (blocoSaldo != null) ...[const SizedBox(height: 8), blocoSaldo],
        const SizedBox(height: 8),
        TextField(
          controller: _qtdCtrl,
          onChanged: (_) => setState(() {}),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
          ],
          style: const TextStyle(color: Colors.white, fontSize: 14),
          // Digita-se o que se CONTA — e é o mesmo número que o sistema
          // mostra. Não há mais conversão nenhuma no meio do caminho.
          decoration: _decoracaoCampo('Unidades', null),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _quantidadeDigitada == null ? null : onConfirmar,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2e6b46),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: Text(rotuloBotao),
          ),
        ),
      ],
    ];
  }

  InputDecoration _decoracaoCampo(String hint, IconData? icone) =>
      InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0x44ffffff), fontSize: 13),
        prefixIcon: icone == null
            ? null
            : Icon(icone, color: const Color(0xFF8a9aa8), size: 18),
        filled: true,
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
          borderSide: const BorderSide(color: Color(0xFF2e6b46), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        isDense: true,
      );
}

// ── Ajuste de quantidade ─────────────────────────────────────────────────────

/// Troca a quantidade de um rack que já está endereçado — e, com 0, tira o
/// palete do endereço.
///
/// Existe porque o caminho antigo para acertar um número era esvaziar e lançar
/// de novo — o que, num palete no meio da pilha, derruba todos os racks de
/// cima e renumera a pilha inteira (ver galpao_pilhas.dart) só para corrigir
/// uma digitação. Aqui o palete não sai do lugar.
///
/// E é aqui também que ele sai, quando é para sair: com [podeEsvaziar], 0 é
/// um valor aceito e o botão de salvar vira Esvaziar em vermelho, com o aviso
/// da descida da pilha. O painel não tem mais botão para isso — o teclado que
/// já se abre para conferir o número é o mesmo lugar onde se descobre que não
/// há mais nada no endereço.
///
/// Quando o produto está divergente do sistema, o dialog oferece de bandeja o
/// número que zera a diferença: é quase sempre ele que se quer digitar — o
/// caso de "sistema 57, endereçado 14,3, e este é o único palete do produto".
class _DialogAjustarQuantidade extends StatefulWidget {
  /// Nome do endereço, já montado pelo painel (ver
  /// [PainelEnderecoGalpao.rotuloEndereco]) — o dialog não sabe de que prédio
  /// veio o rack, só como o endereço se chama.
  final String rotulo;
  final ProdutoNoRack produto;
  final SaldoProduto? saldo;

  /// O produto é um entre vários do mesmo palete: 0 tira só ele, e o rack
  /// fica com os outros.
  final bool rackMisto;

  /// 0 é aceito e sai daqui como pedido de esvaziar. Falso (uso só de
  /// leitura, testes) mantém o dialog em correção de número.
  final bool podeEsvaziar;

  /// Há racks acima deste na pilha — o aviso do 0 precisa dizer que eles
  /// descem um nível.
  final bool temAcima;

  const _DialogAjustarQuantidade({
    required this.rotulo,
    required this.produto,
    required this.saldo,
    this.podeEsvaziar = false,
    this.temAcima = false,
    this.rackMisto = false,
  });

  @override
  State<_DialogAjustarQuantidade> createState() =>
      _DialogAjustarQuantidadeState();
}

class _DialogAjustarQuantidadeState extends State<_DialogAjustarQuantidade> {
  late final TextEditingController _ctrl = TextEditingController(
    text: formatarNumero(widget.produto.quantidade),
  );

  @override
  void initState() {
    super.initState();
    // Cursor selecionando tudo: o gesto seguinte é digitar o número certo por
    // inteiro, não emendar dígito no que já está lá.
    _ctrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _ctrl.text.length,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// O número digitado, ou null enquanto não dá para salvar. 0 só conta como
  /// número quando há como esvaziar — sem isso ele é campo vazio, e o botão
  /// fica desligado como antes.
  double? get _digitada {
    final q = double.tryParse(_ctrl.text.replaceAll(',', '.'));
    if (q == null || q < 0) return null;
    if (q == 0) return widget.podeEsvaziar ? 0 : null;
    return q;
  }

  /// Salvar aqui tira o palete do endereço, não corrige o número.
  bool get _esvaziando => _digitada == 0;

  /// A quantidade que faria o saldo do produto fechar com o sistema, se toda
  /// a diferença couber NESTE rack. Null quando fechar exigiria zerar o palete
  /// — tirar o palete é decisão de quem está olhando para ele, não sugestão.
  double? get _sugestao {
    final saldo = widget.saldo;
    if (saldo == null || saldo.fecha) return null;
    // Arredondado na casa da tolerância do saldo: a subtração de dois
    // doubles vindos de somas do banco produz "57.00000000000001", e o que
    // se oferece para digitar não pode ter cauda de ponto flutuante.
    final alvo =
        ((widget.produto.quantidade - saldo.diferenca) * 1000).roundToDouble() /
        1000;
    return alvo > 0 ? alvo : null;
  }

  @override
  Widget build(BuildContext context) {
    final rotulo = widget.rotulo;
    final sugestao = _sugestao;
    final digitada = _digitada;

    const corSaindo = Color(0xFFef5350);
    final esvaziando = _esvaziando;

    return AlertDialog(
      backgroundColor: const Color(0xFF141a22),
      title: Text(
        'Quantidade em $rotulo',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.produto.produtoNome.isEmpty
                ? widget.produto.produtoCodigo
                : widget.produto.produtoNome,
            style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
            ],
            style: const TextStyle(color: Colors.white, fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Unidades',
              hintStyle: const TextStyle(color: Color(0x44ffffff)),
              filled: true,
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
                borderSide: BorderSide(
                  color: esvaziando ? corSaindo : corCamda,
                  width: 1.5,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              isDense: true,
            ),
          ),
          // O 0 muda o que o botão faz, então tem de mudar o que o dialog
          // diz: quem digitou 0 sem querer precisa ler "o palete sai" antes
          // de encostar em Esvaziar.
          if (esvaziando) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: corSaindo.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: corSaindo.withValues(alpha: 0.55)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.remove_circle_outline,
                    size: 14,
                    color: corSaindo,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      widget.rackMisto
                          ? '0 tira este produto de $rotulo. Os outros '
                                'continuam no palete.'
                          : widget.temAcima
                          ? '0 tira o palete de $rotulo. Os racks de cima '
                                'descem um nível e a ordem é renumerada.'
                          : '0 tira o palete de $rotulo — o endereço fica '
                                'livre.',
                      style: const TextStyle(
                        color: corSaindo,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (sugestao != null && !esvaziando) ...[
            const SizedBox(height: 10),
            InkWell(
              onTap: () => setState(() {
                _ctrl.text = formatarNumero(sugestao);
                _ctrl.selection = TextSelection.collapsed(
                  offset: _ctrl.text.length,
                );
              }),
              borderRadius: BorderRadius.circular(7),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                decoration: BoxDecoration(
                  color: corCamda.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: corCamda.withValues(alpha: 0.55)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.auto_fix_high, size: 14, color: corCamda),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Usar ${formatarNumero(sugestao)} — fecha com o '
                        'sistema',
                        style: const TextStyle(
                          color: corCamda,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            widget.podeEsvaziar
                ? 'Estava com ${quantidadeEmUnidades(widget.produto.quantidade)}. '
                      '${widget.rackMisto ? 'Digite 0 para tirar este produto do rack.' : 'Digite 0 para tirar o palete inteiro.'}'
                : 'Estava com '
                      '${quantidadeEmUnidades(widget.produto.quantidade)}.',
            style: const TextStyle(color: Color(0xFF6b7a88), fontSize: 11),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: digitada == null
              ? null
              : () => Navigator.pop(context, digitada),
          child: Text(
            esvaziando ? (widget.rackMisto ? 'Tirar' : 'Esvaziar') : 'Salvar',
            style: TextStyle(
              color: esvaziando ? corSaindo : corCamda,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
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
  final bool ativo;
  final VoidCallback onTap;

  const _ToggleSaldoGalpao({required this.ativo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        width: 46,
        decoration: BoxDecoration(
          color: ativo
              ? corCamda.withValues(alpha: 0.18)
              : const Color(0xEE141518),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: ativo ? corCamda : Colors.white.withValues(alpha: 0.10),
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
    // Legenda das cores do mapa, não relatório: rótulo curto para caber numa
    // linha só mesmo com os dois lados acesos. O detalhe por produto está no
    // painel do endereço, que é onde a pergunta 'quanto falta neste?' nasce.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xEE141518),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          // Ícone contornado, o mesmo do botão apagado: o botão da barra fica
          // sólido quando a leitura está ligada, e duas balanças sólidas na
          // tela ao mesmo tempo confundem qual delas é o interruptor.
          const Icon(
            Icons.balance_outlined,
            size: 13,
            color: Color(0xFF8a877f),
          ),
          const SizedBox(width: 8),
          if (comFalta > 0)
            Flexible(
              child: _legenda(corEnderecoDivergente, '$comFalta por endereçar'),
            ),
          if (comFalta > 0 && comSobra > 0) const SizedBox(width: 12),
          if (comSobra > 0)
            Flexible(
              child: _legenda(
                corEnderecoDivergentePositiva,
                '$comSobra acima do sistema',
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
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: cor,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          texto,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 11),
        ),
      ),
    ],
  );
}

class _ToggleConferenciaGalpao extends StatelessWidget {
  final bool ativo;
  final VoidCallback onTap;

  const _ToggleConferenciaGalpao({required this.ativo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        width: 46,
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
  final bool carregando;
  final ModoConferenciaResultado? resultado;
  final VoidCallback? onRefresh;

  const _BannerConferenciaGalpao({
    required this.carregando,
    required this.resultado,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final r = resultado;
    final vazio = !carregando && (r == null || r.galpaoVazioHoje);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xE60d2226),
        border: Border.all(color: corConferenciaCiano.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            vazio ? Icons.celebration_outlined : Icons.fact_check_outlined,
            color: corConferenciaCiano,
            size: 15,
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
              icon: const Icon(
                Icons.refresh,
                size: 16,
                color: Color(0xFF8a9aa8),
              ),
              onPressed: onRefresh,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Atualizar',
            ),
          ],
        ],
      ),
    );
  }
}

class _BotaoRedondo extends StatelessWidget {
  final IconData icone;
  final VoidCallback onTap;

  const _BotaoRedondo({required this.icone, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        width: 46,
        decoration: BoxDecoration(
          color: const Color(0xEE141518),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Icon(icone, color: const Color(0xFF8a877f), size: 20),
      ),
    );
  }
}
