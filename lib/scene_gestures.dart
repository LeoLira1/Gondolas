import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Contabilidade do gesto de câmera das cenas 3D.
///
/// Nenhuma cena usa `onTap`: todas montam um [GestureDetector] com
/// `onScaleStart/Update`, porque o mesmo gesto precisa orbitar, dar zoom,
/// arrastar *e* selecionar. O toque é então **sintetizado** — se a mão saiu da
/// tela sem ter arrastado nem usado dois dedos, aquilo era um toque.
///
/// A decisão vem dos eventos de ponteiro crus, de um [Listener] montado por
/// fora do [GestureDetector], e **não** da sequência de callbacks do
/// [ScaleGestureRecognizer], que não serve para contar dedos: ele reconfigura
/// o gesto a cada mudança no número de dedos, disparando `onScaleEnd` e
/// `onScaleStart` no meio de um toque que continua, e não dispara `onEnd`
/// nenhum quando o último dedo sai. Uma pinça inteira produz:
///
/// ```
/// onScaleStart p=1
/// onScaleEnd   p=2     ← reconfiguração ao encostar o 2º dedo
/// onScaleStart p=2
/// onScaleUpdate p=2 …
/// onScaleEnd   p=1     ← reconfiguração ao soltar o 1º dedo
/// (levanta o último dedo → nenhum callback)
/// ```
///
/// Quem tentar deduzir daí quando a mão saiu da tela erra dos dois lados: se
/// tratar o `onScaleEnd p=2` como fim de gesto, encostar o segundo dedo para
/// dar zoom abre a conferência do produto sozinho; se esperar um `onScaleEnd`
/// com `pointerCount == 0`, ele nunca chega e o toque seguinte é engolido.
///
/// O [Listener] não tem esse problema: todo dedo que encosta na tela também
/// sai dela, então [aoSoltarDedo] sempre chega e sempre zera o estado.
///
/// A câmera continua sendo de cada cena — o mixin não sabe projetar nada. Uso:
///
/// ```dart
/// Listener(
///   onPointerDown:   aoEncostarDedo,
///   onPointerUp:     (e) { if (aoSoltarDedo(e)) _handleTap(pontoDoToque!); },
///   onPointerCancel: aoSoltarDedo,
///   child: GestureDetector(
///     onScaleStart:  _onScaleStart,
///     onScaleUpdate: _onScaleUpdate,
///     child: …,
///   ),
/// )
/// ```
///
/// ```dart
/// void _onScaleStart(ScaleStartDetails d) {
///   beginGesture(d);
///   _cameraAtGestureStart = _camera;
/// }
///
/// void _onScaleUpdate(ScaleUpdateDetails d) {
///   final origin = gestureOrigin;
///   final c0     = _cameraAtGestureStart;
///   if (origin == null || c0 == null) return;
///   if (reanchorIfPointersChanged(d)) {
///     _cameraAtGestureStart = _camera;
///     return;
///   }
///   markDragIfMoved(d);
///   ... matemática de câmera ...
/// }
/// ```
mixin SceneGestureGuard<T extends StatefulWidget> on State<T> {
  /// Posição do primeiro dedo a encostar na tela — o alvo do hit-test.
  ///
  /// É o ponto onde a mão *pousou*, não onde saiu: um toque que arrasta uns
  /// poucos pixels ainda abre o endereço que o usuário mirou.
  Offset? pontoDoToque;

  /// Ponto focal do início do trecho de gesto atual, para a matemática de
  /// câmera. Distinto de [pontoDoToque]: o recognizer reancora este a cada
  /// mudança no número de dedos, e a câmera precisa acompanhar.
  Offset? gestureOrigin;

  /// Ponteiros com o dedo encostado na tela, por id.
  ///
  /// Um [Set] e não um contador: ids são únicos, então um evento repetido ou
  /// fora de ordem não desequilibra a conta.
  final Set<int> _dedos = <int>{};

  /// Instante do último evento de dedo, para detectar registro obsoleto.
  Duration _ultimoEventoDeDedo = Duration.zero;

  bool _isDragging = false;
  int  _pointers   = 0;

  /// Depois deste tempo sem nenhum evento, um dedo ainda registrado é lixo.
  ///
  /// Um dedo parado não gera eventos, mas ninguém segura o dedo por segundos e
  /// só então começa outro toque — o que existe de verdade é o `PointerUp` que
  /// se perde (a cena reconstruída no meio do toque, por exemplo). Sem essa
  /// janela, um dedo fantasma faria a cena parar de responder para sempre:
  /// nenhum toque seguinte chegaria a ser o "último dedo".
  static const Duration _registroObsoleto = Duration(seconds: 3);

  /// Deslocamento a partir do qual o gesto deixa de poder virar toque.
  ///
  /// As cenas usavam 6.0 e 7.0, baixo demais para o dedo: quem toca numa caixa
  /// com o celular na mão raramente fica dentro disso. O padrão do Flutter para
  /// distinguir toque de arrasto (`kTouchSlop`) é 18.0, alto demais para uma
  /// cena que já girou visivelmente nesse meio tempo. 12.0 é o meio-termo, e
  /// fica num lugar só para ser fácil de calibrar depois.
  static const double dragThreshold = 12.0;

  /// Limiar efetivo DESTA cena. O padrão é [dragThreshold]; uma cena pode
  /// apertar (o galpão usa 9.0, porque os alvos lá são cubos grandes e o
  /// custo de um arrasto virar seleção é maior que o de exigir o dedo firme).
  double get limiarDeArrasto => dragThreshold;

  /// Duração máxima de um toque, ou null para não limitar (o padrão das
  /// cenas). Segurar o dedo além disso deixa de ser toque mesmo sem mover:
  /// é alguém pensando com o dedo na tela, não selecionando.
  Duration? get duracaoMaximaDoToque => null;

  /// Instante em que o primeiro dedo do gesto atual encostou.
  Duration? _inicioDoToque;

  /// Variação de escala tolerada antes de considerar que houve pinça.
  static const double _scaleThreshold = 0.02;

  /// O gesto já deixou de ser um toque? Uma vez ligado não desliga até a mão
  /// sair da tela: arrastar longe e voltar ao ponto de partida não vira toque.
  bool get isDragging => _isDragging;

  /// Quantos dedos estão encostados na tela agora.
  int get dedosNaTela => _dedos.length;

  // ── Eventos de ponteiro (Listener) ────────────────────────────────────────

  void aoEncostarDedo(PointerDownEvent e) {
    if (_dedos.isNotEmpty &&
        e.timeStamp - _ultimoEventoDeDedo > _registroObsoleto) {
      _dedos.clear();
    }
    _ultimoEventoDeDedo = e.timeStamp;

    _dedos.add(e.pointer);
    if (_dedos.length == 1) {
      // Começo real de um toque: nada do gesto anterior sobrevive até aqui.
      pontoDoToque  = e.position;
      _isDragging   = false;
      _inicioDoToque = e.timeStamp;
    }
  }

  /// Retorna `true` quando este era o último dedo e o gesto foi um toque —
  /// é o momento de chamar o hit-test com [pontoDoToque].
  bool aoSoltarDedo(PointerEvent e) {
    _ultimoEventoDeDedo = e.timeStamp;
    _dedos.remove(e.pointer);
    if (_dedos.isNotEmpty) return false;

    final limite  = duracaoMaximaDoToque;
    final inicio  = _inicioDoToque;
    final noTempo = limite == null ||
        inicio == null ||
        e.timeStamp - inicio <= limite;

    final ehToque = !_isDragging && pontoDoToque != null && noTempo;
    _isDragging    = false;
    gestureOrigin  = null;
    _pointers      = 0;
    _inicioDoToque = null;
    return ehToque;
  }

  // ── Callbacks de escala (câmera) ──────────────────────────────────────────

  void beginGesture(ScaleStartDetails d) {
    gestureOrigin = d.focalPoint;
    _pointers     = d.pointerCount;
  }

  /// Reancora o gesto quando muda o número de dedos.
  ///
  /// Sem isso o ponto focal salta ao encostar/levantar o segundo dedo e a
  /// câmera dá um pulo. Retorna `true` quando reancorou: a cena deve re-salvar
  /// a sua câmera-base e sair sem mover a câmera neste frame.
  bool reanchorIfPointersChanged(ScaleUpdateDetails d) {
    if (d.pointerCount == _pointers) return false;
    gestureOrigin = d.focalPoint;
    _pointers     = d.pointerCount;
    return true;
  }

  /// Marca o gesto como arrasto se o dedo andou ou a pinça abriu/fechou.
  ///
  /// O critério é a câmera ter mudado de verdade, e não quantos dedos estão na
  /// tela. Contar dedos parecia mais seguro, mas desqualificava o toque a cada
  /// contato acidental — a palma roçando a tela, o polegar da mão que segura o
  /// aparelho —, e era isso que deixava a cena dura. Nem adiantava exigir que
  /// o segundo dedo "mexesse": o próprio `PointerDown` já gera um update.
  ///
  /// O zoom, que era o gesto que abria a conferência sem querer, não escapa:
  /// a pinça muda a escala e o arrasto de dois dedos desloca o ponto focal.
  ///
  /// Em troca, dois dedos pousados e levantados sem mexer nada abrem o produto
  /// — situação rara, e o preço combinado por toques que respondem.
  void markDragIfMoved(ScaleUpdateDetails d) {
    final origin = gestureOrigin;
    if (origin == null) return;
    if ((d.focalPoint - origin).distance > limiarDeArrasto ||
        (d.scale - 1.0).abs() > _scaleThreshold) {
      _isDragging = true;
    }
  }
}
