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

  int  _dedosNaTela     = 0;
  bool _isDragging      = false;
  bool _houveMultiToque = false;
  int  _pointers        = 0;

  /// Deslocamento a partir do qual o gesto deixa de poder virar toque.
  ///
  /// As cenas usavam 6.0 e 7.0, baixo demais para o dedo: quem toca numa caixa
  /// com o celular na mão raramente fica dentro disso. O padrão do Flutter para
  /// distinguir toque de arrasto (`kTouchSlop`) é 18.0, alto demais para uma
  /// cena que já girou visivelmente nesse meio tempo. 12.0 é o meio-termo, e
  /// fica num lugar só para ser fácil de calibrar depois.
  static const double dragThreshold = 12.0;

  /// Variação de escala tolerada antes de considerar que houve pinça.
  static const double _scaleThreshold = 0.02;

  /// O gesto já deixou de ser um toque? Uma vez ligado não desliga até a mão
  /// sair da tela: arrastar longe e voltar ao ponto de partida não vira toque.
  bool get isDragging => _isDragging;

  /// Houve mais de um dedo na tela desde que a mão encostou?
  bool get houveMultiToque => _houveMultiToque;

  // ── Eventos de ponteiro (Listener) ────────────────────────────────────────

  void aoEncostarDedo(PointerDownEvent e) {
    _dedosNaTela++;
    if (_dedosNaTela == 1) {
      // Começo real de um toque: nada do gesto anterior sobrevive até aqui.
      pontoDoToque     = e.position;
      _isDragging      = false;
      _houveMultiToque = false;
    } else {
      // Ninguém põe dois dedos na tela querendo tocar numa caixa.
      _houveMultiToque = true;
    }
  }

  /// Retorna `true` quando este era o último dedo e o gesto foi um toque —
  /// é o momento de chamar o hit-test com [pontoDoToque].
  bool aoSoltarDedo(PointerEvent e) {
    if (_dedosNaTela > 0) _dedosNaTela--;
    if (_dedosNaTela > 0) return false;

    final ehToque = !_isDragging && !_houveMultiToque && pontoDoToque != null;
    _isDragging      = false;
    _houveMultiToque = false;
    gestureOrigin    = null;
    _pointers        = 0;
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
  void markDragIfMoved(ScaleUpdateDetails d) {
    final origin = gestureOrigin;
    if (origin == null) return;
    if ((d.focalPoint - origin).distance > dragThreshold ||
        (d.scale - 1.0).abs() > _scaleThreshold) {
      _isDragging = true;
    }
  }
}
