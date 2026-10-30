import 'package:flutter/material.dart';

import 'codigos_vinculados.dart' show chaveNomeProduto;
import 'onde_esta.dart';
import 'repor_loja.dart';

const _cartao = Color(0xFF161a20);
const _cinza = Color(0xFF8a9aa8);
const _azul = Color(0xFF7aa7e8);
const _laranja = Color(0xFFe8a022);

/// Aba "Repor loja" da tela de Etiquetas: a lista do camda-estoque, só
/// leitura. Tocar no nome mostra onde o produto está nos mapas.
class ReporLojaTab extends StatefulWidget {
  final AbrirEndereco? abrirEndereco;

  /// Para teste: troca a leitura do banco.
  final Future<List<ItemReporLoja>> Function()? buscar;

  const ReporLojaTab({super.key, this.abrirEndereco, this.buscar});

  @override
  State<ReporLojaTab> createState() => ReporLojaTabState();
}

class ReporLojaTabState extends State<ReporLojaTab>
    with AutomaticKeepAliveClientMixin {
  final _filtro = TextEditingController();
  bool _carregando = false;
  String? _erro;
  List<ItemReporLoja>? _itens;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    recarregar();
  }

  @override
  void dispose() {
    _filtro.dispose();
    super.dispose();
  }

  Future<void> recarregar() async {
    setState(() {
      _carregando = true;
      _erro = null;
    });
    try {
      final itens = await (widget.buscar ?? const ReporLojaService().buscar)();
      if (!mounted) return;
      setState(() {
        _itens = itens;
        _carregando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = 'Não consegui buscar a lista do Repor loja: $e';
        _carregando = false;
      });
    }
  }

  List<ItemReporLoja> get _visiveis {
    final itens = _itens ?? const <ItemReporLoja>[];
    final termos = chaveNomeProduto(_filtro.text)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toList();
    if (termos.isEmpty) return itens;
    return [
      for (final i in itens)
        if (termos.every((t) => chaveNomeProduto(
                '${i.codigo} ${i.produto} ${i.categoria}')
            .contains(t)))
          i,
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final itens = _itens;
    final visiveis = _visiveis;
    return Column(children: [
      if (_carregando) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: RefreshIndicator(
          onRefresh: recarregar,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (_erro != null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_erro!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _cinza)),
                )
              else if (itens != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Text(
                    '${itens.length} produtos · '
                    '${itens.fold<int>(0, (s, i) => s + i.repor)} unidades '
                    'a repor',
                    style: const TextStyle(color: _cinza),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: TextField(
                    controller: _filtro,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Filtrar por produto, código ou categoria',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _filtro.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () =>
                                  setState(() => _filtro.clear()),
                            ),
                      filled: true,
                      fillColor: _cartao,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                if (itens.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Nada para repor agora. 🎉',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _cinza)),
                  )
                else if (visiveis.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Nenhum produto com esse filtro.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _cinza)),
                  ),
                for (final i in visiveis) _linha(i),
              ],
            ],
          ),
        ),
      ),
    ]);
  }

  Widget _linha(ItemReporLoja i) {
    final idade = i.idade(DateTime.now());
    final saldo = i.saldoSistema == i.saldoSistema.roundToDouble()
        ? i.saldoSistema.round().toString()
        : i.saldoSistema.toString();
    final abrir = widget.abrirEndereco;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: _cartao,
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: abrir == null
            ? null
            : () => mostrarOndeEsta(context,
                codigo: i.codigo, nome: i.produto, abrir: abrir),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(i.produto,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Wrap(spacing: 8, children: [
                    Text(i.codigo,
                        style: const TextStyle(color: _cinza, fontSize: 12)),
                    if (i.categoria.isNotEmpty)
                      Text(i.categoria,
                          style:
                              const TextStyle(color: _cinza, fontSize: 12)),
                    if (idade.isNotEmpty)
                      Text(idade,
                          style: const TextStyle(color: _azul, fontSize: 12)),
                  ]),
                  const SizedBox(height: 3),
                  Wrap(spacing: 10, children: [
                    Text('Estoque: $saldo',
                        style: TextStyle(
                            color: i.saldoSistema < i.repor ? _laranja : _cinza,
                            fontSize: 12)),
                    if (abrir != null)
                      const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.place_outlined, size: 14, color: _azul),
                        Text(' onde está',
                            style: TextStyle(color: _azul, fontSize: 12)),
                      ]),
                  ]),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 58,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF20252d),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(children: [
                const Text('REPOR',
                    style: TextStyle(color: _cinza, fontSize: 10)),
                Text('${i.repor}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
