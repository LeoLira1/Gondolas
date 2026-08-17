import 'package:flutter/material.dart';

import 'embalagem.dart';
import 'galpao_config.dart';
import 'galpao_scene.dart';

/// Mapa 3D do galpão de racks.
///
/// Etapa 3: toque, seleção e painel inferior de leitura. As pilhas ainda não
/// vêm do banco (etapa 6), então o galpão abre com as 78 vagas livres — é o
/// estado verdadeiro enquanto não houver persistência, não uma tela de
/// exemplo. Lançar/esvaziar (etapa 4) e filtro por rua + "ir para o número"
/// (etapa 5) vêm nas próximas etapas.
class GalpaoPage extends StatefulWidget {
  const GalpaoPage({super.key});

  @override
  State<GalpaoPage> createState() => _GalpaoPageState();
}

class _GalpaoPageState extends State<GalpaoPage> {
  /// Ocupação por posição — vazia até a etapa 6 ligar o banco.
  final Map<int, List<RackGalpao>> _pilhas = {};

  final Map<String, Color> _corPorProduto = {};

  ToqueGalpao? _selecionado;

  void _onTapEndereco(ToqueGalpao? toque) {
    setState(() => _selecionado = toque);
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selecionado;

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
            onTapEndereco: _onTapEndereco,
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
                            '${GalpaoConfig.totalPosicoes} posições · '
                            '${GalpaoConfig.ruas.length} ruas · '
                            'até ${GalpaoConfig.niveisMax} racks empilhados',
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

          // ── Painel inferior ─────────────────────────────────────────────
          if (sel != null)
            Positioned(
              left: 16, right: 16, bottom: 16,
              child: SafeArea(
                top: false,
                child: PainelEnderecoGalpao(
                  toque:  sel,
                  pilhas: _pilhas,
                  onFechar: () => setState(() => _selecionado = null),
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
                    'Toque num rack ou numa vaga para ver o endereço. '
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

// ── Painel do endereço ───────────────────────────────────────────────────────

/// Painel inferior com o endereço selecionado — leitura apenas (as ações de
/// lançar e esvaziar entram na etapa 4). Público para o teste montá-lo com
/// pilhas de exemplo sem atravessar a cena.
class PainelEnderecoGalpao extends StatelessWidget {
  final ToqueGalpao                toque;
  final Map<int, List<RackGalpao>> pilhas;
  final VoidCallback               onFechar;

  const PainelEnderecoGalpao({
    super.key,
    required this.toque,
    required this.pilhas,
    required this.onFechar,
  });

  @override
  Widget build(BuildContext context) {
    final rua   = GalpaoConfig.ruaDe(toque.posicao);
    final pilha = pilhas[toque.posicao] ?? const <RackGalpao>[];
    final rack  = toque.ocupado && toque.ordem <= pilha.length
        ? pilha[toque.ordem - 1]
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
                '${toque.posicao} · N${toque.ordem}',
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
                onTap: onFechar,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 18, color: Color(0xFF8a9aa8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (rack != null)
            _ConteudoOcupado(rack: rack)
          else
            _ConteudoVazio(proximaOrdem: toque.ordem),
        ],
      ),
    );
  }
}

class _ConteudoOcupado extends StatelessWidget {
  final RackGalpao rack;

  const _ConteudoOcupado({required this.rack});

  @override
  Widget build(BuildContext context) {
    // Quantidade na unidade de manuseio quando o nome permite deduzir a
    // embalagem (20L → baldes, 5L → caixas); os litros ficam como texto
    // secundário. Sem litragem no nome, mostra o número cru mesmo.
    final embalada = quantidadeEmbalada(rack.produtoNome, rack.quantidade);
    final litros   = '${formatarNumero(rack.quantidade)} L';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
      ],
    );
  }
}

class _ConteudoVazio extends StatelessWidget {
  final int proximaOrdem;

  const _ConteudoVazio({required this.proximaOrdem});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.check_box_outline_blank,
            size: 16, color: Color(0xFF6fcf97)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Vaga livre — carga nova entra como N$proximaOrdem, no topo '
            'da pilha.',
            style: const TextStyle(color: Color(0xFF6fcf97), fontSize: 12),
          ),
        ),
      ],
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
