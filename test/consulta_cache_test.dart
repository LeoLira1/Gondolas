import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/turso_service.dart';

import '../tool/verify_consulta_cache.dart' as verificacao;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('lançamento sem confirmação reutiliza UUID até sucesso', () async {
    SharedPreferences.setMockInitialValues({});
    final servico = TursoService();
    final primeiro = await servico.pedidoOnline('rack-teste');
    expect(await servico.pedidoOnline('rack-teste'), primeiro);
    // Uma nova instância das preferências lê o mesmo pedido persistido.
    await (await SharedPreferences.getInstance()).reload();
    expect(await servico.pedidoOnline('rack-teste'), primeiro);
    expect(await servico.pedidoOnline('outro-rack'), isNot(primeiro));
    await servico.concluirPedidoOnline('rack-teste');
    expect(await servico.pedidoOnline('rack-teste'), isNot(primeiro));
  });
  test(
    'cache de consulta preserva dados confirmados com rede lenta e falhas',
    verificacao.main,
  );
}
