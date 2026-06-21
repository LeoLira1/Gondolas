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

class CaixaColocadaEstante {
  final int    coluna;
  final int    nivel;
  final int    slot;
  final String produtoId;

  const CaixaColocadaEstante({
    required this.coluna,
    required this.nivel,
    required this.slot,
    required this.produtoId,
  });
}

class CaixaLayoutEstante {
  final int    estanteNum;
  final int    coluna;
  final int    nivel;
  final int    slot;
  final String produtoCodigo;
  final String produtoNome;
  final String corHex;

  const CaixaLayoutEstante({
    required this.estanteNum,
    required this.coluna,
    required this.nivel,
    required this.slot,
    required this.produtoCodigo,
    required this.produtoNome,
    required this.corHex,
  });
}
