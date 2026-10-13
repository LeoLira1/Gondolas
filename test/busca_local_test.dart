import 'package:flutter_test/flutter_test.dart';

import '../tool/verify_busca_local.dart' as verificacao;

void main() {
  test(
    'busca usa cópia completa e preserva posições confirmadas',
    verificacao.main,
  );
}
