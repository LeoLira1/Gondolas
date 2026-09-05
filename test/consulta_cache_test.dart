import 'package:flutter_test/flutter_test.dart';

import '../tool/verify_consulta_cache.dart' as verificacao;

void main() {
  test(
    'cache de consulta preserva dados confirmados com rede lenta e falhas',
    verificacao.main,
  );
}
