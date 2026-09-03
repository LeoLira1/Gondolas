import 'package:flutter/material.dart';

import 'outbox.dart';
import 'turso_service.dart';

/// As gravações que a reconstrução da réplica NÃO reaplicou sozinha.
///
/// Duas razões levam uma mutação até aqui, e a tela diz qual:
///
/// - **conflito**: o banco online não está mais no estado de onde a gravação
///   partiu, nem no estado a que ela ia chegar. Alguém mexeu no meio do
///   caminho, e reaplicar apagaria o trabalho dessa pessoa.
/// - **conferência**: a operação endereça o rack pela posição na pilha, e uma
///   renumeração faz `(posição, ordem)` apontar para outro rack. O número
///   pareceria certo e estaria errado.
///
/// Nada aqui é apagado nem aplicado por esta tela: ela existe para que a pessoa
/// veja o que precisa refazer à mão, com o que era e o que deveria ter virado.
class RevisaoMutacoesPage extends StatefulWidget {
  /// Lista pronta (testes). Sem ela, a página consulta a outbox.
  final List<MutacaoOutbox>? mutacoesIniciais;

  const RevisaoMutacoesPage({super.key, this.mutacoesIniciais});

  @override
  State<RevisaoMutacoesPage> createState() => _RevisaoMutacoesPageState();
}

class _RevisaoMutacoesPageState extends State<RevisaoMutacoesPage> {
  List<MutacaoOutbox>? _mutacoes;

  @override
  void initState() {
    super.initState();
    final semente = widget.mutacoesIniciais;
    if (semente != null) {
      _mutacoes = semente;
    } else {
      _carregar();
    }
  }

  Future<void> _carregar() async {
    final lista = await TursoService().mutacoesParaRevisao();
    if (mounted) setState(() => _mutacoes = lista);
  }

  @override
  Widget build(BuildContext context) {
    final mutacoes = _mutacoes;
    return Scaffold(
      backgroundColor: const Color(0xFF0d1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141a22),
        foregroundColor: Colors.white,
        title: const Text('Gravações para conferir',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: mutacoes == null
          ? const Center(child: CircularProgressIndicator())
          : mutacoes.isEmpty
              ? _vazio()
              : ListView.separated(
                  padding: const EdgeInsets.all(14),
                  itemCount: mutacoes.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) =>
                      i == 0 ? _explicacao() : _cartao(mutacoes[i - 1]),
                ),
    );
  }

  Widget _vazio() => const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'Nada para conferir.\n\nTudo o que este aparelho gravou foi '
            'confirmado pelo banco online ou reaplicado automaticamente.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 14, height: 1.5),
          ),
        ),
      );

  Widget _explicacao() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1a2430),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2a3a4a)),
        ),
        child: const Text(
          'Estas gravações ficaram no aparelho e não foram reaplicadas '
          'sozinhas — reaplicar poderia acertar o rack errado ou apagar o que '
          'outra pessoa fez. Nenhuma foi descartada. Confira cada uma no mapa '
          'e refaça o que ainda fizer sentido.',
          style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 12.5, height: 1.45),
        ),
      );

  Widget _cartao(MutacaoOutbox m) {
    final conflito = m.estado == EstadoMutacao.conflito;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF141a22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: conflito ? const Color(0xFF8b1a1a) : const Color(0xFF2a3a4a)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  m.produtoNome ?? m.produtoCodigo ?? _rotuloOperacao(m.operacao),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: conflito
                      ? const Color(0xFF8b1a1a)
                      : const Color(0xFF6b5a1a),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  conflito ? 'conflito' : 'conferência',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _linha('Operação', _rotuloOperacao(m.operacao)),
          if (m.produtoCodigo != null) _linha('Código', m.produtoCodigo!),
          if (m.posicao != null)
            _linha('Posição', m.ordem != null
                ? '${m.posicao} · N${m.ordem}'
                : '${m.posicao}'),
          if (m.ordem != null) _linha('Ordem original', 'N${m.ordem}'),
          _linha('Quantidade anterior', _qtd(m.quantidadeAnterior)),
          _linha('Resultado pretendido', _qtd(m.quantidadePretendida)),
          _linha('Horário', _horario(m.criadoEm)),
          _linha('Dispositivo', m.dispositivo),
        ],
      ),
    );
  }

  Widget _linha(String rotulo, String valor) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 132,
              child: Text(rotulo,
                  style: const TextStyle(
                      color: Color(0xFF6b7a88), fontSize: 12.5)),
            ),
            Expanded(
              child: Text(valor,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5)),
            ),
          ],
        ),
      );

  static String _qtd(double? valor) {
    if (valor == null) return '—';
    final inteiro = valor == valor.roundToDouble();
    return inteiro
        ? '${valor.toInt()} unidades'
        : valor.toStringAsFixed(2).replaceAll('.', ',');
  }

  static String _horario(DateTime d) {
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(d.day)}/${dois(d.month)}/${d.year} '
        '${dois(d.hour)}:${dois(d.minute)}';
  }

  static String _rotuloOperacao(String operacao) => switch (operacao) {
        'galpao.lancar'            => 'Lançamento no galpão',
        'galpao.esvaziar'          => 'Esvaziar rack do galpão',
        'galpao.ajustarQuantidade' => 'Ajuste de quantidade no galpão',
        'layout.salvarGondola'     => 'Layout de gôndola',
        'layout.salvarEstante'     => 'Layout de estante',
        _                          => operacao,
      };
}
