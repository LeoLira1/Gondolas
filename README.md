# Gôndolas CAMDA

Visualizador 3D das gôndolas e estantes da loja CAMDA (Quirinópolis-GO), em Flutter.
Renderização 3D por software (painter's algorithm, sem WebGL/OpenGL), com endereçamento
de produtos por `(estante, coluna, nível, slot)` sincronizado via Turso/libSQL.

## Funcionalidades

- Cenas 3D navegáveis: gôndola hexagonal, estantes, estante de parede, expositores (MagnoJet, Nellore Isoflex)
- Endereçamento de estoque integrado à tabela `estante_layout` no Turso
- Modo Conferência para auditoria física do estoque
- Sincronização de quantidades com os apps `inventariocamda` e `camda-estoque` via `estoque_localizado`
- Mapa 3D do galpão de racks (botão na barra do mapa da loja)

## Galpão de racks

Prédio separado da loja, com racks metálicos empilháveis — o rack é a própria
unidade de armazenagem, empilhado direto sobre outro, no máximo 4 de altura.

- **85 posições de chão em 8 ruas**, numeradas de 1 a 85 de forma global e
  contínua (não reinicia por rua). O endereço exibido é `<número> · N<nível>`.
  As Ruas 2 (15–25) e 8 (79–85) atravessam as pontas do galpão na horizontal;
  as outras seis correm no comprimento.
- **O nível não é identidade**: é a ordem do rack dentro da pilha. Esvaziar um
  rack faz os de cima descerem, e o que era N2 passa a ser N1 — por isso o
  nível nunca é gravado dentro de um código de endereço textual.
- Planta (coordenadas, ruas, medidas) em `lib/galpao_config.dart`, a única
  fonte da geometria. As larguras de corredor ainda são estimativas.
- Persistência em `galpao_posicoes` (estrutura, semeada do config) e
  `galpao_racks` (ocupação, com renumeração transacional), espelhadas em
  `estoque_localizado` com `local_tipo = 'galpao'` para o estoque do galpão
  contar nos mesmos totais dos apps irmãos.
- Quantidades são lançadas na unidade que se conta no chão — baldes (produto
  de 20 L) ou caixas (5 L × 4) — e gravadas em litros.
- **Busca acende TODAS as posições do produto**: procurar um produto no mapa
  da loja abre o galpão com o endereço escolhido marcado e todos os racks
  daquele produto acesos em laranja — o mesmo produto costuma ocupar vários
  paletes, às vezes em ruas diferentes, e antes só o endereço da linha
  clicada se destacava. Quem casa é o CÓDIGO do produto, não o endereço
  (mesma regra do Modo Conferência). Quando as posições cruzam mais de uma
  rua, o filtro fica em `Todas` em vez de isolar a rua do endereço escolhido,
  e os chips das ruas com o produto ganham um ponto laranja. O painel de um
  rack tem o mesmo destaque num botão (`Destacar N posições deste produto`),
  para partir de um palete achado no mapa.
- **Modo Conferência também no galpão**: o mesmo botão do mapa da loja acende
  em ciano os racks que guardam pendente de hoje (`contagem_itens`), apaga o
  resto e põe um contador `<posição> · <nº>` acima de cada pilha. O cruzamento
  do galpão usa TODOS os pendentes, sem o filtro de categorias de depósito da
  loja — herbicida, adubo e óleo têm endereço justamente aqui. O banner da
  loja ganhou o atalho `N no galpão`, que abre o galpão já em conferência.

## Créditos

Ícone do app: [Map icon criado por Freepik — Flaticon](https://www.flaticon.com/br/icones-gratis/mapa)
