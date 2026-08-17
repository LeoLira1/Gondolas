// ─────────────────────────────────────────────────────────────────────────────
// Conversão de quantidade para a unidade de manuseio (caixas / baldes)
// ─────────────────────────────────────────────────────────────────────────────
//
// Convenção do resto do sistema, que o app segue ao EXIBIR quantidades do
// galpão (o banco continua guardando litros):
//
//  * produto de 5 L  → a caixa fecha 4 unidades (5 L × 4 = 20 L por caixa):
//    litros ÷ 20, mostrado em CAIXAS;
//  * produto de 20 L → litros ÷ 20, mostrado em BALDES.
//
// Nunca mostrar só o número cru de litros quando a embalagem permitir
// converter — quem confere carga conta baldes e caixas, não litros.
//
// A embalagem é DEDUZIDA DO NOME cadastrado: não existe coluna de embalagem
// no estoque_mestre deste banco, e os nomes terminam com a litragem
// ('HERBICIDA BORAL 500 SC 20L', 'HERBICIDA NORTOX 2,4-D 806 SL 5L'). Se um
// dia a coluna aparecer, este arquivo é o único lugar a trocar.

/// Litragem da embalagem no fim do nome, ou null quando o nome não a traz.
///
/// Pega a ÚLTIMA ocorrência de `<número>L` no nome — a concentração vem antes
/// ('500 SC', '806 SL') e não termina em L colado a dígito, então a última é
/// sempre a embalagem. Aceita vírgula ou ponto no número e espaço opcional
/// antes do L ('20L', '20 L').
double? litragemDoNome(String nomeProduto) {
  final matches =
      RegExp(r'(\d+(?:[.,]\d+)?)\s?L\b', caseSensitive: false)
          .allMatches(nomeProduto);
  if (matches.isEmpty) return null;
  final texto = matches.last.group(1)!.replaceAll(',', '.');
  return double.tryParse(texto);
}

/// Quantidade em litros convertida para a unidade de manuseio, pronta para a
/// tela: '90 baldes', '12 caixas', '1 balde'. Null quando a litragem do nome
/// não permite converter — aí a tela mostra o número cru.
String? quantidadeEmbalada(String nomeProduto, double litros) {
  final litragem = litragemDoNome(nomeProduto);
  final String singular;
  if (litragem == 20) {
    singular = 'balde';
  } else if (litragem == 5) {
    singular = 'caixa';
  } else {
    return null;
  }
  // 20 L por unidade nos dois casos: o balde É 20 L, e a caixa fecha 4 × 5 L.
  final unidades = litros / 20;
  return '${formatarNumero(unidades)} '
      '${unidades == 1 ? singular : '${singular}s'}';
}

/// Número sem casa decimal inútil ('90', não '90.0'), com uma casa quando a
/// conta não fecha ('90.5') — mesmo estilo dos _fmtQtd existentes.
String formatarNumero(double n) =>
    n == n.roundToDouble() ? n.round().toString() : n.toStringAsFixed(1);
