# Cache de consulta e gravação online

A abertura das cenas lê respostas persistidas por banco antes de esperar a rede. O retorno ao app dispara atualização em segundo plano. A preferência de cache controla a leitura da cópia; toda gravação nova usa LibsqlClient.remote.

O cache guarda somente resultados lidos do servidor ou dados de transações confirmadas. Falhas de rede preservam a última cópia. A geração do cache impede que consultas iniciadas antes de um commit substituam o estado confirmado. Falhas ao persistir o cache não transformam um commit online em falha de gravação.

Gravações do galpão e do barracão entram numa fila persistida no aparelho (FilaGravacao) e vão ao servidor como um lote único por operação (gravacao_lote.dart): o UUID é carimbado na mesma transação dos racks, espelho e auditoria, e cada comando do lote só age se o carimbo ainda não existe — reenviar é seguro. Ajuste e remoção acham o rack pelo UUID. A tela mostra o banco com a fila aplicada por cima, e só uma recusa do servidor (conflito) desfaz o que estava na tela. Layouts substituem o estado da estrutura em uma transação.

A primeira leitura após a atualização precisa preencher o novo cache com internet. Arquivos de réplica e outbox antigos não são apagados na migração. As pendências antigas permanecem na revisão; recuperação explícita confere o arquivo antigo por uma conexão local separada, sem enviar frames. Operações complexas antigas ainda exigem revisão manual.

Validação: consulta_cache_test.dart testa rede lenta, retomada, falhas, isolamento entre bancos, proteção contra resposta anterior ao commit e persistência do identificador de tentativa. A suíte Flutter e o build Android rodam no GitHub Actions. Teste final no celular e na rede da loja continua necessário.
