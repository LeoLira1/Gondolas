import 'package:flutter/material.dart';

import 'galpao_config.dart';
import 'galpao_scene.dart';

/// Mapa 3D do galpão de racks.
///
/// Etapa 2: cena estática. As pilhas ainda não vêm do banco (etapa 6), então
/// o galpão abre com as 78 vagas livres — é o estado verdadeiro enquanto não
/// houver persistência, e não uma tela de exemplo com carga inventada.
/// Seleção, painel inferior, lançamento/esvaziamento e filtro por rua entram
/// nas etapas seguintes.
class GalpaoPage extends StatelessWidget {
  const GalpaoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b0c0e),
      body: Stack(
        children: [
          const GalpaoScene(),

          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BotaoRedondo(
                      icone: Icons.arrow_back,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'CAMDA · Galpão',
                            style: TextStyle(
                              color:      Colors.white,
                              fontSize:   15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${GalpaoConfig.totalPosicoes} posições · '
                            '${GalpaoConfig.ruas.length} ruas · '
                            'até ${GalpaoConfig.niveisMax} racks empilhados',
                            style: TextStyle(
                              color:    Colors.white.withValues(alpha: 0.45),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            left: 16, right: 16, bottom: 20,
            child: SafeArea(
              top: false,
              child: Text(
                'Um dedo arrasta · dois dedos giram e dão zoom. '
                'Contorno = vaga livre para carga nova.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color:    Colors.white.withValues(alpha: 0.35),
                  fontSize: 11,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BotaoRedondo extends StatelessWidget {
  final IconData     icone;
  final VoidCallback onTap;

  const _BotaoRedondo({required this.icone, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        width:  46,
        decoration: BoxDecoration(
          color:        const Color(0xEE141518),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Icon(icone, color: const Color(0xFF8a877f), size: 20),
      ),
    );
  }
}
