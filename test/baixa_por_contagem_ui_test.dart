import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/baixa_por_contagem.dart';
import 'package:gondola_camda/baixa_por_contagem_ui.dart';
import 'package:gondola_camda/estoque_localizado_service.dart';

final _contadoEm = DateTime(2026, 8, 17, 8);
final _lancadoEm = DateTime(2026, 8, 10, 15);

EnderecoLocalizado _rack(int posicao, double qtd, {int nivel = 1}) =>
    EnderecoLocalizado(
      produtoCodigo: '10432',
      localTipo:     'galpao',
      localNum:      posicao,
      faceOuColuna:  0,
      andarOuNivel:  nivel,
      quantidade:    qtd,
      atualizadoEm:  _lancadoEm.toIso8601String(),
    );

PlanoBaixa _plano({
  double sistema = 70,
  List<EnderecoLocalizado>? enderecos,
  String nome = 'HERBICIDA BORAL 500 SC 20L',
}) =>
    planejarBaixa(
      contagem: ContagemDoProduto(
        codigos:           const ['10432'],
        nome:              nome,
        qtdSistema:        sistema,
        deltaDivergencias: 0,
        confirmadaEm:      _contadoEm,
      ),
      enderecos: enderecos ?? [_rack(52, 100)],
    );

Widget _montar(ResumoBaixa resumo) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: FaixaBaixaAutomatica(resumo: resumo),
        ),
      ),
    );

void main() {
  testWidgets('a faixa diz quantos produtos e quantas unidades saíram',
      (tester) async {
    await tester.pumpWidget(_montar(ResumoBaixa(aplicados: [_plano()])));

    expect(
      find.textContaining('Baixa da contagem · 1 produto · 30 un'),
      findsOneWidget,
    );
  });

  testWidgets('o toque abre o extrato com o de-onde-para-onde',
      (tester) async {
    await tester.pumpWidget(_montar(ResumoBaixa(aplicados: [_plano()])));
    await tester.tap(find.byType(FaixaBaixaAutomatica));
    await tester.pumpAndSettle();

    expect(find.text('Baixa automática da contagem'), findsOneWidget);
    expect(find.text('HERBICIDA BORAL 500 SC 20L'), findsOneWidget);
    // O total do produto e, abaixo, o endereço com as duas pontas da conta —
    // é essa segunda linha que se confere na frente do rack.
    expect(find.text('30 unidades · endereçado 100 → 70'), findsOneWidget);
    expect(find.text('GALPAO·52·N1   100 → 70'), findsOneWidget);
  });

  testWidgets('o rack esvaziado é dito com todas as letras', (tester) async {
    await tester.pumpWidget(
        _montar(ResumoBaixa(aplicados: [_plano(sistema: 0)])));
    await tester.tap(find.byType(FaixaBaixaAutomatica));
    await tester.pumpAndSettle();

    expect(find.textContaining('endereço esvaziado'), findsOneWidget);
  });

  testWidgets('o que continua faltando endereçar aparece separado',
      (tester) async {
    // Sistema 145 contra 90 endereçados: não há o que baixar, e os 55 que
    // faltam são justamente o que a baixa NÃO resolve sozinha.
    final faltando = _plano(sistema: 145, enderecos: [_rack(52, 90)]);
    await tester.pumpWidget(_montar(ResumoBaixa(
      aplicados: [_plano()],
      ignorados: [faltando],
    )));
    await tester.tap(find.byType(FaixaBaixaAutomatica));
    await tester.pumpAndSettle();

    expect(find.text('CONTINUA FALTANDO ENDEREÇAR'), findsOneWidget);
    expect(
      find.textContaining('Faltam 55 unidades por endereçar'),
      findsOneWidget,
    );
  });

  testWidgets('gravação incompleta é mostrada como falha, não como baixa',
      (tester) async {
    await tester.pumpWidget(_montar(ResumoBaixa(falhados: [_plano()])));
    await tester.tap(find.byType(FaixaBaixaAutomatica));
    await tester.pumpAndSettle();

    expect(find.text('NÃO DEU PARA GRAVAR'), findsOneWidget);
    expect(find.textContaining('Gravação incompleta'), findsOneWidget);
  });

  testWidgets('o X fecha a faixa', (tester) async {
    var fechada = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: FaixaBaixaAutomatica(
            resumo:   ResumoBaixa(aplicados: [_plano()]),
            onFechar: () => fechada = true,
          ),
        ),
      ),
    ));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(fechada, isTrue);
  });
}
