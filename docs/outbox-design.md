# Próxima etapa: outbox durável de mutações

A correção atual é **fail-closed e não destrutiva**: uma réplica com alterações
não confirmadas jamais é reconstruída automaticamente. Isso elimina a perda,
mas não resolve automaticamente uma divergência já instalada.

A recuperação automática futura deve usar uma outbox SQLite separada do arquivo
da réplica, particionada pela identidade normalizada da URL. Cada registro terá
UUID, operação, payload canônico, banco de destino, criação, tentativas e estado.
A mesma transação de negócio deverá registrar a intenção antes do commit local;
no remoto, uma tabela `app_mutacoes_aplicadas(uuid primary key, aplicada_em)`
fornecerá reconhecimento inequívoco e idempotência. A reconstrução deverá:

1. copiar a réplica e seus sidecars para backup;
2. manter a outbox externa intacta;
3. obter e validar a nova base;
4. reaplicar, transacionalmente, somente UUIDs sem reconhecimento remoto;
5. sincronizar e consultar `app_mutacoes_aplicadas` no servidor;
6. marcar como confirmadas apenas as mutações reconhecidas.

Até esse protocolo existir, frame, ausência de exceção e carimbos agregados não
autorizam apagar uma réplica com pendências.
