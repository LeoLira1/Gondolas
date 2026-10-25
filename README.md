# Gôndolas CAMDA

Visualizador 3D das gôndolas e estantes da loja CAMDA (Quirinópolis-GO), em Flutter.
Renderização 3D por software (painter's algorithm, sem WebGL/OpenGL), com endereçamento
de produtos por `(estante, coluna, nível, slot)` sincronizado via Turso/libSQL.

## Funcionalidades

- Cenas 3D navegáveis: gôndola hexagonal, estantes, estante de parede, expositores (MagnoJet, Nellore Isoflex, Monitor e o Expositor de Madeira E24 — escada de 3 degraus × 6 produtos encostada no balcão)
- Endereçamento de estoque integrado à tabela `estante_layout` no Turso
- Modo Conferência para auditoria física do estoque
- Sincronização de quantidades com os apps `inventariocamda` e `camda-estoque` via `estoque_localizado`
- **Baixa automática da venda pela contagem** — o que foi vendido sai sozinho dos racks e prateleiras
- Ilha de paletes no corredor central da loja (12 espaços × 5 produtos)
- Mostruário de ferragens num palete na parede da direita da loja (20 posições)
- Mapa 3D do galpão de racks (botão na barra do mapa da loja)
- Mapa 3D do barracão de paletes (botão ao lado do galpão, na mesma barra)

## Ilha de paletes (loja)

No corredor central da loja, entre a Gôndola 7 (lado do caixa) e a Gôndola 6
(lado da entrada), ficam 12 paletes encostados e forrados com tapume verde —
uma plataforma baixa só, 2 paletes de largura × 6 de comprimento. Cada palete
é um **espaço** (1–12) e recebe até **5 produtos** lado a lado.

- **Numeração dos espaços** igual ao croqui: de 2 em 2, do caixa para a
  entrada, esquerda antes da direita (1–2 perto do caixa, 11–12 perto da
  entrada). O número aparece no tapume do mapa e flutuando sobre cada palete
  na cena de detalhe.
- **Endereço `espaço-produto`**: `3-2` é o produto 2 do espaço 3. O chip da
  cena mostra `Ilha · espaço 3 · produto 2`, e a busca, `Espaço 3`.
- **Estrutura fixa nº 22** na infra de estante (`local_tipo = 'estante'`,
  slot sempre 0), com `nivel` = espaço (0–11) e `coluna` = produto (0–4) — sem
  coluna nem tabela nova. Por isso busca, saldo, Modo Conferência e baixa
  pela contagem já enxergam a ilha. Não confundir com os paletes soltos
  (101+), cadastrados em runtime e sem maquete no mapa.
- No carrossel de estantes ela vem depois dos expositores. Geometria (palete
  PBR de 1,20 × 1,00 m, medidas reais) em `lib/ilha_paletes_scene.dart`; no
  mapa ela entra em escala de planta (1,8 × 5,6 m) para deixar corredor dos
  dois lados, e a rota do boneco funcionário passou a contorná-la.

## Mostruário (loja)

Palete de madeira (PBR 1,20 × 1,00 m) no chão da parede da direita, entre a
Estante 1 e a cozinha, com uns 20 tipos de produto à mostra — porcas,
arruelas, barras de ferro, correntes, pá, rastelo. Não é estante: não tem
nível, só posições no tampo.

- **20 posições, numeradas 1–20** numa grade de 5 × 4: a fileira 1–5 é a da
  frente (corredor), a 16–20 a do fundo (parede), sempre da esquerda para a
  direita. O número aparece sobre cada posição na cena de detalhe.
- **Endereço é a posição**: o chip da cena mostra `Mostruário · posição 7`,
  e a busca, `Posição 7`.
- **Estrutura fixa nº 23** na infra de estante (`local_tipo = 'estante'`,
  slot sempre 0), com `nivel` = posição (0–19) e `coluna` sempre 0 — a busca
  agrupa por nível e assim já devolve a posição exata. Sem coluna nem tabela
  nova: busca, saldo, Modo Conferência e baixa pela contagem já enxergam.
- No carrossel de estantes ele vem logo depois da ilha. Geometria em
  `lib/mostruario_scene.dart`; no mapa entra em medida real, com o lado de
  1,20 m ao longo da parede, e o corredor do cliente passa pela frente dele.

## Galpão de racks

Prédio separado da loja, com racks metálicos empilháveis — o rack é a própria
unidade de armazenagem, empilhado direto sobre outro, no máximo 4 de altura.

- **Duas partes, 138 posições de chão em 15 ruas**, numeradas de 1 a 138 de
  forma global e contínua (não reinicia por rua nem por parte). O endereço
  exibido é `<número> · N<nível>`.
  - **Parte 1** — 85 posições em 8 ruas. As Ruas 2 (15–25) e 8 (79–85)
    atravessam as pontas do galpão na horizontal; as outras seis correm no
    comprimento.
  - **Parte 2** — 53 posições: 44 em 4 ruas de 11 (86–129) e 9 gaiolas no
    fim dos corredores (130–138, ver abaixo). As quatro fileiras são
    simples com corredor entre todas. A numeração é uma serpentina: desce a
    Rua 9 (86–96), sobe a 10 (97–107), desce a 11 (108–118), sobe a 12
    (119–129) — o mesmo princípio do perímetro contínuo da parte 1, para quem
    separa carga andar a rua inteira antes de virar. No croqui do galpão ela
    está etiquetada de 1 a 44; no app o endereço é o número global, e é ele
    que vai para a etiqueta nova do rack: dois `44` no mesmo galpão não são
    endereço, são ambiguidade.
  - **Gaiolas no fim dos corredores (Parte 2)** — no fundo de cada um dos 3
    corredores (o lado do 86) ficam 3 gaiolas lado a lado, de uma fileira à
    outra: Rua 13 (130–132) entre a R12 e a R11, Rua 14 (133–135) entre a R11
    e a R10, Rua 15 (136–138) entre a R10 e a R9, numeradas da esquerda para a
    direita, continuando do 129. São racks como os outros (empilham até 4,
    aceitam rack misto), com o lado de 1,20 m em Z como as fileiras vizinhas
    (`rackAtravessado`) e passo de 1,05 m — de comprido, três não caberiam no
    corredor de 3,45 m. Posição estimada em `galpao_config.dart`.
- **O mapa desenha uma parte de cada vez**, trocada pelo seletor `Parte 1` /
  `Parte 2` acima dos chips de rua — os dois blocos ficam longe um do outro no
  chão, e enquadrar os dois juntos deixaria cada rack do tamanho de um pixel.
  A câmera reenquadra ao trocar, os chips passam a ser os da parte aberta
  (`R1`–`R8` ou `R9`–`R15`) e o filtro volta para `Todas`. O que não está
  desenhado também não recebe toque: a lista de alvos do hit-test é a da parte
  aberta. Os pontos dos chips de parte (ciano de conferência, laranja de
  busca) são o que impede o outro bloco de sumir do mundo — é a marca que diz
  que o produto procurado, ou a contagem de hoje, também está lá. O campo
  `nº` atravessa as partes sozinho: digitar 100 abre a parte 2 no endereço,
  porque quem tem o número na mão não pensa em bloco.
- **O nível não é identidade**: é a ordem do rack dentro da pilha. Esvaziar um
  rack faz os de cima descerem, e o que era N2 passa a ser N1 — por isso o
  nível nunca é gravado dentro de um código de endereço textual.
- Planta (coordenadas, ruas, medidas) em `lib/galpao_config.dart`, a única
  fonte da geometria. As larguras de corredor ainda são estimativas.
- Persistência em `galpao_posicoes` (estrutura, semeada do config) e
  `galpao_racks` (ocupação, com renumeração transacional), espelhadas em
  `estoque_localizado` com `local_tipo = 'galpao'` para o estoque do galpão
  contar nos mesmos totais dos apps irmãos.
- **Rack misto: até 5 produtos no mesmo palete.** Quando sobra pouco de um
  produto, ele vai junto no palete de outro em vez de ocupar uma gaiola
  sozinho. No painel do rack, `Adicionar outro produto neste rack (n/5)`
  põe mais um. O rack misto lista cada produto com a sua quantidade, e 0 num
  deles tira só aquele (o palete fica com os outros). O último produto que
  sai tira o rack, e a pilha desce como sempre. No mapa o rack misto ganha
  duas listras claras nas laterais, e acende se QUALQUER produto dele for o
  procurado, estiver pendente de conferência ou com falta/sobra. O primeiro
  produto continua na linha de `galpao_racks`. Os demais ficam em
  `galpao_rack_itens`, presos pelo `rack_uuid`, e cada um vira uma linha
  própria no espelho de `estoque_localizado` (mesmo nível), então busca,
  saldo, Modo Conferência e baixa automática enxergam todos eles.
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
- **O número do palete é a única ação do rack**: tocar a quantidade no painel
  abre o teclado que a corrige, e **0 tira o palete do endereço** (com aviso
  em vermelho da descida da pilha antes de confirmar). O painel não tem mais a
  barra de botões `Esvaziar` / `Lançar N<n>` embaixo — duas faixas coloridas
  na largura toda competiam com o que se vai ler ali, que é o produto e o
  número. Lançar em cima de uma pilha parcial é tocar o contorno da vaga no
  mapa.
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

## Barracão

Terceiro prédio, ao lado da loja e do galpão, com o botão de caixas na mesma
barra do mapa da loja. Aqui não há rack nem pilha: a unidade de armazenagem é
o **palete de madeira apoiado no chão, com um bag de 1000 kg em cima**, e cada
palete é UM endereço, com UM produto.

- **Obra**: retângulo de 3500 × 1000 cm, pé-direito 600, paredes de 20. As
  aberturas ficam todas na parede de 35 m em `Z = 0` — porta (600–800, vão de
  200 × 300), portão (1300–1800, 500 × 450) e porta (2300–2500, 200 × 300) —,
  cada uma com verga até o pé-direito. As outras três paredes são cheias. A
  planta inteira está em `lib/barracao_config.dart`, a única fonte da
  geometria; os panos cheios da frente são DERIVADOS das aberturas, então
  mexer numa abertura não deixa um pano velho para trás.
- **Unidade: centímetros.** A planta, as colunas `pos_x`/`pos_z` no Turso e as
  coordenadas do mundo 3D da cena do barracão são todas em cm — a loja e o
  galpão são em metros. Não colide porque o renderizador é adimensional e cada
  cena monta a câmera a partir do seu próprio envelope; o que não pode é
  misturar as duas unidades dentro do barracão.
- **Layout**: fileiras paralelas à parede do fundo, começando encostadas nela e
  avançando para a frente. Passo de 135 cm em X (palete de 120 + 15 de folga) e
  120 cm em Z (100 + 20). A última fileira para onde ainda sobram 400 cm de
  corredor de manobra da empilhadeira — o que hoje dá 4 fileiras de 25 paletes,
  com 500 cm livres na frente. **Esses números não estão fixados no código**:
  são o que o layout padrão calcula, e o layout padrão só serve de semente.
- **Endereços em `barracao_enderecos`** (id, rótulo, `pos_x`, `pos_z`, produto
  e quantidade), com o rótulo `UNIQUE`. A numeração é contínua no barracão
  inteiro, sem reiniciar por fileira: `BAR-01`, `BAR-02`, … `BAR-100`. A
  tabela é semeada UMA vez, quando está vazia — ao contrário de
  `galpao_posicoes`, que é reescrita do código a cada abertura. A diferença é
  deliberada: no galpão a planta é fixa e o código manda; aqui paletes entram e
  saem do chão, e reescrever apagaria justamente o cadastro que a tabela existe
  para guardar. **O app desenha o que vier do banco**, não o que o config
  calcula.
- **Espelho em `estoque_localizado`** com `local_tipo = 'barracao'` e
  `local_num` = id da linha, pelo mesmo motivo do galpão: sem ele, o que está
  endereçado no barracão ficaria fora do inventário cíclico e do Modo
  Conferência dos apps irmãos. `face_ou_coluna` e `andar_ou_nivel` ficam em 0 —
  o palete não tem face, coluna nem nível, ele É o endereço.
- **Câmera padrão isométrica, de frente para a parede das aberturas**, com os
  35 m enquadrados (o enquadramento é calculado a partir do envelope, como no
  galpão). A elevação de 0,92 rad é alta o bastante para a vista passar por
  cima da parede de 6 m e alcançar a fileira da frente — a sombra geométrica da
  parede cobre ~458 cm para dentro, e a fileira da frente começa a 520. O giro
  do usuário não desce abaixo de 0,55 rad pelo mesmo motivo: mais baixo que
  isso, a parede cobre o salão inteiro.
- **O toque num palete abre o painel do galpão**, não um fluxo paralelo:
  `PainelEnderecoGalpao` é literalmente o mesmo widget, com os rótulos do
  barracão (`BAR-07` no lugar de `52 · N3`). Busca de produto por qualquer
  parte do nome, código ou dois termos soltos (`buscarProdutosGalpao`),
  últimos lançados como atalho, e o mesmo teclado de quantidade — inclusive o
  0, que aqui libera o palete em vez de derrubar uma pilha. A costura é a dupla
  `ToqueGalpao`/`RackGalpao`: cada endereço do barracão vira uma posição de um
  nível só.

## Baixa automática da venda pela contagem

O rack ficava azul sozinho. Vende-se 30 do Boral, o ERP baixa o `qtd_sistema`
na planilha do dia seguinte, e os endereços continuam com a quantidade de
antes da venda — endereçado 100 contra sistema 70. Não era erro de ninguém:
este app é o único lugar que sabe em QUE rack o produto está, e ninguém vai lá
tirar 30 do palete a cada nota emitida. O mapa mentia em azul até alguém
corrigir rack por rack.

Agora quem corrige é a **contagem**. Quando um produto é confirmado no app
[Contagem CAMDA](https://github.com/LeoLira1/Contagemsimplificada) — `OK ✓` ou
`Divergência` —, ele grava em `contagem_itens` que a pilha foi conferida. Na
abertura seguinte do app (ou do galpão), a diferença entre o que os endereços
somam e o que foi contado sai dos racks, **de um ou de vários**, e uma faixa
azul no topo do mapa diz o que saiu de onde.

**O alvo é a contagem, não o sistema.** O app de divergências
([`Planilha-`](https://github.com/LeoLira1/Planilha-)) registra o que falta ou
sobra por conta de um cooperado SEM mexer no `qtd_sistema`: uma falta de 30
lançada para o cooperado quer dizer que o sistema tem 100 e o chão tem 70.
Baixar contra o sistema puro deixaria no rack 30 unidades que não existem na
prateleira, então o alvo é `qtd_sistema + Σ delta das divergências abertas` —
o mesmo número que o app de contagem gravou em `qtd_fisica`. É essa soma que
amarra os três apps na mesma conta, e é ela que responde "está faltando, mas é
de algum cooperado". Divergência resolvida some da tabela, e o alvo volta ao
`qtd_sistema` sozinho: não há estado a manter dos dois lados.

**De onde sai primeiro.** Gôndola, estante, galpão — nessa ordem, porque é da
gôndola que o cliente pega e do galpão que a carga só sai por separação. Na
loja esvazia o slot mais CHEIO primeiro (a mesma regra da correção manual); no
galpão, o mais VAZIO, porque quem separa termina o palete aberto antes de
romper um fechado, e é assim que a vaga se libera de verdade. Rack que chega a
zero é esvaziado de verdade, com a pilha descendo — os ajustes de uma mesma
posição são gravados do nível mais alto para o mais baixo, senão a renumeração
faria o ajuste seguinte acertar o palete errado.

**O que ela nunca faz:**

- **Nunca inventa quantidade.** Endereçado MENOR que o contado é carga sem
  endereço, e só uma pessoa sabe em que rack ela está — o rack continua
  vermelho, e o extrato lista esses produtos à parte.
- **Nunca baixa sem contagem.** Sem confirmação em `contagem_itens` não há
  quem afirme o que existe no chão.
- **Nunca usa a contagem feita AQUI.** `inventario_cicli` fica de fora de
  propósito: ele é gravado somando os próprios endereços, e usá-lo faria a
  baixa contradizer quem acabou de contar o rack na mão. Quem conta pelo app
  das gôndolas está dizendo que o endereço está certo e o sistema é que está
  atrasado; a baixa existe para o caso contrário.
- **Nunca mexe num produto tocado depois da contagem.** Se QUALQUER endereço
  do produto é mais novo que a contagem, alguém lançou ou corrigiu carga desde
  então e a contagem já não descreve o mundo — o produto fica de fora inteiro.
  É essa regra que também torna a baixa idempotente: o endereço que ela grava
  nasce mais novo que a contagem, então a mesma contagem nunca é aplicada duas
  vezes. **Uma contagem, uma baixa.**

**Auditável, nunca mágica.** Cada linha gravada vai para `contagens_log` com
`origem = 'gondolas_app_baixa_contagem'` — é por ela que se acha depois tudo o
que o automático mexeu, e é por ela que se desfaz à mão o que não devia ter
saído. A faixa do mapa abre o extrato produto a produto, com o
de-onde-para-onde de cada endereço.

O interruptor está em ⚙️ → **Baixar a venda pela contagem**, ligado por padrão.
Desligado, o app volta a se comportar como antes: o azul fica no mapa até
alguém corrigir. Na primeira vez que ela roda, a limpeza pode ser grande — são
todas as vendas acumuladas desde a última contagem de cada produto, e todas
elas aparecem no extrato.

**Uma passada a cada 30 minutos, no máximo.** A abertura do app e a abertura
do galpão pedem a baixa cada uma por si, e o galpão é reaberto dezenas de
vezes num turno. Como a baixa é idempotente por contagem, repetir a passada um
minuto depois nunca acha nada de novo: dentro da janela a chamada devolve o
resumo da passada anterior, sem tocar no banco. A hora da última passada fica
guardada no aparelho, por banco — só em memória, cada vez que o Android
matava o app a janela zerava. Religar o interruptor em ⚙️ zera a janela,
porque pedido explícito não espera.

**Duas fases: olhar nas cópias, gravar com o banco fresco.** A passada
primeiro planeja com as cópias de leitura do app (quantidades, saldo, mapa e
contagens, cada uma relida só se a janela dela venceu). Quase sempre não sai
nada aplicável e a passada termina ali, sem varrer tabela nenhuma. Só quando
algum produto teria baixa a passada relê fresco o `estoque_localizado`, o
saldo e o mapa e **replaneja do zero** — o que grava nunca sai de cópia. As
divergências do ciclo vêm sempre frescas, e uma falha de rede nelas aborta a
passada (antes virava "sem divergência" e o alvo saía errado).

**O barracão conta, mas não é baixado.** Os paletes do barracão entram na
soma do produto, mas a baixa nunca tira deles: ela gravava só o espelho em
`estoque_localizado`, o palete em `barracao_enderecos` ficava com a
quantidade antiga e a próxima gravação desfazia a baixa. O que só sairia do
barracão fica como "não coberto" no extrato, para alguém resolver à mão.
Depois de gravar no galpão, a passada relê as pilhas do galpão, para o rack
esvaziado não ficar na tela.

A regra vive em `lib/baixa_por_contagem.dart` (função pura, sem banco e sem
tela); o SQL e a ordem das gravações, em `lib/baixa_por_contagem_service.dart`.

### O galpão travando ao abrir

Com a baixa automática no ar, o app passou a mostrar "Gôndola CAMDA não está
respondendo" ao abrir o galpão. A culpa não era da baixa em si, e sim de uma
função que ela passou a chamar num tamanho novo: `gruposDeCodigos`
(`lib/codigos_vinculados.dart`), que acha os códigos irmãos de cada produto,
comparava CADA código com CADA nome do catálogo e recalculava a chave do nome
a cada par. A leitura de saldo do galpão já a chamava, mas só com os ~300
códigos que têm rack; a baixa a chama com TODOS os códigos de
`estoque_localizado`.

Medido com o catálogo real de 5000 nomes: 300 códigos custavam 7,4 s de CPU
travada na thread da interface, 2000 códigos custavam 42 s. Daí o ANR do
Android, que dispara com 5 s sem resposta.

Agora o casamento por nome passa por um índice `chave do nome → códigos`,
montado numa varredura só: os mesmos 3000 × 5000 saem em dezenas de
milissegundos. Um teste em `test/codigos_vinculados_test.dart` roda esse
tamanho com um limite de 3 s, para o laço dentro do laço não voltar sem
ninguém ver. A baixa do galpão também espera o primeiro frame antes de
começar, para não disputar a thread com o primeiro paint da cena 3D.

## Gravação com internet ruim

Na rede da loja o galpão ficava em "Gravando no banco online…" por muito
tempo, e às vezes o rack nem entrava. Medido no código, não no palpite:

- **Um lançamento eram ~17 idas e voltas ao Turso, uma atrás da outra.** A
  gravação era uma transação interativa (BEGIN, cada SELECT/INSERT/UPDATE uma
  ida, COMMIT), e o `libsql_dart` ainda faz um `describe` antes de toda
  consulta — cada SELECT custava duas idas. Com 1 s de latência, ~17 s; e a
  transação aberta no servidor no meio disso expirava, que era o "às vezes
  nem lança".
- **O segundo toque era jogado fora.** Enquanto um rack ia ao banco, um novo
  lançamento era ignorado em silêncio.
- **Nada tinha prazo.** O HTTP do libsql não tem timeout, e todas as
  consultas de uma conexão passam por um stream só, atrás de um mutex: uma
  requisição pendurada segurava tudo. Uma requisição cortada no meio ainda
  podia deixar o stream com um "baton" vencido, e daí em diante TODA
  requisição daquela conexão falhava até reabrir o app.
- **O seed da planta do galpão eram ~130 idas** numa transação, a cada
  sessão, com a trava de escrita do banco presa — o lançamento esperava atrás.

O que mudou:

- **Uma gravação = uma requisição** (`lib/gravacao_lote.dart`). Lançar,
  corrigir e esvaziar rack, atribuir e esvaziar palete do barracão e gravar
  quantidade de gôndola/estante viram um texto SQL só, mandado num pipeline
  Hrana único (`batch`) entre `BEGIN IMMEDIATE` e `COMMIT`. O servidor roda
  tudo em milissegundos; se um passo falha, o resto (inclusive o COMMIT) é
  pulado e nada é gravado.
- **Reenviar nunca grava duas vezes.** Todo comando do lote é condicionado a
  `NOT EXISTS` do UUID em `app_mutacoes_aplicadas`, e o carimbo é o último
  passo. Resposta perdida (o servidor gravou, o celular não ouviu) → o mesmo
  lote, reenviado, não faz nada.
- **Conflito tem nome.** Pilha que encheu em outro aparelho ou rack que já
  saiu abortam o lote com `GONDOLAS_CONFLITO:<motivo>` (via `json_extract`,
  porque fora de trigger o SQLite não tem RAISE). É o que separa "não adianta
  reenviar" de "a rede caiu".
- **O rack é achado pelo UUID, não pelo nível.** O UUID do rack nasce no
  celular no momento do lançamento; um ajuste feito logo depois, ainda sem
  rede, acha o rack certo mesmo que a pilha tenha mudado.
- **Fila de gravação** (`lib/fila_gravacao.dart`). O toque aplica na tela e
  entra na fila, guardada no aparelho antes de qualquer ida à rede — sobrevive
  a fechar o app. Ela manda uma por vez, na ordem, e reenvia sozinha (1, 2,
  4… até 20 s entre tentativas). A barra de baixo diz se está indo (rodinha)
  ou se a rede não deixou mas está guardado (nuvem riscada, botão `Tentar
  já`); tocar nela lista o que falta e tem `Descartar todas` para emergência.
  Só o que o banco recusa de verdade volta atrás na tela, com aviso dizendo o
  quê e por quê. A fila recomeça sozinha ao abrir o app e ao voltar para ele.
- **A tela é o banco + a fila por cima** (`aplicarPendentesGalpao`,
  `aplicarPendentesBarracao`): recarregar do banco a qualquer momento não faz
  sumir o que ainda não subiu. O saldo é relido uma vez, quando a fila
  esvazia — antes cada lançamento baixava de novo o `estoque_mestre` inteiro.
- **Conexão de escrita própria, descartada a cada falha**, com prazo de 25 s.
  A de leitura também ganhou prazo e se renova sozinha depois de uma falha.
- **Abertura enxuta.** As ~20 criações de tabela/índice viraram uma
  requisição; as migrações só conferem `app_migrations` até darem certo uma
  vez por banco (a marca fica no aparelho); o seed da planta é um upsert só e
  só sai quando a planta do código muda. De ~35 idas na abertura para 1–3.

Verificado em SQLite real por `tool/verify_gravacao_sql.py` (lotes, conflito,
reenvio, pilha que desce, estocado fora do espelho, esquema da abertura) e
nos testes de `test/fila_gravacao_test.dart` e `test/gravacao_lote_test.dart`.
O teste que falta é o do celular na rede da loja.

Ainda no caminho antigo (várias idas por gravação): layouts de gôndola e
estante, cadastro de paletes, exclusão de endereço de gôndola e conclusão de
contagem.

### Layout salvo por cima de outro aparelho

"Salvar layout" apaga a estrutura inteira e regrava o que está na tela. Dois
jeitos de perder dado com isso, os dois corrigidos:

- **Outro aparelho salvou no meio da edição.** O último a salvar apagava a
  edição do outro sem aviso. Agora o salvamento confere, dentro da própria
  transação (`BEGIN IMMEDIATE`), se o layout no banco ainda é o que a tela
  carregou — as caixas e os lugares delas, sem nome nem cor. Se mudou, nada é
  gravado e aparece "Esta gôndola foi alterada em outro aparelho enquanto você
  editava", com **Recarregar** (mostra como ela está e descarta a edição) e
  **Salvar por cima** (grava assim mesmo). Se o banco já tem exatamente o que
  vai ser gravado — a tentativa anterior chegou e só a resposta se perdeu —
  não é conflito. Os endereços zerados que o salvamento limpa saem do layout
  lido nessa mesma transação e da base da tela, não da cópia do aparelho.
- **A gôndola abria vazia quando a leitura falhava** (sem rede e sem cópia,
  como numa instalação nova) e continuava editável: um "Salvar layout" ali
  apagava a de verdade. Agora ela mostra "Não foi possível carregar o layout"
  e a edição fica bloqueada até carregar.

## Leitura no Turso (rows read)

O Turso cobra por linha **varrida**, não por linha devolvida: um `SELECT` sem
filtro indexado conta a tabela inteira, mude ela ou não. Catalogar no galpão
estava custando umas 15 mil linhas por palete, quase tudo relendo o que não
tinha mudado:

- **Escolher um produto novo** no painel recalculava o saldo lendo o
  `estoque_mestre`, as duas tabelas do mapa e o `estoque_localizado` inteiros
  — para mostrar o número de um produto só.
- **Cada gravação expirava** a cópia do `estoque_localizado`, e a conferência
  do fim da fila relia o saldo completo de novo.
- **Cada volta ao app** (a tela bloqueia a cada palete) relia as ~30 consultas
  guardadas, e cada uma que mudou recarregava o galpão por conta própria.
- **O `estoque_mestre` era lido quatro vezes** ao abrir o app e o galpão:
  catálogo, diálogo de quantidade, saldo do galpão e baixa.

O que mudou:

- **Janela por consulta** (`ConsultaCache`). A cópia só volta ao banco depois
  da sua idade: 30 s para as pequenas (galpão, barracão, layouts), 5 min para
  as de tabela grande (`estoque_localizado`, buscas, `materiais_terceiros`) e
  30 min para o cadastro (`estoque_mestre`, mapa de produtos), que só muda
  quando a planilha do ERP sobe ou pelo dashboard. O que ESTE aparelho grava
  corrige a cópia na hora; a janela só limita quanto demora para aparecer o
  que outro aparelho mudou. O **Sincronizar continua relendo tudo**.
- **Uma leitura do `estoque_mestre` para o app inteiro** (`consultarSaldos`):
  o catálogo sai dela (com o teto de 5000 de sempre), e o saldo do galpão, o
  diálogo de quantidade e a baixa usam a mesma cópia. A baixa pede leitura
  fresca, porque grava com base nela, e deixa o resultado para os outros.
- **Saldo do galpão sem consulta própria** (`GalpaoService.carregarSaldos`):
  os códigos com rack saem das pilhas da tela, o sistema e o mapa das cópias
  de cadastro, e o endereçado é somado em Dart da cópia do
  `estoque_localizado`. Escolher um produto para lançar não vai ao banco.
- **Depois de gravar, só o local gravado** (`marcarLocalGravado`): a fila
  anota a posição do galpão (ou o palete do barracão), e a próxima leitura de
  quantidades relê só essas linhas, pelo `idx_estoque_localizado_local`, numa
  ida para todas as posições anotadas.
- **Volta ao app**: no máximo uma releitura a cada 5 min, e só das consultas
  cuja janela venceu. A fila de gravação continua tentando na hora.
- **Avisos em rajada viram uma recarga**: o galpão espera 800 ms de silêncio
  no `dataRevision` antes de recarregar.

Estimativa por palete catalogado: de ~15 mil linhas para algumas centenas (a
releitura das pilhas do galpão, que é pequena). A conta é da **conta inteira**
do Turso: os dashboards Streamlit e os apps irmãos leem do mesmo plano, e a
divisão por banco fica em Databases → (banco) → Usage.

Verificado em `test/leitura_turso_test.dart` (janela, volta ao app, tabela só
de leitura, troca por local, somas do saldo) e `test/galpao_service_test.dart`
(saldo sem banco nem cópia).

### Segunda rodada: loja, conferência, baixa e abertura

Com o galpão resolvido, o grosso da leitura passou para a loja. O plano
inteiro, com as estimativas, está em `docs/plano-rows-read-fase2.md`.

- **Selos das prateleiras sem consulta própria.** O âmbar (endereço gravado
  antes da última contagem) e o vermelho/azul-escuro (divergência do ciclo) eram
  duas consultas com JOIN sobre `estoque_localizado`, `inventario_cicli`,
  `contagem_itens` e `estoque_mestre`, refeitas com `forceRefresh` a cada
  aviso de dados — e cada linha salva no diálogo era um aviso. Agora saem em
  Dart (`lib/badges_estoque.dart`) da cópia das quantidades e de três cópias
  pequenas: última contagem do ciclo por produto, última contagem confirmada
  por produto e produtos em divergência (janela de 10 e 5 min, sem avisar as
  telas quando mudam). A regra é a mesma do SQL, inclusive as esquisitices
  dele (código comparado como texto, maior data por ordem de texto);
  `tool/verify_badges_sql.py` roda o SQL antigo em SQLite real e compara.
  Concluir contagem relê do banco só as linhas do produto nessas cópias.
- **Gôndola e estante esperam a rajada passar.** O layout recarrega na hora;
  selos e catálogo esperam 800 ms de silêncio. O barracão também.
- **Conferência guardada por 1 minuto** (`ModoConferenciaService`). Cada
  volta de estrutura e cada aviso varriam `contagem_itens`; agora pedidos
  dentro de 1 minuto dividem a mesma leitura. Ligar o modo, o botão de
  atualizar da faixa, a volta ao app e o Sincronizar (de qualquer tela)
  leem na hora.
- **Abertura e volta ao app.** A janela de cada cópia sobrevive ao app ser
  fechado (antes toda abertura relia ~11 mil linhas). A volta ao app relê só
  as cópias vencidas **que alguém usou nesta sessão** — os ~35 layouts que só
  a pré-carga leu ficam de fora, e a tela que ficou aberta com o celular
  bloqueado entra. A pré-carga roda uma vez por sessão. "Ver no mapa" não
  repete a baixa (ela só roda na loja raiz). Consulta de tabela ou coluna que
  não existe no banco sai da lista, para não derrubar o Sincronizar.
- **Avisos de verdade.** O "mudou?" não depende mais da ordem das linhas, e
  as cópias que mudam na mesma volta viram um aviso só (300 ms). Antes, depois
  de qualquer correção parcial a releitura sempre acusava mudança, e cada
  cópia avisava separado.
- **Gravar não joga leitura fora.** Concluir contagem, salvar layout,
  paletes, seed do barracão e a fila do galpão não expiram mais a cópia
  inteira do `estoque_localizado` (cada uma corrige o que gravou), e uma
  gravação só descarta as leituras em andamento da cópia que ela corrige.
  Depois da fila, o galpão relê só as posições gravadas.
- **Buscas do galpão e do barracão** saem das cópias das pilhas e dos
  paletes, que já são relidas a cada gravação, em vez de consultas próprias.
- **Catálogo**: não fura mais a janela do `estoque_mestre` (regressão da
  primeira rodada).
- **Índices nas tabelas dos outros apps**, criados uma vez por banco e
  aparelho, em segundo plano, só quando nenhum índice da tabela já começa pela
  mesma coluna (a chave primária conta). Tabela ou coluna que não existe é
  pulada.

| Índice | Tabela (colunas) | Para quê |
|---|---|---|
| `idx_gondolas_contagem_itens_status` | `contagem_itens(status)` | pendentes da conferência |
| `idx_gondolas_estoque_mestre_status_ciclo` | `estoque_mestre(status_ciclo)` | produtos em divergência |
| `idx_gondolas_estoque_mestre_codigo` | `estoque_mestre(codigo)` | concluir contagem |
| `idx_gondolas_inventario_cicli_produto` | `inventario_cicli(produto_id, data_contagem)` | concluir contagem |

Um comportamento antigo foi mantido como estava: depois de "Concluir
contagem", todos os endereços do produto ficam âmbar até serem regravados.

Verificado em `test/leitura_turso_test.dart` (janela em disco, sucesso ×
tentativa, uso, avisos, geração por chave, ordem da correção parcial),
`test/badges_estoque_test.dart`, `test/conferencia_guardada_test.dart`,
`test/baixa_por_contagem_test.dart` (barracão) e `tool/verify_badges_sql.py`.

### Terceira rodada: layouts, volta ao app e a chave de cache

O que sobrava de maior nas tabelas de layout (estimativa, sem medição) era a
volta ao app — relia a busca inteira e cada gôndola ou estante aberta na
sessão, mesmo sem ninguém olhando — e a abertura e o Sincronizar, que liam as
mesmas tabelas duas vezes (uma cópia por estrutura, ~35, mais as duas da
busca).

- **Uma cópia por tabela de layout** (`lib/layouts_copia.dart`). A cópia
  completa de `gondola_layout` e a de `estante_layout` servem a busca do mapa,
  a pré-carga e a cena de cada estrutura. Abrir uma gôndola relê só ela, pelo
  índice do número, e corrige a cópia no lugar (o mesmo que o galpão faz com as
  posições gravadas). A abertura do app lê 2 consultas em vez de ~37, e o
  Sincronizar não relê nada em dobro. A busca continua com os mesmos
  resultados, paletes desativados incluídos.
- **A volta ao app relê só o que está na tela.** Layouts, buscas e as cópias de
  contagem saíram da releitura da volta; a gôndola ou estante à vista relê a
  própria estrutura e os selos quando o app volta. O Sincronizar continua
  relendo tudo.
- **Tela escondida fica parada.** Uma gôndola com "Ver no mapa" (ou ⚙️, ou o
  modelo 3D) por cima não relê mais nada a cada aviso de dados; ela se
  recarrega da cópia ao voltar. A navegação ficou como era.
- **Sem a chave "Cache de consulta" em ⚙️.** Ela vinha da época da réplica
  local. Desligada, cada toque relia tabelas inteiras (estimativa: 1,5 a 2
  milhões de linhas por dia num aparelho movimentado) e, sem rede, as telas
  abriam vazias. Agora todo aparelho reaproveita as leituras recentes; "Atualizar
  dados" e o Sincronizar continuam relendo tudo na hora. Na primeira abertura
  depois da atualização, o app apaga a preferência e as cópias antigas de
  layout — antes juntando as cópias por estrutura na cópia nova, para o
  primeiro uso sem sinal ainda abrir as gôndolas.

Duas correções de layout que não são de leitura vieram junto (ver "Gravação
com internet ruim").

Ficou para depois de medir no campo: leitura incremental de `contagem_itens` e
`inventario_cicli` (o desenho do plano dava resultado errado: a linha volta para
"pendente" sem mudar `confirmado_em`, e o "Limpar lista" apaga tudo) e uma
sonda de versão (`MAX(id)`) por estrutura no lugar da releitura de 30 s.

Verificado em `test/layouts_copia_test.dart` (fatia da cópia, releitura por
estrutura, corrida com a gravação, sem rede com e sem cópia, conferência do
conflito, paridade da busca nas estantes) e `test/leitura_turso_test.dart`
(cópias fora da volta ao app). Falta o gráfico de Rows Read de um dia de loja
e galpão.

### Medindo: ⚙️ → Leituras deste aparelho

O gráfico de Rows Read do Turso é da **conta inteira**: os dashboards, o app
Contagem e todos os aparelhos somados. Para saber quanto é do Gôndolas — e se
uma mudança funcionou —, cada aparelho conta o que ele mesmo pediu ao banco,
por dia e por tipo de consulta (`lib/leituras_turso.dart`), e mostra em ⚙️ →
**Leituras deste aparelho**. Os últimos 8 dias ficam guardados no aparelho.

O cliente do libsql não informa as linhas **varridas** (o que o Turso cobra),
só as devolvidas. Três casos:

- **Tabela inteira**: as duas são a mesma coisa.
- **Pelo índice**: o Turso soma também a busca no índice (e, numa lista
  `IN (...)`, a passada pela lista). O real fica um pouco acima do mostrado.
- **Agrupa ou filtra sem índice**: a última contagem de cada produto (app
  Contagem e inventário cíclico), as divergências da baixa e os estocados com
  saldo varrem a tabela toda e devolvem menos linhas. Para eles a tela estima
  consultas × tamanho da tabela. O tamanho sai do botão **Medir as tabelas**,
  que conta as linhas só dessas quatro tabelas (`contagem_itens`,
  `inventario_cicli`, `divergencias`, `materiais_terceiros`) — e isso mesmo
  custa, uma vez, a leitura delas inteiras. Uma tabela que falhar na medição
  não descarta as outras.

**Sem resposta**: leitura que estourou o prazo depois de enviada. O banco já
executou (e o Turso cobrou); a tela estima as linhas pelo tamanho da cópia que
ela renovaria.

Para comparar com o Turso: some o "≈ linhas lidas" do dia dos aparelhos da loja
e do galpão. O número de cada aparelho é um **piso**, então o que sobrar no
gráfico é dos outros apps **mais** o que fica de fora daqui:

- as consultas da abertura (esquema, migrações) e da recuperação da réplica
  antiga, que rodam raramente;
- o que os próprios comandos de gravação leem por dentro (o DELETE de um
  layout, os `INSERT ... SELECT` e as conferências dos lotes do galpão);
- a busca no índice e as listas `IN`, como acima.

Os SELECTs feitos dentro das gravações (estado anterior, o produto relido
depois de salvar, o barracão relido) entram na conta.

O contador grava no aparelho no máximo uma vez por minuto e, com o app em
segundo plano, na hora. Ficam os últimos 8 dias de calendário.

## Créditos

Ícone do app: [Map icon criado por Freepik — Flaticon](https://www.flaticon.com/br/icones-gratis/mapa)

## Produtos estocados (material de cooperado)

Botão de caixa (📦) na barra de cima do **galpão** e do **barracão**. Abre uma busca
por cooperado, produto ou código, lendo `materiais_terceiros` — a mesma tabela do app
Estocados.

**Lançar o palete.** Os mesmos itens aparecem na busca de produto do painel do endereço
(toque numa vaga → digite cooperado ou produto → quantidade → lançar). O nome fica
`PRODUTO · COOPERADO` e a cor é violeta.

**Fora do saldo, de propósito.** Esse material já foi faturado e saiu do sistema. Por isso
o código gravado no palete leva o prefixo `EST:` e os serviços do galpão e do barracão
**não o espelham em `estoque_localizado`**: ele não entra no saldo, na baixa pela
contagem nem no Modo Conferência, mas ocupa a vaga e aparece no mapa. Nenhuma coluna nova
no banco. A regra está em `lib/estocados_busca.dart` (`prefixoEstocado`).

**Onde está.** Cada item da lista mostra `📍 Galpão 40 · N4` / `BAR-07` (ou `sem endereço`), ligando o palete ao item pelo nome `PRODUTO · COOPERADO`.

**Retirar do endereço.** No painel de um palete de estocado há o botão `Retirar do endereço` (com confirmação): a vaga fica livre, a pilha desce se houver rack em cima, e o item continua na lista do cooperado. Vale no galpão e no barracão (mesmo painel). Fica registrado em `contagens_log` como qualquer esvaziamento.

**Ocupação no cabeçalho do galpão.** Em vez de só `N vagas livres`, o cabeçalho mostra `38 livres · 30 estocados · 61 loja` (parte zerada some), para ver quanto do galpão os estocados ocupam.
