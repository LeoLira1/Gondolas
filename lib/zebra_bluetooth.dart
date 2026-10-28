import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_blue_classic/flutter_blue_classic.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Impressora Zebra (ZT410) por Bluetooth CLÁSSICO — SPP/RFCOMM, o mesmo
/// canal que o app Serial Bluetooth Terminal usa. Não é BLE.
///
/// O Bluetooth corta comandos longos quando vários chegam emendados, então a
/// impressão manda UM ^XA…^XZ por vez com um intervalo entre eles
/// ([intervaloMs], ajustável na tela).
class ZebraBluetooth {
  ZebraBluetooth._();
  static final ZebraBluetooth instance = ZebraBluetooth._();

  static const String keyEndereco = 'zebra_bt_endereco';
  static const String keyNome = 'zebra_bt_nome';
  static const String keyIntervaloMs = 'zebra_bt_intervalo_ms';
  static const int intervaloPadraoMs = 1500;

  static const String avisoTerminal =
      'Feche/desconecte o Serial Bluetooth Terminal e tente de novo.';

  final FlutterBlueClassic _bt = FlutterBlueClassic();
  BluetoothConnection? _conexao;

  bool get conectado => _conexao?.isConnected ?? false;

  // ── Preferências ─────────────────────────────────────────────────────────

  Future<({String endereco, String nome})?> impressoraSalva() async {
    final prefs = await SharedPreferences.getInstance();
    final endereco = prefs.getString(keyEndereco);
    if (endereco == null || endereco.isEmpty) return null;
    return (endereco: endereco, nome: prefs.getString(keyNome) ?? endereco);
  }

  Future<void> salvarImpressora(String endereco, String nome) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyEndereco, endereco);
    await prefs.setString(keyNome, nome);
  }

  Future<void> esquecerImpressora() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyEndereco);
    await prefs.remove(keyNome);
  }

  Future<int> intervaloMs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(keyIntervaloMs) ?? intervaloPadraoMs;
  }

  Future<void> salvarIntervaloMs(int ms) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyIntervaloMs, ms);
  }

  // ── Bluetooth ────────────────────────────────────────────────────────────

  /// Pede BLUETOOTH_CONNECT/BLUETOOTH_SCAN (Android 12+) e liga o Bluetooth
  /// se estiver desligado. Lança [ZebraErro] com a mensagem para o usuário.
  Future<void> prepararBluetooth() async {
    if (!Platform.isAndroid) {
      throw const ZebraErro('Impressão Bluetooth só funciona no Android.');
    }
    final status = await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
    final negadas = status.entries.where((e) => !e.value.isGranted).toList();
    if (negadas.isNotEmpty) {
      final permanente = negadas.any((e) => e.value.isPermanentlyDenied);
      throw ZebraErro(permanente
          ? 'Permissão de Bluetooth negada. Libere "Dispositivos próximos" '
              'nas configurações do Android para o app.'
          : 'Sem permissão de Bluetooth: o app precisa de "Dispositivos '
              'próximos" para falar com a impressora.');
    }
    if (!await _bt.isSupported) {
      throw const ZebraErro('Este aparelho não tem Bluetooth.');
    }
    if (!await _bt.isEnabled) {
      unawaited(_bt.turnOn());
      // O pedido abre um diálogo do sistema; espera o adaptador ligar.
      try {
        await _bt.adapterState
            .firstWhere((s) => s == BluetoothAdapterState.on)
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        throw const ZebraErro('Ligue o Bluetooth para imprimir.');
      }
    }
  }

  /// Dispositivos pareados no Android (a Zebra precisa estar pareada).
  Future<List<BluetoothDevice>> pareados() async {
    await prepararBluetooth();
    final lista = await _bt.bondedDevices ?? const <BluetoothDevice>[];
    return [...lista]..sort((a, b) =>
        _nomeDe(a).toLowerCase().compareTo(_nomeDe(b).toLowerCase()));
  }

  static String _nomeDe(BluetoothDevice d) =>
      (d.name?.isNotEmpty ?? false) ? d.name! : d.address;
  static String nomeDe(BluetoothDevice d) => _nomeDe(d);

  Future<void> conectar(String endereco) async {
    if (conectado && _conexao!.address == endereco) return;
    await desconectar();
    await prepararBluetooth();
    BluetoothConnection? c;
    try {
      c = await _bt.connect(endereco).timeout(const Duration(seconds: 15));
    } catch (_) {
      c = null;
    }
    if (c == null || !c.isConnected) {
      throw const ZebraErro('Não conectou na impressora. $avisoTerminal');
    }
    _conexao = c;
  }

  /// Manda UM comando ZPL e espera ele sair do aparelho. Lança [ZebraErro]
  /// se a conexão caiu.
  Future<void> enviar(String zpl) async {
    final c = _conexao;
    if (c == null || !c.isConnected) {
      throw const ZebraErro('Conexão com a impressora caiu. $avisoTerminal');
    }
    try {
      c.writeString('$zpl\r\n');
      await c.output.allSent.timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const ZebraErro('Falha ao enviar para a impressora. '
          '$avisoTerminal');
    }
    // A escrita que falha só fecha a conexão (o plugin engole o erro).
    if (!c.isConnected) {
      throw const ZebraErro('Conexão com a impressora caiu. $avisoTerminal');
    }
  }

  /// Fecha a conexão, deixando a impressora livre para o terminal.
  Future<void> desconectar() async {
    final c = _conexao;
    _conexao = null;
    if (c == null) return;
    try {
      await c.finish().timeout(const Duration(seconds: 5));
    } catch (_) {
      try {
        await c.close();
      } catch (_) {}
    }
  }
}

class ZebraErro implements Exception {
  final String mensagem;
  const ZebraErro(this.mensagem);

  @override
  String toString() => mensagem;
}
