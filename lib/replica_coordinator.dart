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
  // Trava da recuperação. Enquanto ela está de pé, NADA move o estado: nem o
  // `conectando` que todo init() anuncia, nem o `pronta` que ele conclui, nem
  // o restauro no fim de uma sincronização. Sem a trava, uma réplica sabida
  // divergente voltava a aceitar gravação só porque o app foi reaberto ou
  // porque alguém tocou Sincronizar — e a divergência é justamente o estado
  // em que o servidor recusa os frames locais para sempre.
  bool _recuperacaoTravada = false;

  EstadoReplica get estado => _estado;
  bool get syncReservado => _syncReservado;

  /// True quando só uma recuperação explícita (apagar a réplica divergente)
  /// devolve o app ao normal.
  bool get recuperacaoTravada => _recuperacaoTravada;

  void definirEstado(EstadoReplica novo) {
    if (_recuperacaoTravada) return;
    _estado = novo;
  }

  /// Tranca o coordenador em [EstadoReplica.recuperacaoNecessaria]. Idempotente
  /// — quem detecta a divergência não precisa saber se ela já era conhecida.
  void exigirRecuperacao() {
    _recuperacaoTravada = true;
    _estado = EstadoReplica.recuperacaoNecessaria;
  }

  /// Destrava. Só quem de fato desfez a divergência pode chamar: hoje é o
  /// apagamento dos arquivos da réplica. O estado volta a `desconectada`
  /// porque não há mais réplica — quem reconecta é o init() seguinte.
  void concluirRecuperacao() {
    _recuperacaoTravada = false;
    _estado = EstadoReplica.desconectada;
  }

  Future<T> executarEscrita<T>(Future<T> Function() acao) {
    if (_estado != EstadoReplica.pronta || _syncReservado) {
      return Future<T>.error(ReplicaNaoProntaParaEscrita(
        _syncReservado ? EstadoReplica.sincronizando : _estado,
      ));
    }
    return _enfileirar(acao);
  }

  Future<T> executarSincronizacao<T>(Future<T> Function() acao) {
    // Sincronizar uma réplica divergente é repetir o erro que a condenou, e o
    // restauro de estado no fim apagaria a marca da recuperação.
    if (_recuperacaoTravada) {
      return Future<T>.error(
        const ReplicaNaoProntaParaEscrita(EstadoReplica.recuperacaoNecessaria),
      );
    }
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
      // A trava pode ter subido DENTRO desta sincronização (foi ela quem
      // descobriu a divergência). Restaurar o estado anterior aqui seria
      // apagar a descoberta que a própria operação acabou de fazer.
      if (_recuperacaoTravada) return;
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
