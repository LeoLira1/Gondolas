import 'package:flutter/material.dart';

class Produto {
  final String codigo;
  final String nome;
  final String categoria;
  final String corHex;

  const Produto({
    required this.codigo,
    required this.nome,
    required this.categoria,
    required this.corHex,
  });

  Color get cor {
    final hex = corHex.replaceFirst('#', '');
    return Color(int.parse('FF$hex', radix: 16));
  }
}

class CaixaLayout {
  final int gondolaNum;
  final int andar;
  final String produtoCodigo;
  final String produtoNome;
  final double posX;
  final double posZ;
  final String corHex;

  const CaixaLayout({
    required this.gondolaNum,
    required this.andar,
    required this.produtoCodigo,
    required this.produtoNome,
    required this.posX,
    required this.posZ,
    required this.corHex,
  });
}
