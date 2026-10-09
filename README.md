# Operations Archive

API e interface para armazenar resultados de execução, telemetria, inspeções e ordens de serviço. PostgreSQL no Supabase, autenticação por usuário e Vercel Functions.

## Executar

```sh
npm ci
npm test
npm run typecheck
npm run dev
```

Configure `SUPABASE_URL` e `SUPABASE_PUBLISHABLE_KEY`. A chave de serviço não é necessária. As migrações versionadas estão em `supabase/migrations` e usam o prefixo `bd_`.

## Fluxos

- `/laboratory.html`: cadastro, autenticação, importação de resultados e consulta por projeto.
- `/`: telemetria e ordens de serviço.
- `/inspections.html`: formulários de inspeção.
- `POST /api/runs`: registra resultado e eventos numa transação, com chave de idempotência.
- `GET /api/runs?project=nome`: retorna até 200 registros do usuário autenticado.
- `/api/telemetry`, `/api/operations` e `/api/inspections`: validação, persistência e controle de propriedade.

As políticas RLS isolam usuários. Resultados e eventos são imutáveis. Ordens de serviço têm transições controladas. Movimentos de estoque e lançamentos contábeis exigem revisão e atualizam seus saldos na mesma transação.

## Clientes nativos

```sh
python cloud/sync.py enqueue resultado.json --project c-household-budget
python cloud/sync.py sync
python -m unittest discover -s cloud
```

Defina `BRUNNODEV_ACCESS_TOKEN` com o token da sua sessão. `BRUNNODEV_API_URL` permite alterar o destino HTTPS. O cliente conserva relatórios numa fila SQLite até o servidor confirmar a persistência; tentativas repetidas não duplicam o registro.

Nenhum registro de demonstração é inserido automaticamente. Sensores, pagamentos e modelos de visão dependem dos respectivos dispositivos e fornecedores.
