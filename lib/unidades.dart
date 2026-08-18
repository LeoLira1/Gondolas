// ─────────────────────────────────────────────────────────────────────────────
// Quantidade do galpão: UNIDADES, e só
// ─────────────────────────────────────────────────────────────────────────────
//
// O galpão já contou em baldes/caixas e gravou litros (unidades × 20). A
// conversão era invisível no banco e virava discrepância na tela: o
// `qtd_sistema` do estoque_mestre está em UNIDADE — é o mesmo número que o app
// do scanner mostra —, e dividi-lo por 20 fazia "559 unidades" aparecer como
// "19.4 baldes" ao lado de um endereçado que estava em litros. Duas contas
// diferentes na mesma tarja, e nenhuma delas conferindo com o sistema.
//
// Agora existe uma unidade só, do ERP ao cubo: a unidade. O que se digita é o
// que se grava, é o que se soma no endereçado e é o que se compara com o
// sistema. Nada de litros, caixas ou baldes em lugar nenhum.
//
// Os dados antigos (gravados em litros) são convertidos uma única vez pela
// migração `galpao_quantidade_em_unidades_v1` — ver galpao_migracao_unidades.
// dart.

/// Número sem casa decimal inútil ('90', não '90.0'), com uma casa quando a
/// conta não fecha ('90.5') — mesmo estilo dos _fmtQtd existentes.
String formatarNumero(double n) =>
    n == n.roundToDouble() ? n.round().toString() : n.toStringAsFixed(1);

/// Quantidade pronta para a tela: '45 unidades', '1 unidade'.
String quantidadeEmUnidades(double quantidade) =>
    '${formatarNumero(quantidade)} '
    '${quantidade == 1 ? 'unidade' : 'unidades'}';
