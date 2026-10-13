import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/boneco_loja.dart';
import 'package:gondola_camda/loja_scene.dart';

/// Metade da largura/profundidade que o boneco ocupa no piso, mais uma folga
/// para ele não raspar na estrutura ao passar.
double get _folga => meiaLarguraBoneco(alturaBoneco) + 0.05;

/// Distância de um ponto do piso até a estrutura [item] (0 = dentro dela).
double _distanciaAteItem(double x, double z, ItemLoja item) {
  if (item.tipo == 'gondola') {
    final dx = x - item.x, dz = z - item.z;
    return math.max(0, math.sqrt(dx * dx + dz * dz) - LojaGeometry.gondolaR);
  }
  final dx = (x - item.x).abs() - item.w / 2;
  final dz = (z - item.z).abs() - item.d / 2;
  if (dx <= 0 && dz <= 0) return 0;
  return math.sqrt(math.pow(math.max(dx, 0), 2) + math.pow(math.max(dz, 0), 2));
}

void main() {
  test('boneco tem exatamente a altura da gôndola', () {
    expect(alturaBoneco, LojaGeometry.alturaGondola);

    final e = extremosBoneco(alturaBoneco);
    expect(e.base, closeTo(0, 1e-12));
    expect(e.topo, closeTo(alturaBoneco, 1e-12));
  });

  test('altura da gôndola sai da geometria desenhada no mapa', () {
    // Topo da prateleira mais alta da silhueta usada em LojaGeometry._gondola.
    var topo = 0.0;
    for (final (_, yc, h) in LojaGeometry.gondolaPrateleiras) {
      topo = math.max(topo, (yc + h / 2) * LojaGeometry.gondolaEscala);
    }
    expect(LojaGeometry.alturaGondola, closeTo(topo, 1e-12));
  });

  test('mudar a escala da loja reescala o boneco inteiro', () {
    // As medidas das peças são frações da altura: dobrar a altura dobra tudo,
    // e o topo continua batendo exatamente com a altura pedida.
    final a = extremosBoneco(alturaBoneco);
    final b = extremosBoneco(alturaBoneco * 2);
    expect(b.topo, closeTo(a.topo * 2, 1e-12));
    expect(b.topo, closeTo(alturaBoneco * 2, 1e-12));
    expect(meiaLarguraBoneco(alturaBoneco * 2),
        closeTo(meiaLarguraBoneco(alturaBoneco) * 2, 1e-12));
  });

  test('a passada é função da distância, não do tempo', () {
    // Dois bonecos na mesma rota, um duas vezes mais rápido: depois de andar
    // a MESMA distância, a fase da passada é a mesma — mudar a velocidade
    // acelera a passada junto, em vez de fazer o boneco patinar.
    final lento = BonecoLoja(
        altura: alturaBoneco, rota: rotasLoja[0],
        paleta: PaletaBoneco.funcionario, velocidade: 0.5);
    final rapido = BonecoLoja(
        altura: alturaBoneco, rota: rotasLoja[0],
        paleta: PaletaBoneco.funcionario, velocidade: 1.0);

    for (var i = 0; i < 60; i++) {
      lento.avancar(1 / 30);
      rapido.avancar(1 / 60);
    }
    expect(rapido.s, closeTo(lento.s, 1e-9));
    expect(rapido.passo, closeTo(lento.passo, 1e-9));
    expect(lento.passo.abs(), lessThanOrEqualTo(0.58 + 1e-9));
  });

  test('o balanço do corpo nunca levanta o boneco acima da altura', () {
    final b = BonecoLoja(
        altura: alturaBoneco, rota: rotasLoja[0],
        paleta: PaletaBoneco.funcionario);
    for (var i = 0; i < 400; i++) {
      b.avancar(1 / 60);
      expect(b.elevacao, lessThanOrEqualTo(0));
      expect(b.elevacao, greaterThanOrEqualTo(-0.02 * alturaBoneco - 1e-9));
    }
  });

  test('o yaw vira suave na quina, sem giro brusco de ±π', () {
    final b = BonecoLoja(
        altura: alturaBoneco, rota: rotasLoja[0],
        paleta: PaletaBoneco.funcionario);
    var anterior = b.yaw;
    var maiorSalto = 0.0;
    // Uma volta inteira, passando por todos os waypoints.
    final passos = (rotasLoja[0].perimetro / b.velocidade * 60).ceil() + 10;
    for (var i = 0; i < passos; i++) {
      b.avancar(1 / 60);
      var d = (b.yaw - anterior).abs();
      if (d > math.pi) d = 2 * math.pi - d;
      maiorSalto = math.max(maiorSalto, d);
      anterior = b.yaw;
    }
    expect(maiorSalto, lessThan(0.2));
  });

  test('a rota fecha e a posição sai só de s', () {
    final rota = rotasLoja[0];
    final inicio = rota.em(0);
    final volta  = rota.em(rota.perimetro);
    expect(volta.x, closeTo(inicio.x, 1e-9));
    expect(volta.z, closeTo(inicio.z, 1e-9));
    // A direção é sempre unitária.
    for (var s = 0.0; s < rota.perimetro; s += 0.37) {
      final p = rota.em(s);
      expect(math.sqrt(p.dx * p.dx + p.dz * p.dz), closeTo(1, 1e-9));
    }
  });

  test('nenhuma rota atravessa gôndola ou estante', () {
    for (var r = 0; r < rotasLoja.length; r++) {
      final rota = rotasLoja[r];
      for (var s = 0.0; s < rota.perimetro; s += 0.01) {
        final p = rota.em(s);
        for (final item in itensLoja) {
          expect(
            _distanciaAteItem(p.x, p.z, item),
            greaterThan(_folga),
            reason: 'rota $r em s=$s passa por cima de '
                '${item.tipo} ${item.numero}',
          );
        }
        // E também não sobe na parede perimetral (18 cm de espessura).
        expect(p.x, greaterThan(0.18 + _folga));
        expect(p.x, lessThan(lojaW - 0.18 - _folga));
        expect(p.z, greaterThan(0.18 + _folga));
        expect(p.z, lessThan(lojaH - 0.18 - _folga));
      }
    }
  });

  test('as rotas não se cruzam: os dois bonecos nunca se atropelam', () {
    final a = criarBonecosLoja(2)[0];
    final b = criarBonecosLoja(2)[1];
    final larguraDupla = 2 * meiaLarguraBoneco(alturaBoneco);
    var menor = double.infinity;
    for (var i = 0; i < 60 * 120; i++) {
      a.avancar(1 / 60);
      b.avancar(1 / 60);
      final dx = a.x - b.x, dz = a.z - b.z;
      menor = math.min(menor, math.sqrt(dx * dx + dz * dz));
    }
    expect(menor, greaterThan(larguraDupla));
  });

  test('as faces do cenário são memoizadas entre frames', () {
    // Com boneco em cena o mapa repinta 60×/s: remontar o cenário inteiro a
    // cada frame seria lixo puro para o GC.
    final a = LojaGeometry.buildFaces(null, 0);
    final b = LojaGeometry.buildFaces(null, 0);
    expect(identical(a, b), isTrue);
    // Mas muda de verdade quando a seleção muda.
    expect(identical(a, LojaGeometry.buildFaces(3, 0)), isFalse);
  });

  testWidgets('LojaScene anima os bonecos sem exceções', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LojaScene(bonecos: 2, onSelecionado: (_) {}),
    ));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('o ticker roda só com boneco em cena e para em background',
      (tester) async {
    // Mapa sem bonecos e sem seleção: estático, nenhum frame agendado.
    await tester.pumpWidget(MaterialApp(
      home: LojaScene(onSelecionado: (_) {}),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse);

    // Com boneco, o mapa repinta a cada frame…
    await tester.pumpWidget(MaterialApp(
      home: LojaScene(bonecos: 1, onSelecionado: (_) {}),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue);

    // …até o app ir para o background, quando o ticker para.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse);

    // E volta a andar quando o app volta.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pumpWidget(const SizedBox());
  });
}
