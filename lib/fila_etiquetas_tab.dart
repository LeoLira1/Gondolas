import 'package:flutter/material.dart';

import 'codigos_vinculados.dart' show chaveNomeProduto;
import 'fila_etiquetas_loja.dart';
import 'onde_esta.dart';

const _cartao = Color(0xFF161a20);
const _cinza = Color(0xFF8a9aa8);
const _azul = Color(0xFF7aa7e8);
const _verdeClaro = Color(0xFF4a9d6a);

/// Aba "Etiquetas" da tela Repor loja: a fila do app Etiquetas CAMDA.
/// Tocar no produto mostra onde ele fica (gôndola, estante…) para levar a
/// etiqueta; o ✓ marca "coloquei na prateleira", só neste celular.
class FilaEtiquetasTab extends StatefulWidget {
  final AbrirEndereco? abrirEndereco;

  /// Para teste: troca a leitura do banco.
  final Future<List<ItemFilaEtiqueta>> Function()? buscar;

  /// Para teste: troca onde ficam as marcas "coloquei".
  final Future<Set<String>> Function()? lerColocadas;
  final Future<void> Function(Set<String>)? gravarColocadas;

  const FilaEtiquetasTab({
    super.key,
    this.abrirEndereco,
    this.buscar,
    this.lerColocadas,
    this.gravarColocadas,
  });

  @override
  State<FilaEtiquetasTab> createState() => FilaEtiquetasTabState();
}

class FilaEtiquetasTabState extends State<FilaEtiquetasTab>
    with AutomaticKeepAliveClientMixin {
  final _filtro = TextEditingController();
  bool _carregando = false;
  String? _erro;
  List<ItemFilaEtiqueta>? _itens;
  Set<String> _colocadas = {};

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

  Future<void> _gravar() =>
      (widget.gravarColocadas ?? FilaEtiquetasService.gravarColocadas)(
          _colocadas);

  Future<void> recarregar() async {
    setState(() {
      _carregando = true;
      _erro = null;
    });
    try {
      final itens =
          await (widget.buscar ?? const FilaEtiquetasService().buscar)();
      final marcas = await (widget.lerColocadas ??
          FilaEtiquetasService.lerColocadas)();
      if (!mounted) return;
      final validas = marcasValidas(marcas, itens);
      setState(() {
        _itens = itens;
        _colocadas = validas;
        _carregando = false;
      });
      if (validas.length != marcas.length) await _gravar();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = 'Não consegui buscar a fila de etiquetas: $e';
        _carregando = false;
      });
    }
  }

  Future<void> _alternar(ItemFilaEtiqueta i) async {
    setState(() {
      if (!_colocadas.remove(i.id)) _colocadas.add(i.id);
    });
    try {
      await _gravar();
    } catch (_) {}
  }

  List<ItemFilaEtiqueta> get _visiveis {
    final itens = _itens ?? const <ItemFilaEtiqueta>[];
    final termos = chaveNomeProduto(_filtro.text)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toList();
    if (termos.isEmpty) return itens;
    return [
      for (final i in itens)
        if (termos.every(
            (t) => chaveNomeProduto('${i.codigo} ${i.nome}').contains(t)))
          i,
    ];
  }

  Widget _titulo(String texto) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(texto,
            style: const TextStyle(
                color: _cinza, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final itens = _itens;
    final visiveis = _visiveis;
    // Impressos ainda não colocados em cima; os já colocados vão pro fim.
    final impressos = [
      ...visiveis.where((i) => i.impresso && !_colocadas.contains(i.id)),
      ...visiveis.where((i) => i.impresso && _colocadas.contains(i.id)),
    ];
    final pendentes = visiveis.where((i) => !i.impresso).toList();
    final totalImpressos = itens?.where((i) => i.impresso).length ?? 0;
    final totalColocadas =
        itens?.where((i) => i.impresso && _colocadas.contains(i.id)).length ??
            0;
    final totalPendentes = (itens?.length ?? 0) - totalImpressos;

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
                    '$totalImpressos impressas hoje · '
                    '$totalColocadas/$totalImpressos colocadas · '
                    '$totalPendentes pendente(s)',
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
                      hintText: 'Filtrar por produto ou código',
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
                    child: Text('Fila de etiquetas vazia.',
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
                if (impressos.isNotEmpty) ...[
                  _titulo('IMPRESSAS HOJE'),
                  for (final i in impressos) _linha(i),
                ],
                if (pendentes.isNotEmpty) ...[
                  _titulo('PENDENTES (AINDA NÃO IMPRESSAS)'),
                  for (final i in pendentes) _linha(i),
                ],
              ],
            ],
          ),
        ),
      ),
    ]);
  }

  Widget _linha(ItemFilaEtiqueta i) {
    final abrir = widget.abrirEndereco;
    final colocada = _colocadas.contains(i.id);
    final apagado = !i.impresso || colocada;
    final hora = i.hora;
    return Opacity(
      opacity: apagado ? 0.55 : 1,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: _cartao,
          borderRadius: BorderRadius.circular(10),
          border: colocada
              ? Border.all(color: _verdeClaro.withValues(alpha: 0.6))
              : null,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: abrir == null
              ? null
              : () => mostrarOndeEsta(context,
                  codigo: i.codigo, nome: i.nome, abrir: abrir),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(i.nome,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          decoration:
                              colocada ? TextDecoration.lineThrough : null,
                        )),
                    const SizedBox(height: 3),
                    Wrap(spacing: 8, children: [
                      Text(i.codigo,
                          style: const TextStyle(color: _cinza, fontSize: 12)),
                      Text(i.pares == 1 ? '1 clique' : '${i.pares} cliques',
                          style: const TextStyle(color: _cinza, fontSize: 12)),
                      if (hora.isNotEmpty)
                        Text(i.impresso ? 'impressa $hora' : 'na fila $hora',
                            style:
                                const TextStyle(color: _azul, fontSize: 12)),
                    ]),
                    if (abrir != null) ...[
                      const SizedBox(height: 3),
                      const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.place_outlined, size: 14, color: _azul),
                        Text(' onde está',
                            style: TextStyle(color: _azul, fontSize: 12)),
                      ]),
                    ],
                  ],
                ),
              ),
              if (i.impresso)
                IconButton(
                  tooltip: colocada ? 'Desmarcar' : 'Coloquei na prateleira',
                  iconSize: 30,
                  onPressed: () => _alternar(i),
                  icon: Icon(
                    colocada
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: colocada ? _verdeClaro : _cinza,
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
