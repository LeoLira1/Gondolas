import 'package:flutter/material.dart';

import 'baixa_por_contagem.dart';
import 'models.dart' show pluralizar;
import 'unidades.dart';

// ─────────────────────────────────────────────────────────────────────────────
// A baixa automática na tela
// ─────────────────────────────────────────────────────────────────────────────
//
// A baixa mexe em rack sem ninguém pedir, e é isso que a torna útil. Mas
// mudança silenciosa em quantidade de estoque é exatamente o tipo de coisa que
// faz quem confere parar de confiar no mapa — então ela SEMPRE se anuncia:
// uma faixa dizendo quantos produtos e quantas unidades saíram, e um toque
// abrindo o de-onde-para-onde, endereço por endereço.
//
// A cor é a mesma do rack que passou do sistema (azul), porque é justamente o
// azul que a baixa acabou de apagar do mapa.

const Color _corBaixa = Color(0xFF1565C0);

/// Faixa compacta do que a baixa fez nesta abertura. Uma linha só, no mesmo
/// formato das outras faixas do mapa; o detalhe fica atrás do toque.
class FaixaBaixaAutomatica extends StatelessWidget {
  final ResumoBaixa resumo;
  final VoidCallback? onFechar;

  const FaixaBaixaAutomatica({
    super.key,
    required this.resumo,
    this.onFechar,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => mostrarDetalheBaixa(context, resumo),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
          decoration: BoxDecoration(
            color:        const Color(0xEE141518),
            borderRadius: BorderRadius.circular(9),
            border:       Border.all(color: _corBaixa.withValues(alpha: 0.45)),
          ),
          child: Row(
            children: [
              const Icon(Icons.local_shipping_outlined,
                  size: 13, color: _corBaixa),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Baixa da contagem · '
                  '${pluralizar(resumo.produtos, 'produto')} · '
                  '${formatarNumero(resumo.totalDeduzido)} un fora dos '
                  'endereços',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Color(0xFF8a9aa8), fontSize: 11),
                ),
              ),
              const Icon(Icons.chevron_right,
                  size: 15, color: Color(0xFF8a877f)),
              if (onFechar != null)
                InkWell(
                  onTap: onFechar,
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close,
                        size: 13, color: Color(0xFF8a877f)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// O extrato da baixa: cada produto, quanto saiu e de que endereço.
///
/// É a folha de conferência de quem quer saber por que o palete do rack 52
/// tem 70 hoje e tinha 100 ontem. Os produtos que ficaram FALTANDO endereço
/// vêm no fim, porque esses a baixa não resolve — só uma pessoa resolve.
Future<void> mostrarDetalheBaixa(
    BuildContext context, ResumoBaixa resumo) async {
  final faltando = resumo.comFaltaDeEndereco;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF111417),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Row(children: [
                const Icon(Icons.local_shipping_outlined,
                    size: 17, color: _corBaixa),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    'Baixa automática da contagem',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close,
                      size: 17, color: Color(0xFF8a877f)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Text(
                'A contagem confirmada disse quanto existe no chão; o que os '
                'endereços tinham a mais era venda ainda não baixada. As '
                'divergências abertas já estão descontadas do alvo.',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 11,
                    height: 1.4),
              ),
            ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                children: [
                  for (final plano in resumo.aplicados) _ItemBaixa(plano: plano),
                  if (resumo.falhados.isNotEmpty) ...[
                    const _Titulo('Não deu para gravar'),
                    for (final plano in resumo.falhados)
                      _ItemBaixa(plano: plano, falhou: true),
                  ],
                  if (faltando.isNotEmpty) ...[
                    const _Titulo('Continua faltando endereçar'),
                    for (final plano in faltando) _ItemFalta(plano: plano),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Titulo extends StatelessWidget {
  final String texto;
  const _Titulo(this.texto);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(
          texto.toUpperCase(),
          style: const TextStyle(
              color: Color(0xFF8a877f),
              fontSize: 10,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600),
        ),
      );
}

class _ItemBaixa extends StatelessWidget {
  final PlanoBaixa plano;
  final bool falhou;

  const _ItemBaixa({required this.plano, this.falhou = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFF0d1117),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: falhou
              ? const Color(0xFFe57373).withValues(alpha: 0.35)
              : const Color(0xFF232f3a),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            plano.contagem.nome.isEmpty
                ? plano.contagem.codigo
                : plano.contagem.nome,
            style: const TextStyle(
                color: Colors.white, fontSize: 12.5, height: 1.25),
          ),
          const SizedBox(height: 2),
          Text(
            plano.contagem.codigos.join(' + '),
            style: const TextStyle(color: Color(0xFF8a877f), fontSize: 10.5),
          ),
          const SizedBox(height: 7),
          Text(
            falhou
                ? 'Gravação incompleta — '
                    '${quantidadeEmUnidades(plano.deduzido)} a retirar'
                : '${quantidadeEmUnidades(plano.deduzido)} '
                    '· endereçado ${formatarNumero(plano.enderecadoAntes)} → '
                    '${formatarNumero(plano.enderecadoDepois)}',
            style: TextStyle(
              color: falhou ? const Color(0xFFe57373) : _corBaixa,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          for (final ajuste in plano.ajustes)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '${ajuste.endereco.enderecoCompacto}   '
                '${formatarNumero(ajuste.qtdAnterior)} → '
                '${formatarNumero(ajuste.qtdNova)}'
                '${ajuste.esvazia ? '  (endereço esvaziado)' : ''}',
                style: const TextStyle(
                    color: Color(0xFFb0ada8), fontSize: 11, height: 1.3),
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemFalta extends StatelessWidget {
  final PlanoBaixa plano;
  const _ItemFalta({required this.plano});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFF0d1117),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
            color: const Color(0xFFe53935).withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            plano.contagem.nome.isEmpty
                ? plano.contagem.codigo
                : plano.contagem.nome,
            style: const TextStyle(
                color: Colors.white, fontSize: 12.5, height: 1.25),
          ),
          const SizedBox(height: 6),
          Text(
            'Faltam ${quantidadeEmUnidades(plano.faltaEnderecar)} por '
            'endereçar — a baixa não inventa em que rack elas estão.',
            style: const TextStyle(
                color: Color(0xFFe57373), fontSize: 11.5, height: 1.3),
          ),
        ],
      ),
    );
  }
}
