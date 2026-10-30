import 'package:flutter_test/flutter_test.dart';
import 'package:gondola_camda/gondola_scene.dart'
    show GondolaGeometry, Vec3, intersecaoRaioCaixa;

void main() {
  // Caixa de 0,40 × 0,52 × 0,40 apoiada em y = 1, centrada em (1, 0).
  const min = Vec3(0.8, 1.0, -0.2);
  const max = Vec3(1.2, 1.52, 0.2);

  test('raio de cima acerta o topo da caixa', () {
    final t = intersecaoRaioCaixa(
        const Vec3(1, 5, 0), const Vec3(0, -1, 0), min: min, max: max);
    expect(t, closeTo(5 - 1.52, 1e-9));
  });

  test('raio inclinado pela lateral acerta antes de chegar à prateleira', () {
    // Vindo de fora, de lado e de cima: entra pela face x = 1,2 a meia altura.
    const origem = Vec3(3, 3, 0);
    final dir = (const Vec3(1.2, 1.26, 0) - origem).normalized;
    final t = intersecaoRaioCaixa(origem, dir, min: min, max: max);
    expect(t, isNotNull);
    final ponto = origem + dir * t!;
    expect(ponto.x, closeTo(1.2, 1e-9));
    // O plano da prateleira (y = 1) fica mais longe: era nele que o toque
    // "vazava" para a caixa de trás.
    final tPrateleira = (1.0 - origem.y) / dir.y;
    expect(t, lessThan(tPrateleira));
  });

  test('raio que passa ao lado não acerta', () {
    final t = intersecaoRaioCaixa(
        const Vec3(2, 5, 0), const Vec3(0, -1, 0), min: min, max: max);
    expect(t, isNull);
  });

  test('o volume do toque é o mesmo que o desenho usa', () {
    expect(GondolaGeometry.caixaLargura, 0.40);
    expect(GondolaGeometry.caixaAltura, 0.52);
    expect(GondolaGeometry.caixaProfundidade, 0.40);
  });
}
