import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/outbox.dart';
import 'package:gondola_camda/revisao_mutacoes_page.dart';

void main() {
  MutacaoOutbox mutacao({
    String operacao = 'galpao.ajustarQuantidade',
    EstadoMutacao estado = EstadoMutacao.revisaoManual,
  }) =>
      MutacaoOutbox(
        uuid: 'abc',
        operacao: operacao,
        alvo: const AlvoMutacao(
            tabela: 'galpao_racks', chave: {'posicao': 12, 'ordem': 2}),
        estadoAnterior: const {'quantidade': 14},
        estadoFinal: const {'quantidade': 90},
        criadoEm: DateTime(2026, 9, 3, 14, 5),
        dispositivo: 'android-1a2b3c4d',
        estado: estado,
        produtoCodigo: 'BORAL',
        produtoNome: 'HERBICIDA BORAL 500 SC 20L',
        posicao: 12,
        ordem: 2,
        quantidadeAnterior: 14,
        quantidadePretendida: 90,
      );

  Widget montar(List<MutacaoOutbox> lista) =>
      MaterialApp(home: RevisaoMutacoesPage(mutacoesIniciais: lista));

  testWidgets('mostra os campos que a conferência exige', (tester) async {
    await tester.pumpWidget(montar([mutacao()]));
    await tester.pump();

    expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
    expect(find.text('BORAL'), findsOneWidget);
    expect(find.text('12 · N2'), findsOneWidget);       // posição
    expect(find.text('N2'), findsOneWidget);            // ordem original
    expect(find.text('14 unidades'), findsOneWidget);   // quantidade anterior
    expect(find.text('90 unidades'), findsOneWidget);   // resultado pretendido
    expect(find.text('03/09/2026 14:05'), findsOneWidget);
    expect(find.text('android-1a2b3c4d'), findsOneWidget);
    expect(find.text('Ajuste de quantidade no galpão'), findsOneWidget);
  });

  testWidgets('separa conflito de conferência', (tester) async {
    await tester.pumpWidget(montar([
      mutacao(estado: EstadoMutacao.conflito),
      mutacao(estado: EstadoMutacao.revisaoManual),
    ]));
    await tester.pump();

    expect(find.text('conflito'), findsOneWidget);
    expect(find.text('conferência'), findsOneWidget);
  });

  testWidgets('lista vazia diz que não há nada pendente', (tester) async {
    await tester.pumpWidget(montar(const []));
    await tester.pump();

    expect(find.textContaining('Nada para conferir'), findsOneWidget);
  });

  testWidgets('a tela não oferece apagar nem aplicar', (tester) async {
    // A regra é explícita: nada aqui é descartado, e reaplicar é justamente o
    // que não se pode fazer sozinho nestas operações. Um botão que sugerisse
    // qualquer das duas coisas seria a promessa errada.
    await tester.pumpWidget(montar([mutacao()]));
    await tester.pump();

    expect(find.widgetWithText(TextButton, 'Descartar'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Aplicar'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });
}
