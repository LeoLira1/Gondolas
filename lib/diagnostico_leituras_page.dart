import 'package:flutter/material.dart';

import 'leituras_turso.dart';
import 'turso_service.dart';

/// ⚙️ → Leituras deste aparelho: quantas consultas e linhas ESTE aparelho
/// pediu ao Turso, por dia e por tipo (ver leituras_turso.dart). O gráfico de
/// Rows Read do Turso soma a conta inteira — dashboards, o app Contagem e
/// todos os aparelhos —, então é daqui que sai quanto é do Gôndolas.
class DiagnosticoLeiturasPage extends StatefulWidget {
  const DiagnosticoLeiturasPage({super.key, this.contador, this.agora});

  /// O contador a mostrar; sem ele, o do app ([TursoService.leituras]).
  final ContadorDeLeituras? contador;

  /// O relógio do "Hoje" (testes); sem ele, [DateTime.now].
  final DateTime Function()? agora;

  @override
  State<DiagnosticoLeiturasPage> createState() =>
      _DiagnosticoLeiturasPageState();
}

/// Nome legível de cada tipo de leitura. Tipo sem nome aparece cru.
const Map<String, String> nomesDasLeituras = {
  'quantidades_detalhes_v2': 'Quantidades (estoque_localizado inteiro)',
  'quantidades_locais': 'Quantidades de um local gravado',
  'quantidades_produto': 'Quantidades de um produto salvo',
  'saldos_dialogo_v1': 'Cadastro (estoque_mestre inteiro)',
  'vinculos_mapa_produtos': 'Mapa de produtos',
  'vinculos_mapa_produtos_codigos': 'Mapa de produtos (códigos)',
  'layouts_gondola_v1': 'Layouts das gôndolas (tabela inteira)',
  'layouts_estante_v1': 'Layouts das estantes (tabela inteira)',
  'layout_estrutura': 'Uma gôndola/estante (pelo índice)',
  'salvar_layout': 'Salvar layout (conferência)',
  'galpao': 'Galpão (racks)',
  'galpao_posicoes': 'Galpão (posições gravadas)',
  'barracao': 'Barracão (paletes)',
  'barracao_seed': 'Barracão (conferência da planta)',
  'estocados': 'Estocados (materiais_terceiros)',
  'ultima_contagem_itens_confirmado_em': 'Contagens do app Contagem',
  'ultima_contagem_itens_registrado_em': 'Contagens do app Contagem',
  'ultima_contagem_ciclico_v1': 'Inventário cíclico',
  'divergentes_ciclo_v1': 'Divergências do ciclo',
  'contagem_concluida': 'Concluir contagem',
  'conferencia_pendentes': 'Modo Conferência (pendentes)',
  'conferencia_enderecos': 'Modo Conferência (endereços)',
  'baixa_enderecos': 'Baixa automática (endereços)',
  'baixa_divergencias': 'Baixa automática (divergências)',
  'enderecos_produto': 'Endereços de um produto',
  'info_mestre': 'Cadastro de um produto',
  'busca_na_cena': 'Buscar dentro da gôndola/estante',
  'paletes': 'Cadastro de paletes',
  'indices_conferencia': 'Conferência dos índices',
  'medicao_tabelas': 'Medição das tabelas (este botão)',
  'gravacao_estado_anterior': 'Gravações (estado anterior)',
  'sem_resposta': 'Sem resposta (estimado pela cópia)',
  'leitura_avulsa': 'Outras leituras',
};

class _DiagnosticoLeiturasPageState extends State<DiagnosticoLeiturasPage> {
  List<({String dia, Map<String, LeiturasDoTipo> tipos})> _dias = const [];
  Map<String, int> _tamanhos = const {};
  DateTime? _medidoEm;
  int _diaEscolhido = 0;
  bool _carregando = true;
  bool _medindo = false;

  @override
  void initState() {
    super.initState();
    _carregar();
    final medicao = TursoService().medindoTabelas
        ? TursoService().medirTabelas()
        : null;
    if (medicao != null) {
      // Saiu e voltou durante uma medição: mostra-a até o fim.
      _medindo = true;
      _esperarMedicao(medicao);
    }
  }

  ContadorDeLeituras get _contador =>
      widget.contador ?? TursoService().leituras;

  Future<void> _carregar() async {
    final turso = TursoService();
    final dias = await _contador.dias();
    final medida = await turso.tamanhosDasTabelas();
    if (!mounted) return;
    setState(() {
      _dias = dias;
      _tamanhos = medida.tamanhos;
      _medidoEm = medida.em;
      _diaEscolhido = _diaEscolhido.clamp(0, dias.isEmpty ? 0 : dias.length - 1);
      _carregando = false;
    });
  }

  Future<void> _medir() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Medir as tabelas?',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: const Text(
          'Conta as linhas das tabelas que algumas consultas varrem inteiras '
          '(agrupam ou filtram sem índice). É o que permite estimar o que o '
          'Turso cobra delas.\n\n'
          'Contar custa, uma vez, a leitura dessas tabelas inteiras (a soma '
          'aparece aqui depois). Basta medir de vez em quando.',
          style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Medir'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _medindo = true);
    await _esperarMedicao(TursoService().medirTabelas());
  }

  Future<void> _esperarMedicao(Future<void> medicao) async {
    String? erro;
    try {
      await medicao;
    } catch (e) {
      erro = 'Não deu para medir todas agora. Confira a conexão.';
    }
    if (!mounted) return;
    setState(() => _medindo = false);
    if (erro != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(erro),
        backgroundColor: const Color(0xFF8b1a1a),
      ));
    }
    await _carregar();
  }

  Future<void> _zerar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Zerar a contagem?',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: const Text(
          'Apaga as leituras dos últimos dias contadas neste aparelho.',
          style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Zerar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _contador.zerar();
    await _carregar();
  }

  static String _milhar(int n) {
    final s = n.abs().toString();
    final b = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
      b.write(s[i]);
    }
    return b.toString();
  }

  String _diaLegivel(String dia, int indice) {
    final partes = dia.split('-');
    final curto = partes.length == 3 ? '${partes[2]}/${partes[1]}' : dia;
    final agora = (widget.agora ?? DateTime.now)();
    if (indice == 0 && dia == ContadorDeLeituras.diaDe(agora)) {
      return 'Hoje';
    }
    return curto;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0e1014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0e1014),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8a9aa8)),
        title: const Text(
          'Leituras deste aparelho',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        actions: [
          IconButton(
            tooltip: 'Zerar a contagem',
            icon: const Icon(Icons.delete_outline, color: Color(0xFF8a9aa8)),
            onPressed: _carregando ? null : _zerar,
          ),
        ],
      ),
      body: _carregando
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF4a9d6a)),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'O gráfico de Rows Read do Turso soma a conta inteira: os '
                  'dashboards, o app Contagem e todos os aparelhos. Aqui está só '
                  'o que ESTE aparelho pediu, por dia.',
                  style: TextStyle(
                    color: Color(0xFF8a9aa8),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                if (_dias.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Nenhuma leitura contada ainda.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF5a6a78)),
                    ),
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < _dias.length; i++)
                        ChoiceChip(
                          label: Text(_diaLegivel(_dias[i].dia, i)),
                          selected: i == _diaEscolhido,
                          onSelected: (_) => setState(() => _diaEscolhido = i),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _resumoDoDia(_dias[_diaEscolhido].tipos),
                ],
                const SizedBox(height: 20),
                _tabelas(),
              ],
            ),
    );
  }

  Widget _resumoDoDia(Map<String, LeiturasDoTipo> tipos) {
    final semTamanho = <String>{};
    final varridas = estimarVarridas(tipos, _tamanhos, semTamanho: semTamanho);
    final consultas = tipos.values.fold<int>(0, (s, t) => s + t.consultas);
    final devolvidas = tipos.values.fold<int>(0, (s, t) => s + t.linhas);

    int varridasDoTipo(String tipo, LeiturasDoTipo l) {
      final tabela = tabelaVarridaPor(tipo);
      final tamanho = tabela == null ? null : _tamanhos[tabela];
      return tamanho == null ? l.linhas : l.consultas * tamanho;
    }

    final ordem = tipos.entries.toList()
      ..sort(
        (a, b) => varridasDoTipo(
          b.key,
          b.value,
        ).compareTo(varridasDoTipo(a.key, a.value)),
      );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF0d1117),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF232f3a)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '≈ ${_milhar(varridas)} linhas lidas',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_milhar(consultas)} consultas · '
                '${_milhar(devolvidas)} linhas devolvidas',
                style: const TextStyle(color: Color(0xFF8a9aa8), fontSize: 12),
              ),
              if (semTamanho.isNotEmpty) ...[
                const SizedBox(height: 6),
                const Text(
                  'Sem a medida das tabelas, as consultas que varrem a tabela '
                  'inteira contam só o que devolveram — o real é maior. Use '
                  '"Medir as tabelas" abaixo.',
                  style: TextStyle(
                    color: Color(0xFFe0a33e),
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        for (final e in ordem)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nomesDasLeituras[e.key] ?? e.key,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '${_milhar(e.value.consultas)} consultas'
                        '${tabelaVarridaPor(e.key) != null ? ' · varre a tabela ${tabelaVarridaPor(e.key)}' : ''}',
                        style: const TextStyle(
                          color: Color(0xFF5a6a78),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _milhar(varridasDoTipo(e.key, e.value)),
                  style: const TextStyle(
                    color: Color(0xFF8a9aa8),
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _tabelas() {
    final em = _medidoEm;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0d1117),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF232f3a)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            em == null
                ? 'Tamanho das tabelas: ainda não medido'
                : 'Tamanho das tabelas (medido em '
                      '${em.day.toString().padLeft(2, '0')}/'
                      '${em.month.toString().padLeft(2, '0')})',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          const SizedBox(height: 8),
          for (final e in _tamanhos.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      e.key,
                      style: const TextStyle(
                        color: Color(0xFF8a9aa8),
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Text(
                    _milhar(e.value),
                    style: const TextStyle(
                      color: Color(0xFF8a9aa8),
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _medindo ? null : _medir,
            icon: _medindo
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF4a9d6a),
                    ),
                  )
                : const Icon(Icons.straighten, size: 15),
            label: Text(_medindo ? 'Medindo...' : 'Medir as tabelas'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF4a9d6a),
              side: const BorderSide(color: Color(0xFF2e4a38)),
            ),
          ),
        ],
      ),
    );
  }
}
