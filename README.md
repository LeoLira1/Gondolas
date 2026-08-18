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
- **Quantidade em UNIDADES, do ERP ao cubo.** O galpão já converteu para
  litros (baldes/caixas × 20) e isso era discrepância garantida contra o
  `qtd_sistema` do `estoque_mestre`, que está em unidade: o mesmo produto que
  o app do scanner (`LeoLira1/scanner`) mostra com 559 aparecia aqui como
  "sistema 19.4". Agora não há conversão em lugar nenhum — o que se digita é o
  que se grava, é o que se soma no endereçado e é o que se compara com o
  sistema. Os racks lançados na convenção antiga são convertidos uma única vez
  pela migração `galpao_quantidade_em_unidades_v1`, que divide por 20 os
  produtos de 20 L e 5 L em `galpao_racks` e no espelho de
  `estoque_localizado`.
- **Busca acende TODAS as posições do produto**: procurar um produto no mapa
  da loja abre o galpão com o endereço escolhido marcado e todos os racks
  daquele produto acesos em laranja — o mesmo produto costuma ocupar vários
  paletes, às vezes em ruas diferentes, e antes só o endereço da linha
  clicada se destacava. Quem casa é o CÓDIGO do produto, não o endereço
  (mesma regra do Modo Conferência). Quando as posições cruzam mais de uma
  rua, o filtro fica em `Todas` em vez de isolar a rua do endereço escolhido,
  e os chips das ruas com o produto ganham um ponto laranja. O painel de um
  rack tem o mesmo destaque num botão (`Destacar N posições`), que só aparece
  quando o produto está em mais de um lugar — acender a posição que já está
  aberta na tela não mostra nada.
- **Saldo do produto no palete (sistema × endereçado)**: com a leitura de
  saldo ligada (botão da balança na barra superior, ligada por padrão), o rack
  de um produto que ainda tem carga sem endereço fica **vermelho** e o de um
  produto endereçado além do que o sistema registra fica **azul** — as mesmas
  cores que as gôndolas e estantes já usam para divergência de contagem. O
  painel do endereço mostra a conta por extenso (`Faltam 55 unidades por
  endereçar` / `Sistema 145 · endereçado 90`), e ela também aparece ao escolher
  o produto para lançar numa vaga, que é quando interessa saber quanto ainda
  falta distribuir. Saldo que FECHA não ganha caixa colorida — vira uma linha
  quieta (`Tudo endereçado · sistema 2112 unidades`); a moldura é do aviso.
  O endereçado soma TODOS os locais do produto em `estoque_localizado`
  (galpão + gôndolas + estantes) contra `estoque_mestre.qtd_sistema` — a mesma
  conta com que o app fecha o inventário cíclico —, então um produto que também
  está na loja não aparece em falta por causa disso. Produto sem linha no
  `estoque_mestre` fica na cor da categoria: sem `qtd_sistema` não há saldo a
  afirmar. A precedência das cores é Modo Conferência > busca > saldo >
  categoria.
- **Os dois lados da conta somam TODOS os códigos do produto.** O mesmo item
  tem mais de uma linha em `estoque_mestre` (`254185` e `US254185`), e ler só
  a do rack mostrava metade do saldo. O agrupamento é o mesmo do app do
  scanner (`lib/codigos_vinculados.dart`): primeiro o cadastro
  (`mapa_produtos` + `mapa_produtos_codigos`), e só na falta dele o nome do
  produto, ignorando irmão já vinculado a outro produto. Quando mais de um
  código entra na soma, a tarja diz quais (`códigos somados · 254185 +
  US254185`).
- **Camadas de cima enxutas.** O cabeçalho é `Galpão` + vagas livres em uma
  linha cada (o título espremido quebrava em duas e o subtítulo descia por
  cima dos chips de rua, que ficam numa camada própria e não empurram nada),
  e as faixas de destaque e de saldo cabem numa linha cada — empilhadas em
  duas linhas, as duas juntas comiam um quarto da tela por cima do mapa. O
  atalho `Ver todas as ruas` saiu da faixa de destaque: o chip `Todas` está
  logo acima, na barra de ruas, fazendo o mesmo.
- **Modo Conferência também no galpão**: o mesmo botão do mapa da loja acende
  em ciano os racks que guardam pendente de hoje (`contagem_itens`), apaga o
  resto e põe um contador `<posição> · <nº>` acima de cada pilha. O cruzamento
  do galpão usa TODOS os pendentes, sem o filtro de categorias de depósito da
  loja — herbicida, adubo e óleo têm endereço justamente aqui. O banner da
  loja ganhou o atalho `N no galpão`, que abre o galpão já em conferência.

## Créditos

Ícone do app: [Map icon criado por Freepik — Flaticon](https://www.flaticon.com/br/icones-gratis/mapa)
