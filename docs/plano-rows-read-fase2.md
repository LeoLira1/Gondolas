# Menos rows read: fase 2 (loja, conferência, baixa e cache)

> **Status: aplicado** (commit `Menos rows read, fase 2…`). O resumo para quem usa está no README, em
> "Leitura no Turso → Segunda rodada". Diferenças do texto abaixo:
> - Os selos casam o código só quando os dois lados são texto, e o `codigo` de `estoque_mestre` (INTEGER)
>   casa pelo valor numérico — é o que o JOIN antigo fazia de fato no SQLite, conferido por
>   `tool/verify_badges_sql.py` (o texto abaixo dizia `toString()`).
> - A releitura das posições do galpão tem teste na `ConsultaCache` (ordem da correção parcial), não no
>   `GalpaoService`.
> - Depois da revisão: a volta ao app relê as chaves usadas na sessão, sem o prazo de 2 h (a tela aberta
>   com o celular bloqueado ficava de fora); "concluir contagem" relê do banco as linhas do produto nas
>   cópias dos selos em vez de montá-las; a baixa espera a correção da cópia antes do aviso final; a
>   conferência guardada também cai com o Sincronizar de qualquer tela.
> - Falta a medição no campo (gráfico de Rows Read de um dia de loja e galpão).

## Contexto

A primeira rodada (commit `Menos rows read no Turso…`, branch `claude/laughing-cori-7rst28`) tirou o
custo do galpão. O Leo pediu para fazer as outras melhorias.

Uma auditoria somente leitura com 4 mapeadores e 4 verificadores adversariais inventariou todas as
leituras do app. Todos os achados abaixo foram confirmados no código, e as ressalvas dos verificadores
já estão incorporadas.

Decisões do Leo:
- **Índices**: o Gôndolas pode criar índices nas tabelas dos outros apps.
- **Baixa automática**: passa a rodar no máximo a cada **30 min**.

Tamanhos usados nas estimativas:

| Tabela | Linhas |
|---|---|
| estoque_mestre (M) | ~5 mil |
| estoque_localizado (L) | 3 a 6 mil |
| contagem_itens (C) | cresce sempre |
| inventario_cicli (I) | cresce sempre |

### Onde a leitura está agora, por volume

1. **Badges de gôndola e estante** (o maior da loja).
   - Desatualizados custam I + C + L. Divergentes custam M ou 2L.
   - As duas rodam com `forceRefresh` a cada `dataRevision`, sem debounce nem deduplicação.
   - Cada linha salva no diálogo dispara um aviso. Um Salvar de N linhas custa N+1 pares por tela
     montada.
   - Na loja dá de 150 a 300 pares por dia.
2. **Conferência**: varre C a cada volta de estrutura e a cada aviso. Não tem cache.
3. **Baixa**: cada passada lê C + L a 2L + M + mapa + D. Dá de 25 a 50 passadas por dia.
4. **Abertura a frio**: a janela das cópias não sobrevive ao app ser fechado. Cada abertura relê ~11 mil
   linhas. "Ver no mapa" empilha uma `LojaPage` que repete o prewarm e a baixa.
5. **Volta ao app**: relê todas as chaves registradas e vencidas, inclusive os ~35 layouts que só o
   prewarm leu.
6. **Avisos falsos e em rajada.**
   - O "mudou?" compara `jsonEncode` sensível à ordem. Depois de qualquer correção parcial (que põe as
     linhas no fim), a próxima releitura sempre acusa mudança.
   - Cada chave avisa separado. Uma volta ao app ou um Sincronizar viram k avisos, cada um uma rodada
     forçada nas telas.
7. **Gravações que expiram a cópia inteira do `estoque_localizado` sem motivo**: concluir contagem,
   salvar layout, paletes e seed do barracão.
8. **Toda gravação descarta as leituras em andamento de TODAS as chaves** (geração global). As linhas já
   foram cobradas e a cópia continua velha.
9. **Regressão do commit anterior**: `_consultarCatalogo` usa `consultarSaldos(forceRefresh: true)`, que
   fura a janela do `estoque_mestre`. Mais um detalhe do mesmo commit: `_invalidarCachesDeLeitura` apaga
   `_locaisGravados` sem expirar a cópia das quantidades (na reconexão em ⚙️).

Bugs de correção achados (não são de leitura):
- **(a) Barracão na baixa.** A baixa grava só o espelho das linhas do barracão; `barracao_enderecos`
  continua com a quantidade antiga e a próxima gravação desfaz a baixa.
- **(b) Galpão depois da baixa.** A cópia `galpao` não é relida depois que a baixa grava, e o rack
  esvaziado fica na tela.
- **(c) Divergências na baixa.** `_lerDivergencias` engole erro de rede como "sem divergência", e o alvo
  da baixa sai errado.
- **Só reportar, sem mexer:** depois de "Concluir contagem", todos os endereços do produto ficam âmbar.
  A regra é mantida fielmente.

## Mudanças

### 1. ConsultaCache (`lib/consulta_cache.dart`)

- **Último sucesso separado da última tentativa.**
  - `_sucessoEm[chave]` guarda a hora de início da leitura que deu certo.
  - `_ultimaTentativa` continua só como trava de releitura em segundo plano.
  - `vencida(chave)` (público) mede pelo sucesso.
- **Janela persistida.**
  - `_sucessoEm` vai para o disco na chave `'$chave|em'` quando a leitura completa dá certo e no
    `confirmar` de cópia inteira.
  - `ler()` restaura `_sucessoEm` e `_ultimaTentativa` ao carregar do disco.
  - `expirar()` apaga o carimbo em disco também.
- **`atualizarParte` não renova a janela** da cópia inteira, nem na memória nem no disco. Ganha um
  parâmetro `ordenar` opcional, para manter a ordem da cópia.
- **"Mudou?" sem depender da ordem.** A assinatura passa a ser a lista ordenada de `jsonEncode(linha)`.
- **Aviso por chave.** Novo parâmetro `avisar` (padrão `true`). As chaves de contagem e divergência usam
  `false`.
- **Geração por chave.**
  - `confirmar`/`atualizarParte` invalidam só a própria chave.
  - `invalidarConsultasEmAndamento([chaves])`: sem argumento invalida todas, menos as `somenteLeitura`,
    cujo `_emAndamento` também não é limpo. Com argumento, invalida só as chaves dadas.
- **Uso registrado.**
  - `ler()` anota `_ultimoUso[chave]`, a não ser que rode dentro do prewarm. O prewarm roda numa Zone
    com `#semUso`, então não marca uso.
  - `atualizar(soVencidas: true, usadasHa: 2 h)` relê só as chaves vencidas e usadas de verdade.
  - `atualizar()` sem filtro (Sincronizar) espera a passada em andamento e então relê tudo. Hoje ela volta
    na hora sem reler nada.

### 2. TursoService (`lib/turso_service.dart`)

- **Avisos agrupados.** `aoAtualizar` agenda UM `dataRevision++` com um respiro de 300 ms, em vez de um
  por chave. O `++` final do Sincronizar continua imediato.
- **`marcarGravacaoLocal({bool expirarQuantidades = true, Set<String>? chavesAfetadas})`.**
  - A fila passa `expirarQuantidades: false` e invalida só `galpao`, ou só `barracao`. Para operação do
    barracão, também expira `barracao`, porque a página pode fechar antes da recarga.
  - Upsert, exclusões, `concluirContagem`, layouts, paletes e seed do barracão passam
    `expirarQuantidades: false`.
  - `_aplicarEstadoFinal` (outbox) continua expirando.
- **`_invalidarCachesDeLeitura`.** Se ainda há `_locaisGravados`, expira a cópia das quantidades antes de
  limpar. Também zera a marca do prewarm.
- **Ao anotar um local gravado**, apaga o carimbo em disco da cópia das quantidades. Se o Android matar o
  app antes da correção, a reabertura relê a tabela inteira em vez de servir cópia velha como fresca.
- **Catálogo.** `_consultarCatalogo` usa `consultarSaldos(forceRefresh: vencida(saldos))`. Depois do
  Sincronizar ou com a cópia fresca, não lê de novo.
- **Buscas do galpão e do barracão derivadas das cópias.**
  - `busca_galpao` sai da cópia `galpao`; `busca_barracao` sai da cópia `barracao`.
  - O SQL das duas cópias vira constante pública compartilhada com GalpaoService e BarracaoService.
  - A ordenação é total em Dart: (produto_nome, posicao, ordem) e (produto_nome, rotulo), com o filtro
    de código vazio.
  - Saem as chaves e os remendos `busca_galpao`/`busca_barracao`. Isso também elimina o aviso falso por
    ordem depois de cada rajada no galpão.
- **Busca de gôndolas e estantes.** O remendo de `busca_gondolas`/`busca_estantes` em `guardarConsulta`
  passa a projetar as mesmas colunas do SQL (com DISTINCT). Fim do aviso falso depois de salvar layout.
- **`_anexarQuantidades`** só lê a cópia das quantidades se houver resultado de gôndola ou estante.
- **Prewarm uma vez por sessão e por banco**, marcado só depois de dar certo.
- **Novas cópias.**
  - `ultima_contagem_ciclico_v1`:
    `SELECT produto_id AS produto_codigo, MAX(contado_em) AS ultima FROM inventario_cicli WHERE contado_em IS NOT NULL GROUP BY produto_id`.
    Janela de 10 min, `avisar: false`. É corrigida localmente depois de `concluirContagem`.
  - `ultima_contagem_itens_<col>`: mesma forma sobre `contagem_itens`, com `status != 'pendente'`.
    É `somenteLeitura`, janela de 10 min, `avisar: false`. A coluna fica memorizada, e a troca só
    acontece em erro `no such column`.
  - `divergentes_ciclo_v1`:
    `SELECT codigo, qtd_contada_ciclo, qtd_sistema_na_contagem FROM estoque_mestre WHERE status_ciclo = 'divergencia'`.
    Janela de 5 min, `avisar: false`. É corrigida localmente depois de `concluirContagem`.
- **Índices nas tabelas dos outros apps.** Rodam uma vez por banco e aparelho, em segundo plano depois do
  `init`.
  - Cada índice só é criado se nenhum índice existente já começar pela mesma coluna. A checagem usa
    `pragma_index_list` + `pragma_index_info` (testado no SQLite: a PK aparece).
  - Tabela ou coluna ausente: pula sem erro.

| Índice | Para quê |
|---|---|
| `contagem_itens(status)` | pendentes da conferência |
| `estoque_mestre(status_ciclo)` | divergentes |
| `estoque_mestre(codigo)` | `concluirContagem` e o JOIN |
| `inventario_cicli(produto_id, data_contagem)` | `concluirContagem` |

### 3. Badges da loja

- **Funções puras novas** em `lib/badges_estoque.dart`: `calcularDesatualizados` e
  `calcularDivergentes`. Elas reproduzem a regra SQL de hoje:
  - código casado pelo texto (`toString()`), já que `produto_id` pode ser INTEGER;
  - MAX de TEXTO entre as duas fontes;
  - `DateTime.tryParse(atual).isBefore(DateTime.tryParse(ultima))`;
  - positivo quando `qtd_contada_ciclo > qtd_sistema_na_contagem`.
- **Os dois fetch calculam em Dart** a partir de `consultarQuantidades()` e das cópias novas.
  - Saem o TTL de 2 min, `_invalidarCachesBadges` e o fallback de coluna local.
  - Continua o mapa de `infoDesatualizado`.
- **Gravações.**
  - `_atualizarCopiaDoProduto` expira a cópia no catch e no `client == null`.
  - `concluirContagem` corrige as cópias de ciclo e divergentes via `atualizarParte`.
- **Parâmetro `avisar`** em `upsertQuantidade` e em `guardarQuantidadesProduto`. A baixa passa `false`.

### 4. Telas

- **`GondolaPage` e `EstantePage`** (`lib/main.dart`). Em `_aoAtualizarDados`:
  - o layout recarrega na hora;
  - badges e catálogo passam por um debounce de 800 ms, com Timer cancelado no `dispose`;
  - os badges deixam de ser forçados.
- **`BarracaoPage`**: o mesmo debounce de 800 ms.
- **`LojaPage`**:
  - `_atualizarBuscaVisivel` só refaz a busca com a rota no topo (`ModalRoute.isCurrent`).
  - Na volta ao app chama `ModoConferenciaService().esquecer()`.
  - A baixa automática só roda na raiz (`itemTipoInicial == null`).
- **Galpão.** Depois que a fila esvazia ou recusa uma gravação, relê só as posições gravadas:
  - `GalpaoService.recarregarPosicoes`, com `SELECT … WHERE posicao IN (…)` pelo UNIQUE(posicao, ordem);
  - mais `atualizarParte('galpao')`, mantendo a ordem (posicao, ordem).

### 5. Conferência (`lib/modo_conferencia_service.dart`)

- **Memo em memória dentro do serviço** (fora da ConsultaCache, para não entrar na volta ao app nem no
  Sincronizar).
  - Validade de 60 s, deduplicação de chamadas em andamento, e é por banco.
  - `buscarConferenciaDoDia({bool forcar = false})`. Pedido forçado nunca pega carona numa leitura
    iniciada antes dele.
  - `esquecer()` na volta ao app e no Sincronizar.
- **`forcar: true`** só ao ligar o modo e no botão de atualizar do banner (loja, galpão e barracão).

### 6. Baixa (`lib/baixa_por_contagem_service.dart`, `lib/baixa_por_contagem.dart`)

- **Janela de 30 min.**
- **Fase 1, das cópias.**
  - Usa quantidades, saldos, vínculos e contagens, cada uma com `forceRefresh` se estiver vencida pelo
    último sucesso.
  - As divergências vêm frescas e fecham na falha (bug c): só `no such table` vira vazio.
  - Se nenhum plano sair aplicável, a passada termina sem a fase 2. Instalação nova, sem cópia, vai
    direto para a fase 2.
- **Fase 2, só com plano aplicável.**
  - Relê fresco `_lerEnderecos` (com `rack_uuid`), `consultarSaldos(forceRefresh: true)` e
    `vinculosDoMapa(forceRefresh: true, falharFechado: true)`. Erro numa tabela que existe aborta.
  - Reaproveita as divergências e as contagens da fase 1. Contagem um pouco mais velha só deixa a baixa
    mais conservadora.
  - Replaneja do zero.
- **Avisos.** Gravações com `avisar: false`. Um `dataRevision++` no fim se houve QUALQUER gravação,
  inclusive parcial.
- **Bug (b):** se gravou no galpão, chama `GalpaoService().recarregarPilhas()` uma vez.
- **Bug (a):** em `planejarBaixa`, endereço do barracão entra na soma, mas nunca é fonte de retirada. O
  resto vira `naoCoberto`.

## Fora desta rodada (vai como nota)

- **Unificar os layouts por estrutura com `busca_gondolas`/`busca_estantes`.** Muda o comportamento com
  paletes inativos e custa mais na abertura de uma estrutura.
- **Janela maior para layouts.** O salvamento é destrutivo.
- **Navegação do "Ver no mapa"** (voltar à raiz em vez de empilhar). Precisa de validação com quem usa.
- **Leitura incremental de `contagem_itens`.** Precisaria de índice em `confirmado_em`.
- **Opção "cache desligado" em ⚙️.** É escolha do usuário.
- **Pular o SELECT "antes" do `salvarLayout` no modo remoto.** Ganho pequeno.

## Testes e verificação

- **`test/leitura_turso_test.dart`:**
  - janela persistida e `expirar` apagando o carimbo;
  - sucesso separado da tentativa (falha não deixa a cópia fresca);
  - `usadasHa` e o prewarm sem marcar uso;
  - `avisar: false`;
  - "mudou?" sem ordem;
  - geração por chave (X não descarta Y; X ainda protege X);
  - `somenteLeitura` mantida;
  - `atualizarParte` sem renovar a janela;
  - Sincronizar durante a volta ao app.
- **`test/badges_estoque_test.dart`** mais `tool/verify_badges_sql.py`: paridade da SQL antiga (SQLite
  real) com as funções Dart, cobrindo datas em formato misto, `produto_id` inteiro e divergente
  positivo.
- **`test/baixa_por_contagem_test.dart`:** barracão conta mas não é retirado, com `naoCoberto`.
- **Conferência:** memo e deduplicação com leitor injetado.
- **Galpão:** releitura por posição mantém a ordem.
- **CI local** (Flutter instalado no container): `flutter analyze`, `flutter test` e os `tool/verify_*`.
- **README:** seção "Leitura no Turso" com a fase 2, a baixa a cada 30 min e os índices criados.
- **No campo:** um dia de loja e galpão no gráfico de Rows Read (os tamanhos de tabela são estimativa).
