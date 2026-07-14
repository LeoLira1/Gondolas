import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'turso_service.dart';

class ConfiguracaoPage extends StatefulWidget {
  const ConfiguracaoPage({super.key});

  @override
  State<ConfiguracaoPage> createState() => _ConfiguracaoPageState();
}

class _ConfiguracaoPageState extends State<ConfiguracaoPage> {
  final _urlCtrl   = TextEditingController();
  final _tokenCtrl = TextEditingController();

  bool    _testando    = false;
  String? _statusTeste;
  bool    _testeOk     = false;
  bool    _cacheLocal  = true;
  bool    _sincronizando = false;

  @override
  void initState() {
    super.initState();
    _carregarCredenciais();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _carregarCredenciais() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _urlCtrl.text   = prefs.getString(TursoService.keyDbUrl)   ?? '';
      _tokenCtrl.text = prefs.getString(TursoService.keyDbToken) ?? '';
      _cacheLocal     = prefs.getBool(TursoService.keyCacheLocal) ?? true;
    });
  }

  Future<void> _alterarCacheLocal(bool valor) async {
    setState(() => _cacheLocal = valor);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(TursoService.keyCacheLocal, valor);
    // A troca de modo (local ⇄ remoto) é aplicada pelo init() quando as
    // páginas recarregam ao voltar desta tela.
  }

  Future<void> _sincronizarAgora() async {
    setState(() => _sincronizando = true);
    final ok = await TursoService().sincronizar();
    if (!mounted) return;
    setState(() => _sincronizando = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Sincronizado com o banco online ✓'
          : 'Não foi possível sincronizar — verifique a conexão'),
      backgroundColor: ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: const Duration(seconds: 2),
    ));
  }

  String _textoUltimaSync() {
    final quando = TursoService().ultimaSincronizacao;
    if (quando == null) return 'Nunca sincronizado';
    String dois(int n) => n.toString().padLeft(2, '0');
    return 'Última sincronização: ${dois(quando.day)}/${dois(quando.month)}/'
        '${quando.year} ${dois(quando.hour)}:${dois(quando.minute)}';
  }

  Future<void> _salvarConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(TursoService.keyDbUrl,   _urlCtrl.text.trim());
    await prefs.setString(TursoService.keyDbToken, _tokenCtrl.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Configuração salva'),
        backgroundColor: Color(0xFF2e6b46),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _testarConexao() async {
    setState(() {
      _testando    = true;
      _statusTeste = null;
    });

    final url   = _urlCtrl.text.trim();
    final token = _tokenCtrl.text.trim();

    if (url.isEmpty || token.isEmpty) {
      setState(() {
        _testando    = false;
        _statusTeste = 'Preencha URL e Token antes de testar.';
        _testeOk     = false;
      });
      return;
    }

    try {
      final client = LibsqlClient.remote(url, authToken: token);
      await client.connect();
      await client.query('SELECT 1');
      if (!mounted) return;
      setState(() {
        _testando    = false;
        _statusTeste = 'Conexão bem-sucedida ✓';
        _testeOk     = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testando    = false;
        _statusTeste = 'Erro: $e';
        _testeOk     = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0e1014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0e1014),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8a9aa8)),
        title: const Text(
          'Configuração do Banco',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Info banner
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0d1a24),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1a3a50)),
              ),
              child: const Text(
                'Conexão direta via libsql_dart ao banco Turso CAMDA.\n'
                'As credenciais são salvas localmente no dispositivo.',
                style: TextStyle(color: Color(0xFF7a9ab8), fontSize: 12, height: 1.5),
              ),
            ),
            const SizedBox(height: 28),

            _Campo(
              label: 'Database URL',
              controller: _urlCtrl,
              hint: 'libsql://camda-estoque-leolira1.aws-us-east-2.turso.io',
              obscure: false,
            ),
            const SizedBox(height: 16),

            _Campo(
              label: 'Token',
              controller: _tokenCtrl,
              hint: 'eyJ...',
              obscure: true,
            ),
            const SizedBox(height: 28),

            ElevatedButton.icon(
              onPressed: _salvarConfig,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('Salvar configuração'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2e6b46),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 12),

            OutlinedButton.icon(
              onPressed: _testando ? null : _testarConexao,
              icon: _testando
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF4a9d6a),
                      ),
                    )
                  : const Icon(Icons.wifi_tethering_outlined, size: 16),
              label: Text(_testando ? 'Testando...' : 'Testar conexão'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF4a9d6a),
                side: const BorderSide(color: Color(0xFF2e4a38)),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),

            if (!kIsWeb) ...[
              const SizedBox(height: 28),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0d1117),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF232f3a)),
                ),
                child: Column(children: [
                  SwitchListTile(
                    value: _cacheLocal,
                    onChanged: _alterarCacheLocal,
                    activeColor: const Color(0xFF4a9d6a),
                    title: const Text(
                      'Cache local',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    subtitle: const Text(
                      'Guarda os dados num arquivo do dispositivo: o app abre '
                      'e salva na hora, mesmo com internet ruim. Use o botão '
                      'Sincronizar para enviar/receber do banco online.',
                      style: TextStyle(
                          color: Color(0xFF8a9aa8), fontSize: 11, height: 1.4),
                    ),
                  ),
                  if (_cacheLocal)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            _textoUltimaSync(),
                            style: const TextStyle(
                                color: Color(0xFF8a9aa8), fontSize: 11),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _sincronizando ? null : _sincronizarAgora,
                          icon: _sincronizando
                              ? const SizedBox(
                                  width: 13,
                                  height: 13,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF4a9d6a),
                                  ),
                                )
                              : const Icon(Icons.sync, size: 15),
                          label: Text(
                              _sincronizando ? 'Sincronizando...' : 'Sincronizar'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF4a9d6a),
                            side: const BorderSide(color: Color(0xFF2e4a38)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ]),
                    ),
                ]),
              ),
            ],

            if (_statusTeste != null) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _testeOk
                      ? const Color(0xFF071a0e)
                      : const Color(0xFF1a0707),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _testeOk
                        ? const Color(0xFF2e6b46)
                        : const Color(0xFF6b2e2e),
                  ),
                ),
                child: Text(
                  _statusTeste!,
                  style: TextStyle(
                    color: _testeOk
                        ? const Color(0xFF4a9d6a)
                        : const Color(0xFFe57373),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Campo extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;

  const _Campo({
    required this.label,
    required this.controller,
    required this.hint,
    required this.obscure,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF8a9aa8),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF3a4a58), fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF0d1117),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF232f3a)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF232f3a)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF2e6b46), width: 1.5),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
      ],
    );
  }
}
