import 'package:flutter/material.dart' show Color;

import 'gondola_scene.dart' show Face, Vec3;

// ─────────────────────────────────────────────────────────────────────────────
// Balcão de Atendimento — maquete pro mapa da loja (LojaScene)
//
// Peça comprida encostada no corredor da parede esquerda, paralela à Estante
// Parede (13–18) e entre ela e a coluna de gôndolas 8–12. Medidas reais:
// 7,95 m de comprimento × 1,10 m de altura, tampo de 0,60 m de profundidade e
// 6 cm de espessura sobre um corpo de 0,18 m — o perfil em "T" que aparece de
// frente, com 21 cm de balanço do tampo para cada lado.
//
// O corpo tem dois recortes retangulares abertos por cima (não são nichos
// fechados: o tampo desce junto), em posições simétricas ao longo do
// comprimento. Chamada no switch de tipos em buildFaces da LojaGeometry:
//
//   } else if (item.numero == balcaoNum) {
//     balcaoLoja(faces, item.x, item.z, item.w, item.d, cor);
//   }
// ─────────────────────────────────────────────────────────────────────────────

/// Espessura do corpo, em metros — as coordenadas X/Z do mapa são as reais da
/// loja (só o Y é comprimido), então as medidas do plano entram direto.
const double _corpoEsp = 0.18;

/// Largura de cada recorte e o centro deles, em fração do comprimento.
const double _recorteLarg = 1.18;
const List<double> _recorteCentros = [0.215, 0.785];

/// Quanto o recorte rebaixa o corpo, em fração da altura dele.
const double _recorteRebaixo = 0.43;

/// Desenha o balcão com o comprimento correndo em **Z** (ele é paralelo à
/// parede esquerda): [w] é a espessura em X — a profundidade do tampo — e [d]
/// o comprimento.
void balcaoLoja(
  List<Face> faces,
  double cx, double cz, double w, double d,
  Color cor,
) {
  final hw = w / 2, hd = d / 2;

  // Altura no mapa. As demais estruturas usam LojaGeometry._estanteH (0,85)
  // para representar ~1,9 m reais; o balcão tem 1,10 m e entra
  // proporcionalmente mais baixo — é justamente o degrau de altura que faz ele
  // ler como balcão, e não como mais uma estante encostada na parede.
  const h = 0.50;

  // Espessura do tampo: os 6 cm reais dariam ~0,027 nesta escala, um fio que
  // se perde no contorno das faces. Sobe um pouco para o "T" continuar legível
  // de longe, sem descolar da proporção real.
  const tampoT  = h * 0.07;  // ≈ 0,035
  const corpoH  = h - tampoT;

  void box(double x0, double x1, double y0, double y1,
           double z0, double z1, Color c) {
    faces.add(Face([Vec3(x0,y1,z0), Vec3(x0,y1,z1), Vec3(x1,y1,z1), Vec3(x1,y1,z0)], c));
    faces.add(Face([Vec3(x0,y0,z1), Vec3(x1,y0,z1), Vec3(x1,y1,z1), Vec3(x0,y1,z1)], c));
    faces.add(Face([Vec3(x1,y0,z0), Vec3(x0,y0,z0), Vec3(x0,y1,z0), Vec3(x1,y1,z0)], c));
    faces.add(Face([Vec3(x1,y0,z1), Vec3(x1,y0,z0), Vec3(x1,y1,z0), Vec3(x1,y1,z1)], c));
    faces.add(Face([Vec3(x0,y0,z0), Vec3(x0,y0,z1), Vec3(x0,y1,z1), Vec3(x0,y1,z0)], c));
  }

  final z0 = cz - hd, z1 = cz + hd;
  // O corpo é mais fino que o tampo e fica centrado nele: sobra o balanço de
  // 21 cm para cada lado.
  final corpoX0 = cx - _corpoEsp / 2, corpoX1 = cx + _corpoEsp / 2;

  // Bordas dos recortes ao longo de Z, em ordem. Percorrer os intervalos entre
  // elas e desenhar cada trecho cheio ou rebaixado reproduz a silhueta da
  // vista de frente sem precisar de recorte booleano na malha — cada trecho é
  // um bloco de corpo com o tampo por cima, na altura daquele trecho.
  final bordas = <double>[z0];
  for (final centro in _recorteCentros) {
    final zc = z0 + d * centro;
    bordas.add(zc - _recorteLarg / 2);
    bordas.add(zc + _recorteLarg / 2);
  }
  bordas.add(z1);

  for (var i = 0; i < bordas.length - 1; i++) {
    // Índice ímpar = trecho entre as duas bordas de um recorte.
    final rebaixado = i.isOdd;
    final topoCorpo = rebaixado ? corpoH * (1 - _recorteRebaixo) : corpoH;
    box(corpoX0, corpoX1, 0, topoCorpo, bordas[i], bordas[i + 1], cor);
    box(cx - hw, cx + hw, topoCorpo, topoCorpo + tampoT,
        bordas[i], bordas[i + 1], cor);
  }
}
