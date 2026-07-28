import 'package:flutter/widgets.dart';

/// Contabilidade do gesto de câmera das cenas 3D.
///
/// Nenhuma cena usa `onTap`: todas montam um único [GestureDetector] com
/// `onScaleStart/Update/End`, porque o mesmo gesto precisa orbitar, dar zoom,
/// arrastar *e* selecionar. O toque é então **sintetizado** no fim do gesto —
/// se o dedo não arrastou, aquilo era um tap.
///
/// O risco desse esquema é o inverso: um gesto de câmera que mal se moveu
/// termina indistinguível de um toque e dispara a conferência do produto sem
/// que o usuário tenha pedido. Este mixin concentra as guardas que evitam
/// isso, para que não fiquem valendo em umas cenas e faltando em outras.
///
/// A armadilha principal está no [ScaleGestureRecognizer]: ele reconfigura o
/// gesto sempre que o número de dedos muda, e nessa reconfiguração **dispara
/// um `onScaleEnd`** — antes de qualquer `onScaleUpdate`. Encostar o segundo
/// dedo para dar zoom produz esta sequência:
///
/// ```
/// onScaleStart pointerCount=1
/// onScaleEnd   pointerCount=2   ← nenhum update rodou ainda
/// onScaleStart pointerCount=2
/// onScaleUpdate…
/// onScaleEnd   pointerCount=1
/// ```
///
/// enquanto um toque de verdade é só `onScaleStart pointerCount=1` seguido de
/// `onScaleEnd pointerCount=0`.
///
/// Uma flag de arrasto calculada dentro do `onScaleUpdate` chega tarde demais
/// para aquele primeiro `onScaleEnd`: era ele que abria a conferência do
/// produto ao dar zoom. Por isso a decisão final olha o `pointerCount` do
/// próprio `onScaleEnd` — só houve toque quando **todos** os dedos já saíram
/// da tela.
///
/// A câmera continua sendo de cada cena — o mixin não sabe projetar nada. Uso:
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
///
/// void _onScaleEnd(ScaleEndDetails d) {
///   final tap = gestureOrigin;
///   if (endGesture(d)) _handleTap(tap!);
/// }
/// ```
mixin SceneGestureGuard<T extends StatefulWidget> on State<T> {
  /// Ponto focal do início do gesto. É ele — e não o ponto onde o dedo saiu —
  /// que alimenta o hit-test, senão um tremor de alguns pixels moveria o alvo.
  Offset? gestureOrigin;

  bool _isDragging = false;
  int  _pointers   = 0;

  /// Houve mais de um dedo em algum momento desde que a mão encostou na tela.
  ///
  /// Precisa ser separado de [_isDragging] porque o recognizer parte o gesto
  /// em vários start/end: quem dá zoom, solta um dedo e levanta o outro
  /// produz um `onScaleStart pointerCount=1` no fim, que zeraria [_isDragging]
  /// e deixaria o último trecho — de um dedo só, quase parado — virar toque.
  /// Esta trava só cai quando a tela fica de fato sem nenhum dedo.
  bool _houveMultiToque = false;

  /// Deslocamento a partir do qual o gesto deixa de poder virar tap.
  ///
  /// As cenas usavam 6.0 e 7.0, baixo demais para o dedo: quem toca numa caixa
  /// com o celular na mão raramente fica dentro disso. O padrão do Flutter para
  /// distinguir toque de arrasto (`kTouchSlop`) é 18.0, alto demais para uma
  /// cena que já girou visivelmente nesse meio tempo. 12.0 é o meio-termo, e
  /// fica num lugar só para ser fácil de calibrar depois.
  static const double dragThreshold = 12.0;

  /// Variação de escala tolerada antes de considerar que houve pinça.
  static const double _scaleThreshold = 0.02;

  /// O gesto já deixou de ser um toque? Uma vez ligado não desliga até o fim
  /// do gesto: arrastar longe e voltar ao ponto de partida não vira tap.
  bool get isDragging => _isDragging;

  /// Quantos dedos estão na tela neste gesto.
  int get gesturePointers => _pointers;

  void beginGesture(ScaleStartDetails d) {
    gestureOrigin = d.focalPoint;
    if (d.pointerCount > 1) _houveMultiToque = true;
    // Um trecho que nasce com dois dedos é câmera, não toque — e um que nasce
    // depois de já ter havido dois dedos também: a mão ainda está no meio de
    // um gesto de zoom.
    _isDragging = _houveMultiToque;
    _pointers   = d.pointerCount;
  }

  /// Reancora o gesto quando muda o número de dedos.
  ///
  /// Sem isso o ponto focal salta ao encostar/levantar o segundo dedo e a
  /// câmera dá um pulo. Encostar o segundo dedo também já conta como gesto,
  /// por si só — ninguém põe dois dedos na tela querendo tocar numa caixa.
  ///
  /// Retorna `true` quando reancorou: a cena deve re-salvar a sua câmera-base
  /// e sair sem mover a câmera neste frame.
  bool reanchorIfPointersChanged(ScaleUpdateDetails d) {
    if (d.pointerCount == _pointers) return false;
    gestureOrigin = d.focalPoint;
    _pointers     = d.pointerCount;
    if (d.pointerCount > 1) {
      _houveMultiToque = true;
      _isDragging      = true;
    }
    return true;
  }

  /// Marca o gesto como arrasto se o dedo andou, a pinça abriu/fechou, ou há
  /// mais de um dedo na tela.
  void markDragIfMoved(ScaleUpdateDetails d) {
    final origin = gestureOrigin;
    if (origin == null) return;
    if (d.pointerCount > 1) _houveMultiToque = true;
    if ((d.focalPoint - origin).distance > dragThreshold ||
        (d.scale - 1.0).abs() > _scaleThreshold ||
        d.pointerCount > 1) {
      _isDragging = true;
    }
  }

  /// Encerra o gesto e diz se ele deve virar um toque. Leia [gestureOrigin]
  /// antes de chamar — o estado é limpo aqui.
  ///
  /// `d.pointerCount > 0` significa que ainda há dedo na tela: este não é o
  /// fim de um toque, é a reconfiguração do recognizer ao mudar o número de
  /// dedos. Nesse caso o estado do gesto é preservado, porque o
  /// `onScaleStart` seguinte vem logo atrás e reancora tudo.
  bool endGesture(ScaleEndDetails d) {
    if (d.pointerCount > 0) return false;
    final fireTap = !_isDragging && !_houveMultiToque && gestureOrigin != null;
    gestureOrigin    = null;
    _isDragging      = false;
    _houveMultiToque = false;
    _pointers        = 0;
    return fireTap;
  }
}
