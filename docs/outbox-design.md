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

## O que já vale hoje (e o que ainda não)

Garantido:

- **A divergência é um estado do arquivo, não da sessão.** A marca vive em
  disco (`turso_recuperacao_necessaria_<banco>`) e tranca o coordenador. Nem
  reabrir o app, nem um `init()`, nem tocar Sincronizar de novo reabrem o
  portão de escrita — só a recuperação explícita (apagar a réplica divergente
  em ⚙️ → *Limpar cache local*), que é também a única coisa que remove a marca.
- **A URL do banco não muda com gravação pendente.** A checagem acontece antes
  de as credenciais novas irem para o disco; depois de gravadas, o banco
  anterior já não teria endereço por onde sincronizar.
- **Um `sync()` nativo nunca corre sozinho.** O `Future.timeout` devolve o
  controle ao chamador sem cancelar o trabalho nativo, então o sync em
  andamento fica registrado: outro sync espera por ele, e uma escrita admitida
  também.
- **Apagar a réplica apaga o contador daquele banco**, não só o contador legado
  sem namespace — senão a abertura seguinte ressuscitava pendências de
  gravações que sumiram junto com o arquivo.

Ainda em aberto — é o que a outbox acima resolve:

- Entre o `commit()` local e a persistência do contador de pendências existe
  uma janela. Ela encolheu (a persistência agora é aguardada dentro do mutex,
  não solta com `unawaited`), mas um encerramento abrupto exatamente ali ainda
  deixa uma gravação no arquivo sem estar contada.
- O contador diz *quantas*, nunca *quais*. Por isso a recuperação continua
  sendo "apagar e rebaixar", com perda anunciada, em vez de reaplicar mutação
  por mutação com ACK do servidor.
