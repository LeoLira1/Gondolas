# Proteção de gravações e recuperação

## Contrato

Gravações em réplica local exigem intenção persistida na outbox antes do
commit. Falhar ao abrir ou escrever a outbox cancela a transação; consultas
continuam disponíveis. Escritas remotas são transacionadas no servidor e não
exigem um arquivo local (inclusive Web).

A outbox fica separada da réplica, particionada por banco. Falhas de leitura
propagam erro: não significam zero pendências. A tela lista todos os registros
não confirmados, distinguindo envio pendente, conflito e conferência.

Cada alteração recebe um UUID, inserido em `app_mutacoes_aplicadas` na mesma
transação do efeito. Apenas a consulta ao servidor confirma seu recebimento.
Igualdade de quantidade não prova envio nem a existência do histórico.

## Recuperação explícita

1. Verifica conexão ao servidor, leitura da outbox e cobertura das gravações.
2. Intenções sem carimbo na réplica são reservadas para conferência. Podem ser
   intenções gravadas antes de uma queda que impediu o commit.
3. Reserva a recuperação no coordenador e espera escritas e sync nativo.
4. Repete a verificação, fecha a réplica e copia o arquivo e seus sidecars
   para uma subpasta `recuperacao_<instante>` no diretório privado do app.
5. Só depois apaga a réplica original e reconecta para baixar a base.
6. Reavalia registros elegíveis sob o mesmo mutex das gravações. A comparação
   é repetida dentro da transação; efeito, auditoria e UUID são commitados juntos.

Falha de proteção ou fechamento impede a exclusão. Falha posterior não apaga
outbox nem backup. Não há limpeza automática desses backups nesta mudança.
O contador legado é um sinal adicional, não substitui os UUIDs; gravações
antigas sem cobertura comprovada podem exigir intervenção manual.

## Identidade do rack

`rack_uuid` é uma coluna aditiva, com índice único e proteção contra alteração.
Racks existentes recebem `legacy-<id>` (estável entre réplicas que compartilham
a mesma linha); racks criados pelo app recebem UUID v4. Inserções no formato
antigo, sem a coluna, recebem identidade aleatória por trigger.

`posicao`, `ordem`, a restrição UNIQUE entre elas e o espelho em
`estoque_localizado` permanecem. A migração é transacionada. As telas e a baixa
por contagem levam o identificador observado até a gravação; se a posição
agora contiver outro rack, o salvamento é recusado. Renumerar ou ajustar uma
pilha preserva os identificadores dos racks restantes.

Isto é identidade do registro do rack ocupado. Excluir e cadastrar novamente
cria outro registro e outro identificador; não é cadastro patrimonial do
suporte metálico físico.

## Reaplicação e auditoria

Novos upserts e exclusões de endereços guardam também o conteúdo original de
`contagens_log` na outbox. Ao reaplicar, saldo, histórico e carimbo são gravados
na mesma transação. A checagem do UUID evita reaplicar um commit já presente.
Registros antigos sem esse histórico não têm auditoria inventada: vão para
conferência. Conflitos e conferências persistem entre tentativas, e bloqueiam
reaplicações posteriores do mesmo alvo na mesma passada.

Operações de galpão continuam em conferência, inclusive com UUID, porque além
do rack mudam espelho, histórico e, em exclusões, a ordem da pilha. O motor
genérico ainda não reaplica esse conjunto. O mesmo cuidado vale para layouts,
operações do barracão e conclusão de contagem com efeitos em outras tabelas.

## Validação e limites

- `tool/verify_recovery.dart`: identidade nas operações de pilha, auditoria,
  conflitos e serialização de recuperação, usando Dart puro.
- `tool/verify_rack_sql.py`: migração, inserções legadas, identidade imutável,
  unicidade, renumeração e ocupante substituído em SQLite real temporário.
- Testes Flutter: erro em store fechada, falha e retry da lista de pendências,
  estados visuais e testes existentes. Exigem execução no ambiente Flutter.
- `.github/workflows/validate.yml`: valida PRs sem publicar APK ou release.

A execução de Flutter e de libsql nativo de ponta a ponta permanece obrigatória
antes de distribuir APK. Os testes de SQLite não simulam o protocolo de
replicação do Turso nem comprovam compatibilidade de todos os apps irmãos.
Nenhum banco real foi migrado durante a implementação.
