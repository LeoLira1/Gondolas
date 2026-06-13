import 'package:flutter/material.dart';
import 'gondola_scene.dart';

void main() {
  runApp(const CamdaApp());
}

class CamdaApp extends StatelessWidget {
  const CamdaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gôndola 3D CAMDA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2e6b46),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const GondolaPage(),
    );
  }
}

class GondolaPage extends StatelessWidget {
  const GondolaPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0e1014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0e1014),
        elevation: 0,
        titleSpacing: 12,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2e6b46),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'CAMDA',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Gôndola Octogonal — Protótipo 3D',
                style: TextStyle(color: Colors.white, fontSize: 15),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: const Stack(
        children: [
          GondolaScene(),
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'arraste para girar  ·  pinça para zoom',
                style: TextStyle(
                  color: Color(0x88ffffff),
                  fontSize: 12,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
