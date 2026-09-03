# Outbox durável de mutações

## O que existe hoje

A outbox está implementada. Toda gravação deste app é registrada antes do
commit local, com o estado de onde ela partiu e o estado a que ela pretendia
chegar. Depois de uma reconstrução da réplica, cada registro não confirmado é
reavaliado um a um.

**A prioridade é a integridade, não a automação.** Quando a reaplicação
automática não é comprovadamente segura, o registro vai para conferência
humana. Pedir conferência explícita é melhor do que reconstruir silenciosamente
um estoque incorreto.

### Onde cada peça mora

| Peça | Arquivo |
|---|---|
| Regras puras (modelo, canônico, decisão) | `lib/outbox.dart` |
| Persistência, em arquivo SQLite próprio | `lib/outbox_store.dart` |
| Registro, carimbo, confirmação, reaplicação | `lib/turso_service.dart` |
| Tela de conferência | `lib/revisao_mutacoes_page.dart` |

A outbox fica em `camda_gondolas_outbox_<banco>.db`, **separada da réplica**.
É o ponto inteiro do desenho: a recuperação APAGA o arquivo da réplica, e a
lista do que precisa ser reaplicado não pode morrer junto com aquilo que ela
serve para reconstruir.

### O ciclo de uma mutação

1. **Antes do commit**, o estado anterior e o final desejado são gravados na
   outbox, com um UUID v4.
2. **Na mesma transação local** da alteração, o UUID entra em
   `app_mutacoes_aplicadas`. Assim o reconhecimento viaja nos mesmos frames que
   a mutação: ou os dois chegam ao servidor, ou nenhum.
3. **Depois do sync**, o UUID é procurado numa consulta **ao remoto**. Só isso
   confirma. Consultar a réplica devolveria o UUID que este aparelho acabou de
   gravar nela — ela responde "sim" para tudo, tendo o push saído ou não.
4. **Depois de reconstruir**, o que não foi confirmado é reavaliado.

Um rollback marca o registro como `abortada`. **Nada é apagado da outbox, em
nenhum caminho.**

### O protocolo de reaplicação

Para cada mutação não confirmada, na ordem em que aconteceram:

| Situação | Desfecho |
|---|---|
| Operação de endereço instável (ver abaixo) | conferência manual |
| Remoto == estado final | já aplicada |
| Remoto == estado anterior | aplica o final |
| Remoto != os dois | conflito, para conferência |

A comparação usa só as colunas que os dois estados declaram. `atualizado_em`
fica de fora de propósito: ele muda a cada gravação e faria toda comparação
terminar em conflito. E `90` e `90.0` são a mesma quantidade de baldes — o
SQLite devolve um ou outro conforme o caminho.

### O que NÃO é reaplicado sozinho

`galpao.lancar`, `galpao.esvaziar` e `galpao.ajustarQuantidade` endereçam o rack
por `(posição, ordem)`, e `ordem` é a altura na pilha: esvaziar um rack do meio
renumera os de cima. Depois de uma renumeração, `(posição, ordem)` aponta para
OUTRO rack — reaplicar acertaria a linha errada com um número que parece certo.
`ajustarQuantidade` entra na lista mesmo gravando um valor absoluto: **o valor é
absoluto, o endereço não é.**

`layout.salvarGondola` e `layout.salvarEstante` entram por outro motivo: elas
substituem o layout INTEIRO de uma unidade (DELETE + INSERT), e a reaplicação
deste primeiro desenho aplica linha a linha.

`barracao.atribuir`, `barracao.esvaziar` e `estoqueLocalizado.concluirContagem`
entram por um terceiro: o efeito delas não cabe numa linha. As duas do barracão
também reescrevem o espelho em `estoque_localizado`; a contagem também mexe no
ciclo em `estoque_mestre`. Reaplicá-las com o motor genérico deixaria o endereço
certo e o saldo velho — e, com o UUID confirmado, o desencontro ficaria
invisível. Enquanto a reaplicação não souber refazer o efeito inteiro numa
transação, elas vão para conferência.

Todas ficam gravadas com o estado de antes e o pretendido, e aparecem em ⚙️ →
*gravações para conferir* com produto, posição, ordem original, quantidade
anterior, resultado pretendido, horário e dispositivo. A tela não oferece
descartar nem aplicar: as duas seriam a promessa errada.

## Evolução futura: `rack_uuid` estável

O que trava a automação do galpão é o endereço, não o protocolo. Dar a cada
rack um identificador próprio — `rack_uuid`, gerado no lançamento e imune à
renumeração — faz as três operações passarem a ter chave estável, e com isso
elas entram no mesmo caminho automático das demais.

Isso pede, em conjunto:

1. `rack_uuid` em `galpao_racks`, com backfill dos racks existentes;
2. uma revisão do modelo da pilha, para que `ordem` volte a ser só a
   apresentação (a altura visual) e não a identidade;
3. a chave da outbox passando de `(posição, ordem)` para `rack_uuid`;
4. os apps irmãos que leem `galpao_racks` acompanhando a coluna nova.

Enquanto isso não existe, conferência manual é o desfecho ruim mas honesto.

## Limites que permanecem

Entre gravar a intenção na outbox e o commit local existe uma janela. Um
encerramento abrupto exatamente ali deixa um registro de algo que talvez não
tenha acontecido — e a escolha aqui é deliberada: o registro sobra e o UUID
não é encontrado no remoto, então a mutação vai para conferência. Sobrar um
item para conferir é recuperável; faltar um não é.

Duas coisas ainda não são cobertas por teste automatizado: o SQL de ida e volta
do `OutboxStore` (precisa da lib nativa do libsql) e a reaplicação de ponta a
ponta. A lógica que decide o DESTINO de cada mutação está toda em
`lib/outbox.dart`, que é pura e testada.

E a reaplicação automática não reescreve `contagens_log`: uma linha reaplicada
volta ao valor certo, mas sem a linha de auditoria correspondente. O saldo fica
correto; o histórico daquela gravação, não.
