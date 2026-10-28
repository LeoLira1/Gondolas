import 'dart:async';

import 'package:flutter/material.dart';

import 'etiquetas_vendidos.dart';
import 'etiquetas_vendidos_service.dart';
import 'zebra_bluetooth.dart';

/// Tela "Etiquetas – Vendidos": lista os produtos vendidos num dia que ficam
/// na loja (mesma regra da ferramenta etiquetas_vendidos_loja do MCP) e
/// imprime direto na Zebra ZT410 por Bluetooth clássico, um comando por vez.
class EtiquetasVendidosPage extends StatefulWidget {
  const EtiquetasVendidosPage({super.key});

  @override
  State<EtiquetasVendidosPage> createState() => _EtiquetasVendidosPageState();
}

enum _Status { pendente, enviando, ok, erro }

/// Um envio da fila: [idx] = posição na lista (null = etiqueta de teste).
typedef _Envio = ({int? idx, String zpl});

const _fundo = Color(0xFF0e1014);
const _cartao = Color(0xFF161a20);
const _verde = Color(0xFF2e6b46);
const _verdeClaro = Color(0xFF4a9d6a);
const _cinza = Color(0xFF8a9aa8);
const _laranja = Color(0xFFe8a022);

class _EtiquetasVendidosPageState extends State<EtiquetasVendidosPage> {
  final _service = const EtiquetasVendidosService();
  final _zebra = ZebraBluetooth.instance;

  DateTime _dia = EtiquetasVendidosService.hojeBrasilia();
  bool _carregando = false;
  String? _erroBusca;
  ResultadoEtiquetasVendidos? _res;
  final Set<int> _marcados = {};
  final Map<int, _Status> _status = {};

  String? _impressora;

  bool _imprimindo = false;
  bool _parar = false;
  String? _progresso;
  String? _erroImpressao;
  List<_Envio> _restante = const [];

  @override
  void initState() {
    super.initState();
    _carregarImpressora();
    _buscar();
  }

  @override
  void dispose() {
    _parar = true;
    unawaited(_zebra.desconectar());
    super.dispose();
  }

  Future<void> _carregarImpressora() async {
    final salva = await _zebra.impressoraSalva();
    if (mounted) setState(() => _impressora = salva?.nome);
  }

  // ── Dados ────────────────────────────────────────────────────────────────

  Future<void> _buscar() async {
    setState(() {
      _carregando = true;
      _erroBusca = null;
      _erroImpressao = null;
      _progresso = null;
      _restante = const [];
      _status.clear();
    });
    try {
      final r = await _service.buscar(_dia);
      if (!mounted) return;
      setState(() {
        _res = r;
        _marcados
          ..clear()
          ..addAll(List.generate(r.produtos.length, (i) => i));
        _carregando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _res = null;
        _marcados.clear();
        _erroBusca = 'Não consegui buscar as vendas: $e';
        _carregando = false;
      });
    }
  }

  Future<void> _escolherDia() async {
    final hoje = EtiquetasVendidosService.hojeBrasilia();
    final escolhido = await showDatePicker(
      context: context,
      initialDate: _dia,
      firstDate: DateTime(2024),
      lastDate: hoje,
      helpText: 'Dia das vendas',
    );
    if (escolhido == null || !mounted) return;
    setState(() => _dia = escolhido);
    await _buscar();
  }

  static String _dataBr(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  // ── Impressora ───────────────────────────────────────────────────────────

  /// Lista os pareados para o usuário escolher a Zebra. Devolve o endereço.
  Future<String?> _escolherImpressora() async {
    try {
      final lista = await _zebra.pareados();
      if (!mounted) return null;
      if (lista.isEmpty) {
        _aviso('Nenhum dispositivo pareado. Pareie a Zebra nas configurações '
            'de Bluetooth do Android e tente de novo.');
        return null;
      }
      final escolhido = await showDialog<({String endereco, String nome})>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _cartao,
          title: const Text('Escolha a impressora'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final d in lista)
                  ListTile(
                    leading: const Icon(Icons.print_outlined),
                    title: Text(ZebraBluetooth.nomeDe(d)),
                    subtitle: Text(d.address),
                    onTap: () => Navigator.pop(ctx,
                        (endereco: d.address, nome: ZebraBluetooth.nomeDe(d))),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
          ],
        ),
      );
      if (escolhido == null) return null;
      await _zebra.salvarImpressora(escolhido.endereco, escolhido.nome);
      if (mounted) setState(() => _impressora = escolhido.nome);
      return escolhido.endereco;
    } on ZebraErro catch (e) {
      _aviso(e.mensagem);
      return null;
    }
  }

  Future<void> _abrirConfiguracoes() async {
    var intervalo = await _zebra.intervaloMs();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _cartao,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Impressora Zebra',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(children: [
                  const Icon(Icons.print_outlined, color: _cinza),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_impressora ?? 'Nenhuma escolhida',
                        style: const TextStyle(color: _cinza)),
                  ),
                  TextButton(
                    onPressed: () async {
                      await _escolherImpressora();
                      setSheet(() {});
                    },
                    child: const Text('Trocar'),
                  ),
                  if (_impressora != null)
                    TextButton(
                      onPressed: () async {
                        await _zebra.esquecerImpressora();
                        if (mounted) setState(() => _impressora = null);
                        setSheet(() {});
                      },
                      child: const Text('Esquecer'),
                    ),
                ]),
                const SizedBox(height: 16),
                Text(
                  'Intervalo entre etiquetas: '
                  '${(intervalo / 1000).toStringAsFixed(1)} s',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Slider(
                  value: intervalo.toDouble(),
                  min: 500,
                  max: 5000,
                  divisions: 45,
                  label: '${(intervalo / 1000).toStringAsFixed(1)} s',
                  onChanged: (v) => setSheet(() => intervalo = v.round()),
                  onChangeEnd: (v) => _zebra.salvarIntervaloMs(v.round()),
                ),
                const Text(
                  'Se a impressora cortar ou pular etiquetas, aumente. '
                  'Padrão: 1,5 s.',
                  style: TextStyle(color: _cinza, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Impressão ────────────────────────────────────────────────────────────

  Future<void> _imprimirTodas() {
    final fila = <_Envio>[
      for (final i in _marcados.toList()..sort())
        (idx: i, zpl: _res!.produtos[i].zpl),
    ];
    setState(() {
      for (final e in fila) {
        _status[e.idx!] = _Status.pendente;
      }
    });
    return _executar(fila);
  }

  Future<void> _imprimirItem(int i) =>
      _executar([(idx: i, zpl: _res!.produtos[i].zpl)]);

  Future<void> _imprimirTeste() => _executar([(idx: null, zpl: zplTeste())]);

  Future<void> _continuar() => _executar(_restante);

  Future<void> _executar(List<_Envio> fila) async {
    if (fila.isEmpty || _imprimindo) return;
    setState(() {
      _imprimindo = true;
      _parar = false;
      _erroImpressao = null;
      _restante = const [];
      _progresso = 'Conectando na impressora…';
    });

    var endereco = (await _zebra.impressoraSalva())?.endereco;
    endereco ??= await _escolherImpressora();
    if (endereco == null) {
      if (mounted) {
        setState(() {
          _imprimindo = false;
          _progresso = null;
        });
      }
      return;
    }

    var enviadas = 0;
    try {
      await _zebra.conectar(endereco);
      final intervalo = Duration(milliseconds: await _zebra.intervaloMs());
      for (var k = 0; k < fila.length; k++) {
        if (_parar || !mounted) {
          _restante = fila.sublist(k);
          break;
        }
        final envio = fila[k];
        setState(() {
          _progresso = fila.length == 1 && envio.idx == null
              ? 'Imprimindo teste…'
              : 'Imprimindo ${k + 1} de ${fila.length}…';
          if (envio.idx != null) _status[envio.idx!] = _Status.enviando;
        });
        try {
          await _zebra.enviar(envio.zpl);
        } on ZebraErro catch (e) {
          if (!mounted) return;
          setState(() {
            if (envio.idx != null) _status[envio.idx!] = _Status.erro;
            final qual = envio.idx == null
                ? 'etiqueta de teste'
                : '${_res!.produtos[envio.idx!].descricao} '
                    '(${_res!.produtos[envio.idx!].codigo})';
            _erroImpressao = 'Erro na ${k + 1}ª de ${fila.length}: $qual.\n'
                '${e.mensagem}';
            _restante = fila.sublist(k);
          });
          break;
        }
        enviadas++;
        if (!mounted) return;
        setState(() {
          if (envio.idx != null) _status[envio.idx!] = _Status.ok;
        });
        if (k < fila.length - 1) await Future<void>.delayed(intervalo);
      }
    } on ZebraErro catch (e) {
      if (mounted) {
        setState(() {
          _erroImpressao = e.mensagem;
          _restante = fila;
        });
      }
    } finally {
      // Libera a impressora para o Serial Bluetooth Terminal.
      await _zebra.desconectar();
    }
    if (!mounted) return;
    setState(() {
      _imprimindo = false;
      if (_erroImpressao != null) {
        _progresso = null;
      } else if (_restante.isNotEmpty) {
        _progresso = 'Parado: $enviadas de ${fila.length} enviadas.';
      } else {
        _progresso = fila.length == 1 && fila.first.idx == null
            ? 'Teste enviado ✅'
            : 'Pronto: $enviadas de ${fila.length} enviadas ✅';
      }
    });
  }

  void _aviso(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final produtos = _res?.produtos ?? const <EtiquetaVendido>[];
    return PopScope(
      canPop: !_imprimindo,
      child: Scaffold(
        backgroundColor: _fundo,
        appBar: AppBar(
          backgroundColor: _fundo,
          elevation: 0,
          title: const Text('Etiquetas – Vendidos',
              style: TextStyle(fontSize: 17)),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh, color: _cinza),
              tooltip: 'Buscar de novo',
              onPressed: _carregando || _imprimindo ? null : _buscar,
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined, color: _cinza),
              tooltip: 'Impressora e intervalo',
              onPressed: _imprimindo ? null : _abrirConfiguracoes,
            ),
          ],
        ),
        body: Column(children: [
          if (_carregando) const LinearProgressIndicator(minHeight: 2),
          _barraTopo(),
          if (_erroImpressao != null) _bannerErro(),
          Expanded(child: _lista(produtos)),
        ]),
        bottomNavigationBar: _rodape(produtos),
      ),
    );
  }

  Widget _barraTopo() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(children: [
        OutlinedButton.icon(
          onPressed: _carregando || _imprimindo ? null : _escolherDia,
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(_dataBr(_dia)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _impressora == null ? 'Sem impressora' : '🖨️ $_impressora',
            style: const TextStyle(color: _cinza, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton.icon(
          onPressed: _imprimindo ? null : _imprimirTeste,
          icon: const Icon(Icons.print_outlined, size: 18),
          label: const Text('Imprimir teste'),
        ),
      ]),
    );
  }

  Widget _bannerErro() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3a1d1d),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFb04a4a)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('⚠️ $_erroImpressao',
              style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            if (_restante.isNotEmpty)
              FilledButton.icon(
                onPressed: _imprimindo ? null : _continuar,
                style: FilledButton.styleFrom(backgroundColor: _verde),
                icon: const Icon(Icons.play_arrow),
                label: Text('Continuar daqui (${_restante.length})'),
              ),
            OutlinedButton(
              onPressed: _imprimindo ? null : _escolherImpressora,
              child: const Text('Trocar impressora'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _lista(List<EtiquetaVendido> produtos) {
    if (_erroBusca != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_erroBusca!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _cinza)),
        ),
      );
    }
    final res = _res;
    if (res == null) return const SizedBox.shrink();
    final todos = produtos.isNotEmpty && _marcados.length == produtos.length;

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (res.produtosVendidos == 0)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nenhuma venda registrada nesse dia.',
                textAlign: TextAlign.center, style: TextStyle(color: _cinza)),
          )
        else if (produtos.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nenhum vendido desse dia fica nas gôndolas/estantes '
                'que levam etiqueta.',
                textAlign: TextAlign.center, style: TextStyle(color: _cinza)),
          )
        else
          CheckboxListTile(
            value: todos,
            onChanged: _imprimindo
                ? null
                : (v) => setState(() {
                      _marcados.clear();
                      if (v == true) {
                        _marcados.addAll(
                            List.generate(produtos.length, (i) => i));
                      }
                    }),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Text(
              '${produtos.length} produtos · ${_marcados.length} marcados',
              style: const TextStyle(color: _cinza),
            ),
          ),
        for (var i = 0; i < produtos.length; i++) _linha(i, produtos[i]),
        if (res.fora.isNotEmpty)
          _recolhivel(
            'Ficaram de fora (${res.fora.length})',
            [
              for (final f in res.fora)
                '${f.descricao} (${f.codigo}) — ${f.motivo}',
            ],
          ),
        if (res.avisos.isNotEmpty)
          _recolhivel('Avisos (${res.avisos.length})', res.avisos),
      ],
    );
  }

  Widget _linha(int i, EtiquetaVendido p) {
    final st = _status[i];
    Widget? icone;
    switch (st) {
      case _Status.ok:
        icone = const Text('✅', style: TextStyle(fontSize: 18));
      case _Status.erro:
        icone = const Text('⚠️', style: TextStyle(fontSize: 18));
      case _Status.enviando:
        icone = const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2));
      case _Status.pendente:
      case null:
        icone = null;
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: _cartao,
        borderRadius: BorderRadius.circular(10),
        border: st == _Status.erro
            ? Border.all(color: const Color(0xFFb04a4a))
            : null,
      ),
      child: Row(children: [
        Checkbox(
          value: _marcados.contains(i),
          onChanged: _imprimindo
              ? null
              : (v) => setState(() =>
                  v == true ? _marcados.add(i) : _marcados.remove(i)),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.descricao,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  '${p.codigo} · ${p.local} · etiqueta: ${p.textoEtiqueta}',
                  style: const TextStyle(color: _cinza, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        if (icone != null)
          Padding(padding: const EdgeInsets.only(left: 4), child: icone),
        IconButton(
          icon: const Icon(Icons.print_outlined, color: _laranja, size: 20),
          tooltip: 'Reimprimir esta',
          onPressed: _imprimindo ? null : () => _imprimirItem(i),
        ),
      ]),
    );
  }

  Widget _recolhivel(String titulo, List<String> linhas) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Container(
        decoration: BoxDecoration(
          color: _cartao,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            title: Text(titulo,
                style: const TextStyle(color: _cinza, fontSize: 14)),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final l in linhas)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text('• $l',
                      style: const TextStyle(color: _cinza, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rodape(List<EtiquetaVendido> produtos) {
    final n = _marcados.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_progresso != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(_progresso!,
                    style: const TextStyle(
                        color: _verdeClaro, fontWeight: FontWeight.w600)),
              ),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: _imprimindo
                  ? OutlinedButton.icon(
                      onPressed: _parar ? null : () => setState(() => _parar = true),
                      icon: const Icon(Icons.stop),
                      label: Text(_parar ? 'Parando…' : 'Parar'),
                    )
                  : FilledButton.icon(
                      onPressed: n == 0 || _carregando ? null : _imprimirTodas,
                      style: FilledButton.styleFrom(
                        backgroundColor: _verde,
                        textStyle: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      icon: const Icon(Icons.print),
                      label: Text('Imprimir todas ($n)'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
