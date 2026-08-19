import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'loja_scene.dart' show PreferenciasMapa;
import 'baixa_por_contagem_service.dart';
import 'palete_registry.dart';
import 'replica_local.dart' show resumoDoSync;
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
  bool    _reconectando = false;
  bool    _sincronizando = false;
  bool    _limpandoCache = false;

  List<Palete> _paletes = const [];
  bool _salvandoPalete  = false;

  // Bonecos caminhando pelo mapa da loja: 0 (desligado), 1 ou 2.
  int _bonecos = PreferenciasMapa.bonecos.value;

  // Baixa automática do que foi vendido (ver baixa_por_contagem.dart). Nasce
  // no padrão e é corrigida pela leitura das preferências logo em seguida.
  bool _baixaAutomatica = BaixaPorContagemService.padraoBaixaAutomatica;

  @override
  void initState() {
    super.initState();
    _carregarCredenciais();
    _carregarPaletes();
    PreferenciasMapa.lerBonecos().then((n) {
      if (mounted) setState(() => _bonecos = n);
    });
    BaixaPorContagemService.lerAutomatica().then((ligada) {
      if (mounted) setState(() => _baixaAutomatica = ligada);
    });
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

  // ── Paletes ────────────────────────────────────────────────────────────────
  // O catálogo dos paletes vem do PaleteRegistry (tabela `paletes`), que já foi
  // carregado no init() do TursoService. Aqui só recarregamos para refletir o
  // que outro dispositivo tenha cadastrado desde a última sincronização.

  Future<void> _carregarPaletes() async {
    await TursoService().init();
    await PaleteRegistry().carregar();
    if (!mounted) return;
    setState(() => _paletes = PaleteRegistry().ativos);
  }

  Future<void> _adicionarPalete() async {
    final apelido = await _dialogPalete();
    if (apelido == null) return;
    setState(() => _salvandoPalete = true);
    final num = await PaleteRegistry().criar(apelido: apelido);
    if (!mounted) return;
    setState(() {
      _salvandoPalete = false;
      _paletes        = PaleteRegistry().ativos;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(num != null
          ? 'Palete $num cadastrado ✓'
          : 'Não foi possível cadastrar o palete — verifique a conexão'),
      backgroundColor:
          num != null ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: Duration(seconds: num != null ? 3 : 5),
    ));
  }

  Future<void> _editarPalete(Palete p) async {
    final apelido = await _dialogPalete(inicial: p);
    if (apelido == null) return;
    setState(() => _salvandoPalete = true);
    final ok = await PaleteRegistry().atualizar(p.copyWith(apelido: apelido));
    if (!mounted) return;
    setState(() {
      _salvandoPalete = false;
      _paletes        = PaleteRegistry().ativos;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Palete ${p.num} atualizado ✓'
          : 'Não foi possível salvar o palete ${p.num}'),
      backgroundColor: ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _confirmarDesativarPalete(Palete p) async {
    final nome = p.apelido.isEmpty ? 'Palete ${p.num}' : p.apelido;
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Desativar o palete ${p.num}?',
          style: const TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Text(
          '$nome sai do mapa e do carrossel.\n\n'
          'O número ${p.num} NÃO volta a ser usado: um palete novo sempre '
          'recebe um número maior. Isso é de propósito — reciclar o número '
          'faria o palete novo herdar os endereços antigos deste no estoque.\n\n'
          'Antes de desativar, recadastre em outro endereço os produtos que '
          'estão neste palete: as contagens deles continuam gravadas no '
          'número ${p.num} e deixarão de aparecer nas buscas.',
          style: const TextStyle(
              color: Color(0xFF8a9aa8), fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar',
                style: TextStyle(color: Color(0xFF8a9aa8))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desativar',
                style: TextStyle(color: Color(0xFFe57373))),
          ),
        ],
      ),
    );
    if (confirmou != true) return;

    setState(() => _salvandoPalete = true);
    final ok = await PaleteRegistry().desativar(p.num);
    if (!mounted) return;
    setState(() {
      _salvandoPalete = false;
      _paletes        = PaleteRegistry().ativos;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Palete ${p.num} desativado — o número não será reutilizado'
          : 'Não foi possível desativar o palete ${p.num}'),
      backgroundColor: ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: const Duration(seconds: 4),
    ));
  }

  /// Dialog de cadastro/edição. Devolve o apelido, ou null se cancelou.
  ///
  /// O apelido é o ÚNICO campo: o palete tem tamanho e grade padrão (1,20 ×
  /// 1,00 m, 15 posições), e não é desenhado no mapa da loja — como a estante
  /// 5, só existe no carrossel de detalhes. Sem geometria no mapa, pedir x/z
  /// seria entrada morta, então a posição fica gravada como 0 na tabela até
  /// que (se) o palete passe a aparecer no mapa.
  Future<String?> _dialogPalete({Palete? inicial}) {
    final apelidoCtrl = TextEditingController(text: inicial?.apelido ?? '');

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          inicial == null ? 'Novo palete' : 'Palete ${inicial.num}',
          style: const TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  inicial == null
                      ? 'Tamanho padrão: 1,20 × 1,00 m, 15 posições (5 × 3). '
                          'O número é alocado automaticamente e mostrado ao salvar.'
                      : 'Tamanho padrão: 1,20 × 1,00 m, 15 posições (5 × 3).',
                  style: const TextStyle(
                      color: Color(0xFF8a9aa8), fontSize: 12, height: 1.4),
                ),
              ),
              _Campo(
                label: 'Apelido',
                controller: apelidoCtrl,
                hint: 'Palete óleo — corredor 3',
                obscure: false,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar',
                style: TextStyle(color: Color(0xFF8a9aa8))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, apelidoCtrl.text.trim()),
            child: const Text('Salvar',
                style: TextStyle(color: Color(0xFF4a9d6a))),
          ),
        ],
      ),
    );
  }

  Future<void> _alterarCacheLocal(bool valor) async {
    setState(() => _cacheLocal = valor);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(TursoService.keyCacheLocal, valor);
    // A troca de modo (local ⇄ remoto) é aplicada pelo init() quando as
    // páginas recarregam ao voltar desta tela.
  }

  /// Tenta reabrir o cache local sem precisar fechar e reabrir o app.
  Future<void> _tentarCacheLocal() async {
    setState(() => _reconectando = true);
    await TursoService().reconectar();
    if (!mounted) return;
    final deuCerto = TursoService().modoLocal;
    setState(() => _reconectando = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(deuCerto
          ? 'Cache local aberto ✓ — gravações voltam a ser instantâneas'
          : 'Ainda não deu — o app segue no banco online. '
              'Procure um lugar com sinal melhor e tente de novo.'),
      backgroundColor:
          deuCerto ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: Duration(seconds: deuCerto ? 3 : 6),
    ));
  }

  Future<void> _sincronizarAgora() async {
    setState(() => _sincronizando = true);
    final ok = await TursoService().sincronizar();
    if (!mounted) return;
    setState(() => _sincronizando = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      // O aviso só aparece quando o sync deu certo depois de reconstruir a
      // replica local divergente: o usuário precisa saber que o cache foi
      // refeito do zero, senão some gravação sem explicação.
      content: Text(ok
          ? (TursoService().ultimoAvisoSync ??
              resumoDoSync(
              modoLocal: TursoService().modoLocal,
              enviadas:  TursoService().enviadasNoUltimoSync))
          : 'Não foi possível sincronizar — '
              '${TursoService().ultimoErroSync ?? 'verifique a conexão'}'),
      backgroundColor: ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: Duration(
          seconds: ok ? (TursoService().ultimoAvisoSync != null ? 6 : 2) : 6),
    ));
  }

  Future<void> _confirmarLimparCache() async {
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141a22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Limpar cache local?',
          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          'Apaga o arquivo de dados salvo neste dispositivo e baixa tudo de '
          'novo do banco online. O Sincronizar já refaz o cache sozinho quando '
          'ele diverge do banco — use este botão só se o problema insistir.\n\n'
          'Gravações feitas offline e ainda não sincronizadas serão perdidas.',
          style: TextStyle(color: Color(0xFF8a9aa8), fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xFF8a9aa8))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Limpar e rebaixar',
                style: TextStyle(color: Color(0xFFe57373))),
          ),
        ],
      ),
    );
    if (confirmou == true) _limparCacheLocal();
  }

  Future<void> _limparCacheLocal() async {
    setState(() => _limpandoCache = true);
    final ok = await TursoService().limparCacheLocal();
    if (ok) await TursoService().init();
    if (!mounted) return;
    setState(() => _limpandoCache = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? (TursoService().isConnected
              ? 'Cache local limpo e rebaixado do banco online ✓'
              : 'Cache local limpo — sem conexão para rebaixar agora')
          : 'Não foi possível limpar o cache local'),
      backgroundColor:
          ok ? const Color(0xFF2e6b46) : const Color(0xFF8b1a1a),
      duration: const Duration(seconds: 4),
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

    // Conecta AGORA, e não "quando der". A primeira conexão da replica baixa
    // o banco inteiro e é a ÚNICA que depende de rede boa; antes ela ficava
    // para o próximo _garantirConexao(), ou seja, para o momento imprevisível
    // em que o app fosse consultar algo — tipicamente já no galpão, com sinal
    // fraco, que é como se cai no modo remoto sem perceber. Aqui o usuário
    // está parado na tela de ⚙️ e vê o resultado.
    setState(() => _reconectando = true);
    await TursoService().reconectar();
    if (!mounted) return;
    setState(() => _reconectando = false);

    final servico = TursoService();
    final (texto, cor) = switch (servico) {
      _ when !servico.isConnected => (
          'Configuração salva, mas não deu para conectar — confira URL, '
              'token e a internet.',
          const Color(0xFF8b1a1a),
        ),
      _ when servico.caiuParaRemoto => (
          'Salvo, mas o cache local não pôde ser aberto — veja o aviso '
              'logo abaixo.',
          const Color(0xFF8b6a1a),
        ),
      _ when servico.modoLocal => (
          'Salvo ✓ — cache local pronto, os dados já estão no aparelho.',
          const Color(0xFF2e6b46),
        ),
      _ => (
          'Salvo ✓ — conectado direto no banco online.',
          const Color(0xFF2e6b46),
        ),
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(texto),
      backgroundColor: cor,
      duration: Duration(seconds: servico.modoLocal ? 3 : 6),
    ));
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

  Future<void> _alterarBaixaAutomatica(bool ligada) async {
    setState(() => _baixaAutomatica = ligada);
    await BaixaPorContagemService.salvarAutomatica(ligada);
    // Religar o interruptor é pedido explícito: a próxima tela roda a baixa na
    // hora, sem esperar a janela de [intervaloMinimoAutomatica].
    if (ligada) BaixaPorContagemService().esquecerJanela();
  }

  // ── Mapa da loja ───────────────────────────────────────────────────────────

  void _alterarBonecos(int quantidade) {
    setState(() => _bonecos = quantidade);
    // O mapa escuta PreferenciasMapa.bonecos, então a cena já reflete a escolha
    // quando o usuário voltar para ela.
    PreferenciasMapa.salvarBonecos(quantidade);
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
              // Desabilitado enquanto conecta: a primeira vez baixa o banco
              // inteiro e pode levar bem mais que um toque de botão sugere.
              onPressed: _reconectando ? null : _salvarConfig,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(_reconectando
                  ? 'Salvando e conectando…'
                  : 'Salvar configuração'),
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
                    activeThumbColor: const Color(0xFF4a9d6a),
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
                  // O app está em modo remoto com o cache local LIGADO: até
                  // aqui, esta tela mostrava a preferência e escondia o que
                  // valia de verdade. Quem está nesse estado grava tudo pela
                  // rede (e vê "não deu para gravar" com sinal ruim) sem ter
                  // como saber por quê.
                  if (_cacheLocal && TursoService().caiuParaRemoto)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2a1e10),
                          borderRadius: BorderRadius.circular(6),
                          border:
                              Border.all(color: const Color(0xFF6b4a1e)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '⚠ O cache local não pôde ser aberto',
                              style: TextStyle(
                                  color: Color(0xFFe0a33e),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'O app está gravando direto no banco online, '
                              'então cada lançamento depende da internet e o '
                              'Sincronizar não tem o que enviar. Costuma ser '
                              'sinal fraco na primeira abertura, enquanto a '
                              'base é baixada.',
                              style: TextStyle(
                                  color: Color(0xFFc8b79a),
                                  fontSize: 11,
                                  height: 1.4),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed:
                                  _reconectando ? null : _tentarCacheLocal,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: Text(_reconectando
                                  ? 'Tentando…'
                                  : 'Tentar de novo'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFe0a33e),
                                side: const BorderSide(
                                    color: Color(0xFF6b4a1e)),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_cacheLocal)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _textoUltimaSync(),
                                style: const TextStyle(
                                    color: Color(0xFF8a9aa8), fontSize: 11),
                              ),
                              if (TursoService().gravacoesPendentes > 0) ...[
                                const SizedBox(height: 4),
                                // O que ainda não subiu, dito antes de o
                                // usuário apertar Sincronizar: é a resposta
                                // para "sincronizou mesmo?" sem ter de
                                // adivinhar pelo tempo que o botão levou.
                                Text(
                                  TursoService().gravacoesPendentes == 1
                                      ? '1 gravação esperando envio'
                                      : '${TursoService().gravacoesPendentes} '
                                          'gravações esperando envio',
                                  style: const TextStyle(
                                      color: Color(0xFFe0a33e),
                                      fontSize: 11,
                                      height: 1.3),
                                ),
                              ],
                              if (TursoService().ultimoErroSync != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Última falha: '
                                  '${TursoService().ultimoErroSync}',
                                  style: const TextStyle(
                                      color: Color(0xFFe57373),
                                      fontSize: 11,
                                      height: 1.3),
                                ),
                              ],
                            ],
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
                  if (_cacheLocal)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed:
                              _limpandoCache ? null : _confirmarLimparCache,
                          icon: _limpandoCache
                              ? const SizedBox(
                                  width: 13,
                                  height: 13,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFFe57373),
                                  ),
                                )
                              : const Icon(Icons.delete_sweep_outlined, size: 15),
                          label: Text(_limpandoCache
                              ? 'Limpando...'
                              : 'Limpar cache local'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFe57373),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 4),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ],

            // ── Paletes ───────────────────────────────────────────────────
            // Os paletes de madeira do piso são os únicos móveis cadastrados
            // em runtime (os demais são const no código), então precisam de
            // CRUD aqui: entram e saem da loja conforme a necessidade, sem
            // depender de uma nova versão do app.
            const SizedBox(height: 28),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0d1117),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF232f3a)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
                    child: Row(children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Paletes',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Paletes de madeira do piso (15 posições, 5 × 3). '
                              'Aparecem no fim do carrossel de estantes; como a '
                              'estante 5, não são desenhados no mapa da loja.',
                              style: TextStyle(
                                  color: Color(0xFF8a9aa8),
                                  fontSize: 11,
                                  height: 1.4),
                            ),
                          ],
                        ),
                      ),
                      if (_salvandoPalete)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFFe87722),
                            ),
                          ),
                        ),
                    ]),
                  ),
                  if (_paletes.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Text(
                        'Nenhum palete cadastrado.',
                        style:
                            TextStyle(color: Color(0xFF5a6a78), fontSize: 12),
                      ),
                    )
                  else
                    ..._paletes.map((p) => Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                          child: Row(children: [
                            Container(
                              width: 34,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2a1a0e),
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                    color: const Color(0xFFb7783f)),
                              ),
                              child: Text(
                                '${p.num}',
                                style: const TextStyle(
                                    color: Color(0xFFd9a26a),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    p.apelido.isEmpty
                                        ? 'Palete ${p.num}'
                                        : p.apelido,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 12.5),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${p.colunas * p.fileiras} posições · '
                                    '${p.colunas} × ${p.fileiras}',
                                    style: const TextStyle(
                                        color: Color(0xFF8a9aa8),
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: _salvandoPalete
                                  ? null
                                  : () => _editarPalete(p),
                              icon: const Icon(Icons.edit_outlined, size: 17),
                              color: const Color(0xFF8a9aa8),
                              tooltip: 'Editar',
                              visualDensity: VisualDensity.compact,
                            ),
                            IconButton(
                              onPressed: _salvandoPalete
                                  ? null
                                  : () => _confirmarDesativarPalete(p),
                              icon: const Icon(
                                  Icons.remove_circle_outline, size: 17),
                              color: const Color(0xFFe57373),
                              tooltip: 'Desativar',
                              visualDensity: VisualDensity.compact,
                            ),
                          ]),
                        )),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _salvandoPalete ? null : _adicionarPalete,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Adicionar palete'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFe87722),
                          side: const BorderSide(color: Color(0xFF5a3a1e)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 9),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Baixa automática ──────────────────────────────────────────
            // O interruptor existe porque a baixa MEXE em quantidade de
            // estoque sozinha. Quem preferir conferir rack por rack tem de
            // poder desligá-la sem desinstalar nada — e quem a desliga
            // continua vendo o azul do que foi vendido, que é o estado
            // anterior a este recurso, não um defeito.
            const SizedBox(height: 28),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0d1117),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF232f3a)),
              ),
              child: SwitchListTile(
                value: _baixaAutomatica,
                onChanged: _alterarBaixaAutomatica,
                activeThumbColor: const Color(0xFF4a9d6a),
                title: const Text(
                  'Baixar a venda pela contagem',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                subtitle: const Text(
                  'Quando a contagem é confirmada no app Contagem CAMDA, o '
                  'que os endereços têm a mais que o contado sai sozinho dos '
                  'racks e prateleiras — é a venda que ninguém baixou à mão. '
                  'As divergências abertas do app de divergências já entram '
                  'na conta. Nunca cria quantidade, e nunca mexe num produto '
                  'lançado depois da contagem.',
                  style: TextStyle(
                      color: Color(0xFF8a9aa8), fontSize: 11, height: 1.4),
                ),
              ),
            ),

            // ── Mapa da loja ──────────────────────────────────────────────
            // Os bonecos que caminham pelos corredores são enfeite: ficam aqui
            // (e não num botão do mapa) para não roubar espaço da barra de
            // busca, que é o que se usa o tempo todo naquela tela.
            const SizedBox(height: 28),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0d1117),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF232f3a)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Personagens no mapa',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Bonecos caminhando pelos corredores do mapa da '
                          'loja. Desligue se preferir a cena parada ou se o '
                          'aparelho estiver lento.',
                          style: TextStyle(
                              color: Color(0xFF8a9aa8),
                              fontSize: 11,
                              height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: Row(children: [
                      for (var n = 0; n <= PreferenciasMapa.maxBonecos; n++)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                                right: n == PreferenciasMapa.maxBonecos ? 0 : 8),
                            child: _OpcaoBonecos(
                              quantidade:  n,
                              selecionado: _bonecos == n,
                              onTap:       () => _alterarBonecos(n),
                            ),
                          ),
                        ),
                    ]),
                  ),
                ],
              ),
            ),

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

// ── _OpcaoBonecos ───────────────────────────────────────────────────────────
// Uma das três opções de personagens no mapa: nenhum, 1 ou 2.

class _OpcaoBonecos extends StatelessWidget {
  final int          quantidade;
  final bool         selecionado;
  final VoidCallback onTap;

  const _OpcaoBonecos({
    required this.quantidade,
    required this.selecionado,
    required this.onTap,
  });

  String get _rotulo => switch (quantidade) {
        0 => 'Nenhum',
        1 => '1 pessoa',
        _ => '$quantidade pessoas',
      };

  @override
  Widget build(BuildContext context) {
    const camda = Color(0xFFe87722);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selecionado
              ? camda.withValues(alpha: 0.16)
              : const Color(0xFF141a20),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selecionado ? camda : const Color(0xFF232f3a),
          ),
        ),
        child: Column(
          children: [
            Icon(
              quantidade == 0
                  ? Icons.person_off_outlined
                  : Icons.directions_walk,
              size:  18,
              color: selecionado ? camda : const Color(0xFF8a9aa8),
            ),
            const SizedBox(height: 4),
            Text(
              _rotulo,
              style: TextStyle(
                color: selecionado ? camda : const Color(0xFF8a9aa8),
                fontSize: 11,
                fontWeight: selecionado ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
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
