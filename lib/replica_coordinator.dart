import 'dart:async';

/// Estado único e observável da réplica. Leitura pode continuar em
/// [basePendente], mas somente [pronta] admite uma nova escrita.
enum EstadoReplica {
  desconectada,
  conectando,
  basePendente,
  pronta,
  sincronizando,
  recuperacaoNecessaria,
  erro,
}

class ReplicaNaoProntaParaEscrita implements Exception {
  final EstadoReplica estado;
  const ReplicaNaoProntaParaEscrita(this.estado);

  @override
  String toString() => estado == EstadoReplica.basePendente
      ? 'É necessário conectar à internet e estabelecer a base local antes da primeira gravação.'
      : estado == EstadoReplica.sincronizando
          ? 'A sincronização está em andamento; aguarde para gravar.'
          : estado == EstadoReplica.recuperacaoNecessaria
              ? 'A réplica precisa de recuperação; os dados locais foram preservados.'
              : 'A réplica local não está pronta para gravação (${estado.name}).';
}

/// Mutex FIFO compartilhado por escritas, sincronização e reconstrução.
///
/// A reserva entra na fila de forma síncrona, antes do primeiro `await`. O
/// timeout pertence apenas ao chamador: o Future nativo e o mutex continuam
/// vivos até a operação terminar, pois Future.timeout não cancela trabalho.
class CoordenadorReplica {
  EstadoReplica _estado = EstadoReplica.desconectada;
  Future<void> _cauda = Future<void>.value();
  bool _syncReservado = false;

  EstadoReplica get estado => _estado;
  bool get syncReservado => _syncReservado;

  void definirEstado(EstadoReplica novo) => _estado = novo;

  Future<T> executarEscrita<T>(Future<T> Function() acao) {
    if (_estado != EstadoReplica.pronta || _syncReservado) {
      return Future<T>.error(ReplicaNaoProntaParaEscrita(
        _syncReservado ? EstadoReplica.sincronizando : _estado,
      ));
    }
    return _enfileirar(acao);
  }

  Future<T> executarSincronizacao<T>(Future<T> Function() acao) {
    if (_syncReservado) {
      return Future<T>.error(
        const ReplicaNaoProntaParaEscrita(EstadoReplica.sincronizando),
      );
    }
    _syncReservado = true;
    final anterior = _estado;
    _estado = EstadoReplica.sincronizando;
    final futuro = _enfileirar(acao);
    return futuro.whenComplete(() {
      _syncReservado = false;
      if (_estado == EstadoReplica.sincronizando) {
        _estado = anterior == EstadoReplica.basePendente
            ? EstadoReplica.basePendente
            : EstadoReplica.pronta;
      }
    });
  }

  Future<T> _enfileirar<T>(Future<T> Function() acao) {
    final resultado = Completer<T>();
    final vez = _cauda.catchError((_) {});
    _cauda = vez.then((_) async {
      try {
        resultado.complete(await acao());
      } catch (e, st) {
        resultado.completeError(e, st);
      }
    });
    return resultado.future;
  }
}
