import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/estante_edr300_scene.dart';
import 'package:gondola_camda/estante_parede_scene.dart';
import 'package:gondola_camda/estante_scene.dart';
import 'package:gondola_camda/expositor_magnojet_scene.dart';
import 'package:gondola_camda/expositor_monitor_scene.dart';
import 'package:gondola_camda/expositor_nellore_scene.dart';
import 'package:gondola_camda/gondola_scene.dart';
import 'package:gondola_camda/loja_scene.dart';
import 'package:gondola_camda/models.dart';
import 'package:gondola_camda/palete_scene.dart';
import 'package:gondola_camda/scene_gestures.dart';

// Nenhuma cena 3D usa onTap: o toque é sintetizado no fim de um gesto de
// escala. Estes testes cobrem a fronteira entre "isso foi um toque" e "isso
// foi câmera" — em especial o caso que abria a conferência do produto por
// acidente: uma pinça de zoom curta, que mal se move e termina indistinguível
// de um toque.

/// Uma cena sob teste: como montá-la com um espião no callback de toque.
typedef ConstrutorCena = Widget Function(VoidCallback aoTocar);

final Map<String, ConstrutorCena> cenas = {
  'GondolaScene': (aoTocar) => GondolaScene(
        gondolaAtual: 9,
        onFaceTap: (_, __, ___, ____) => aoTocar(),
      ),
  'EstanteScene': (aoTocar) => EstanteScene(
        estanteAtual: 1,
        onTapCelulaVisualizar: (_, __, ___) => aoTocar(),
      ),
  'Edr300Scene': (aoTocar) => Edr300Scene(
        geometry: const Edr300Geometry(colunas: colunasEdr300Tripla),
        estanteNum: estanteEdr300TriplaNum,
        autoRotate: false,
        onTapCelulaVisualizar: (_, __, ___) => aoTocar(),
      ),
  'EstanteParedeScene': (aoTocar) => EstanteParedeScene(
        estanteAtual: estanteParedeMin,
        onTapCelulaVisualizar: (_, __, ___) => aoTocar(),
      ),
  'PaleteScene': (aoTocar) => PaleteScene(
        estanteAtual: paleteNumMin,
        onTapCelulaVisualizar: (_, __, ___) => aoTocar(),
      ),
  'ExpositorMagnojetScene': (aoTocar) => ExpositorMagnojetScene(
        geometry: const ExpositorMagnojetGeometry(),
        autoRotate: false,
        onTapGanchoVisualizar: (_, __) => aoTocar(),
      ),
  'ExpositorNelloreScene': (aoTocar) => ExpositorNelloreScene(
        geometry: const ExpositorNelloreGeometry(),
        autoRotate: false,
        onTapCelulaVisualizar: (_, __) => aoTocar(),
      ),
  'ExpositorMonitorScene': (aoTocar) => ExpositorMonitorScene(
        geometry: const ExpositorMonitorGeometry(),
        autoRotate: false,
        onTapCelulaVisualizar: (_, __) => aoTocar(),
      ),
  'LojaScene': (aoTocar) => LojaScene(onSelecionado: (_) => aoTocar()),
};

/// Monta a cena e devolve um contador de toques disparados.
Future<ValueNotifier<int>> montar(
    WidgetTester tester, ConstrutorCena constroi) async {
  final toques = ValueNotifier(0);
  await tester.pumpWidget(MaterialApp(home: constroi(() => toques.value++)));
  await tester.pump();
  return toques;
}

/// Descarta a cena: várias delas rodam um Ticker que precisa parar antes do
/// fim do teste.
Future<void> descartar(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

/// Ponto da tela em que um toque parado de um dedo chega a alguma célula.
///
/// O hit-test é por ray casting contra a geometria, então nem todo pixel
/// acerta produto. Varremos uma grade até achar um que acerte: é esse ponto
/// que os testes de "não deve virar toque" usam depois, senão eles passariam
/// à toa, só por mirar no vazio.
Future<Offset> acharPontoDeToque(
    WidgetTester tester, ConstrutorCena constroi) async {
  final tamanho = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (var fy = 0.30; fy <= 0.75; fy += 0.05) {
    for (var fx = 0.30; fx <= 0.70; fx += 0.05) {
      final ponto = Offset(tamanho.width * fx, tamanho.height * fy);
      final toques = await montar(tester, constroi);
      final gesto = await tester.startGesture(ponto);
      await gesto.up();
      await tester.pump();
      final acertou = toques.value > 0;
      await descartar(tester);
      if (acertou) return ponto;
    }
  }
  fail('nenhum ponto da grade disparou um toque nesta cena');
}

void main() {
  for (final entrada in cenas.entries) {
    final nome = entrada.key;
    final constroi = entrada.value;

    group(nome, () {
      testWidgets('um dedo parado dispara o toque', (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        final gesto = await tester.startGesture(ponto);
        await gesto.up();
        await tester.pump();

        expect(toques.value, 1, reason: 'o fluxo normal não pode ter quebrado');
        await descartar(tester);
      });

      // A regressão original: era assim que a conferência abria sozinha ao dar
      // zoom. Basta a pinça mexer na escala — não precisa ser um zoom grande.
      testWidgets('dois dedos que mexem a câmera não disparam o toque',
          (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        final dedo1 = await tester.startGesture(ponto - const Offset(30, 0));
        final dedo2 = await tester.startGesture(ponto + const Offset(30, 0));
        await tester.pump();
        // Pinça curta: abaixo do limiar de deslocamento, mas a escala muda.
        await dedo1.moveBy(const Offset(-3, 0));
        await dedo2.moveBy(const Offset(3, 0));
        await tester.pump();
        await dedo1.up();
        await dedo2.up();
        await tester.pump();

        expect(toques.value, 0);
        await descartar(tester);
      });

      // O buraco que aceitamos ao trocar "contar dedos" por "a câmera mudou":
      // dois dedos pousados e levantados sem mexer em absolutamente nada abrem
      // o produto. É raro, e é o preço de o toque de um dedo não ser engolido
      // por um contato acidental da palma ou do polegar que segura o aparelho.
      // Se um dia isso incomodar, o lugar de apertar é markDragIfMoved.
      testWidgets('dois dedos totalmente parados abrem — buraco conhecido',
          (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        final dedo1 = await tester.startGesture(ponto);
        final dedo2 = await tester.startGesture(ponto + const Offset(40, 0));
        await tester.pump();
        await dedo1.up();
        await dedo2.up();
        await tester.pump();

        expect(toques.value, 1);
        await descartar(tester);
      });

      testWidgets('pinça de zoom não dispara o toque', (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        final dedo1 = await tester.startGesture(ponto - const Offset(30, 0));
        final dedo2 = await tester.startGesture(ponto + const Offset(30, 0));
        await tester.pump();
        await dedo1.moveBy(const Offset(-50, 0));
        await dedo2.moveBy(const Offset(50, 0));
        await tester.pump();
        await dedo1.up();
        await dedo2.up();
        await tester.pump();

        expect(toques.value, 0);
        await descartar(tester);
      });

      // O recognizer parte o gesto de zoom em vários start/end. Soltar um dedo
      // abre um trecho novo, de um dedo só — que sem a trava de multitoque
      // terminaria virando toque com a mão ainda na tela.
      testWidgets('soltar um dedo da pinça e levantar o outro não dispara',
          (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        final dedo1 = await tester.startGesture(ponto - const Offset(30, 0));
        final dedo2 = await tester.startGesture(ponto + const Offset(30, 0));
        await tester.pump();
        await dedo1.moveBy(const Offset(-40, 0));
        await dedo2.moveBy(const Offset(40, 0));
        await tester.pump();
        await dedo1.up();
        await tester.pump();
        // Sobrou um dedo, que treme um pouco antes de sair.
        await dedo2.moveBy(const Offset(3, 2));
        await tester.pump();
        await dedo2.up();
        await tester.pump();

        expect(toques.value, 0);
        await descartar(tester);
      });

      testWidgets('arrasto de um dedo não dispara o toque', (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        final gesto = await tester.startGesture(ponto);
        await gesto.moveBy(const Offset(60, 25));
        await tester.pump();
        await gesto.up();
        await tester.pump();

        expect(toques.value, 0);
        await descartar(tester);
      });

      // A flag de arrasto é latching: quem arrasta a câmera e volta ao ponto
      // de partida não deve terminar abrindo a conferência.
      testWidgets('arrastar e voltar à origem não dispara o toque',
          (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        final gesto = await tester.startGesture(ponto);
        await gesto.moveBy(const Offset(80, 0));
        await tester.pump();
        await gesto.moveBy(const Offset(-80, 0));
        await tester.pump();
        await gesto.up();
        await tester.pump();

        expect(toques.value, 0);
        await descartar(tester);
      });

      // Depois de um gesto de câmera a mão sai da tela e o próximo toque é
      // intencional. A proteção contra abertura acidental não pode sobreviver
      // ao gesto que a motivou, senão engole o toque seguinte.
      //
      // A cena não pode ficar muda depois de um gesto de câmera: era esse o
      // relato de "clico algumas vezes e não abre".
      //
      // A verificação é por varredura, e não por um toque no ponto conhecido,
      // porque a pinça move a câmera — a caixa que estava sob aquele ponto sai
      // de lá, e um toque isolado falharia por ter mirado no vazio, não pela
      // trava. Com a trava presa, *nenhum* ponto da tela responde; é essa a
      // diferença que interessa. O "abre já no primeiro toque" está afirmado
      // ao pé da letra na LojaScene, mais abaixo, onde o toque avisa mesmo sem
      // acertar estrutura nenhuma.
      testWidgets('depois de uma pinça, a cena continua respondendo',
          (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        final dedo1 = await tester.startGesture(ponto - const Offset(30, 0));
        final dedo2 = await tester.startGesture(ponto + const Offset(30, 0));
        await tester.pump();
        await dedo1.moveBy(const Offset(-50, 0));
        await dedo2.moveBy(const Offset(50, 0));
        await tester.pump();
        await dedo1.up();
        await dedo2.up();
        await tester.pump();
        expect(toques.value, 0, reason: 'a pinça em si não abre nada');

        final tamanho = tester.view.physicalSize / tester.view.devicePixelRatio;
        for (var fy = 0.30; fy <= 0.75 && toques.value == 0; fy += 0.05) {
          for (var fx = 0.30; fx <= 0.70 && toques.value == 0; fx += 0.05) {
            final toque = await tester
                .startGesture(Offset(tamanho.width * fx, tamanho.height * fy));
            await toque.up();
            await tester.pump();
          }
        }

        expect(toques.value, greaterThan(0),
            reason: 'nenhum toque respondeu após a pinça');
        await descartar(tester);
      });

      testWidgets('toques seguidos abrem todas as vezes', (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        for (var i = 0; i < 3; i++) {
          final toque = await tester.startGesture(ponto);
          await toque.up();
          await tester.pump();
        }

        expect(toques.value, 3);
        await descartar(tester);
      });

      testWidgets('tremor abaixo do limiar ainda dispara o toque',
          (tester) async {
        final ponto = await acharPontoDeToque(tester, constroi);
        final toques = await montar(tester, constroi);

        final gesto = await tester.startGesture(ponto);
        // Dedo trêmulo, mas dentro do limiar: continua sendo um toque.
        await gesto.moveBy(const Offset(4, 3));
        await tester.pump();
        await gesto.up();
        await tester.pump();

        expect(toques.value, 1);
        await descartar(tester);
      });
    });
  }

  // Um PointerUp pode se perder — a cena reconstruída no meio do toque, por
  // exemplo — e deixar um dedo registrado que nunca sai. Sem auto-cura, a cena
  // para de responder de vez: nenhum toque seguinte chega a ser o último dedo.
  // A LojaScene serve de banco de prova porque o toque avisa mesmo sem acertar
  // estrutura nenhuma.
  testWidgets('LojaScene: dedo fantasma não deixa a cena muda para sempre',
      (tester) async {
    final toques = await montar(tester, cenas['LojaScene']!);
    const ponto = Offset(400, 300);

    // A auto-cura é medida pelo timeStamp dos próprios eventos, e os gestos
    // sintéticos nascem todos em Duration.zero — daí o createGesture, que
    // deixa marcar o instante de cada evento.
    const t0 = Duration(seconds: 1);

    // Dedo que encosta e nunca sai (nem up, nem cancel).
    final fantasma = await tester.createGesture();
    await fantasma.down(ponto, timeStamp: t0);
    await tester.pump();

    // Enquanto ele "está na tela", o toque de outro dedo não vira toque —
    // é indistinguível de um gesto de dois dedos.
    final durante = await tester.createGesture();
    await durante.down(ponto + const Offset(80, 0),
        timeStamp: t0 + const Duration(milliseconds: 100));
    await durante.up(timeStamp: t0 + const Duration(milliseconds: 200));
    await tester.pump();
    expect(toques.value, 0);

    // Passado o tempo do registro obsoleto, o fantasma é descartado e a cena
    // volta a responder sozinha.
    const t1 = Duration(seconds: 10);
    final depois = await tester.createGesture();
    await depois.down(ponto, timeStamp: t1);
    await depois.up(timeStamp: t1 + const Duration(milliseconds: 100));
    await tester.pump();

    expect(toques.value, 1, reason: 'a cena se recupera do dedo fantasma');
    await descartar(tester);
  });

  // O relato original: "dou um zoom e depois clico algumas vezes intencionais
  // e não abre". Aqui a pinça é de verdade, com a câmera afastando — o que nas
  // outras cenas tiraria a caixa de baixo do dedo. A LojaScene serve de banco
  // de prova porque o toque avisa mesmo quando não acerta estrutura nenhuma
  // (`onSelecionado(null)`), então o resultado depende só da trava de gesto.
  testWidgets('LojaScene: zoom de verdade e o toque seguinte já abre',
      (tester) async {
    final toques = await montar(tester, cenas['LojaScene']!);
    const ponto = Offset(400, 300);

    final dedo1 = await tester.startGesture(ponto - const Offset(40, 0));
    final dedo2 = await tester.startGesture(ponto + const Offset(40, 0));
    await tester.pump();
    await dedo1.moveBy(const Offset(-90, -20));
    await dedo2.moveBy(const Offset(90, 20));
    await tester.pump();
    await dedo1.up();
    await dedo2.up();
    await tester.pump();
    expect(toques.value, 0, reason: 'a pinça em si não abre nada');

    final toque = await tester.startGesture(ponto);
    await toque.up();
    await tester.pump();

    expect(toques.value, 1, reason: 'o primeiro toque após o zoom já abre');
    await descartar(tester);
  });

  test('o limiar de arrasto acomoda o tremor do dedo sem engolir o arrasto',
      () {
    // Os valores antigos (6.0 e 7.0) ficavam abaixo do tremor típico de um
    // toque no celular; kTouchSlop (18.0) já deixaria passar arrastos que
    // giraram a cena visivelmente.
    expect(SceneGestureGuard.dragThreshold, greaterThan(7.0));
    expect(SceneGestureGuard.dragThreshold, lessThan(18.0));
  });
}
