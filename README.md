# Gôndolas CAMDA

Visualizador 3D das gôndolas e estantes da loja CAMDA (Quirinópolis-GO), em Flutter.
Renderização 3D por software (painter's algorithm, sem WebGL/OpenGL), com endereçamento
de produtos por `(estante, coluna, nível, slot)` sincronizado via Turso/libSQL.

## Funcionalidades

- Cenas 3D navegáveis: gôndola hexagonal, estantes, estante de parede, expositores (MagnoJet, Nellore Isoflex)
- Endereçamento de estoque integrado à tabela `estante_layout` no Turso
- Modo Conferência para auditoria física do estoque
- Sincronização de quantidades com os apps `inventariocamda` e `camda-estoque` via `estoque_localizado`

## Créditos

Ícone do app: [Map icon criado por Freepik — Flaticon](https://www.flaticon.com/br/icones-gratis/mapa)
