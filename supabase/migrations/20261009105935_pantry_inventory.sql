create table public.bd_pantry_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  name text not null check (length(name) between 1 and 120),
  location text not null default 'pantry' check (length(location) between 1 and 80),
  quantity integer not null check (quantity between 0 and 1000000),
  expires_on date not null,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  unique (id, owner_id)
);
create index bd_pantry_owner_expiry on public.bd_pantry_items(owner_id, expires_on);

create table public.bd_pantry_movements (
  owner_id uuid not null default auth.uid() references auth.users(id),
  client_key text not null check (length(client_key) between 1 and 128),
  item_id uuid not null,
  delta integer not null check (delta <> 0),
  expected_revision bigint not null,
  resulting_quantity integer not null,
  resulting_revision bigint not null,
  created_at timestamptz not null default now(),
  primary key (owner_id, client_key),
  foreign key(item_id, owner_id) references public.bd_pantry_items(id, owner_id)
);
create index bd_pantry_movement_item_owner on public.bd_pantry_movements(item_id, owner_id);
alter table public.bd_pantry_items enable row level security;
alter table public.bd_pantry_movements enable row level security;
revoke all on public.bd_pantry_items, public.bd_pantry_movements from anon, authenticated;
grant select, insert, update on public.bd_pantry_items to authenticated;
grant select, insert on public.bd_pantry_movements to authenticated;
create policy bd_pantry_items_read on public.bd_pantry_items for select to authenticated using(owner_id = (select auth.uid()));
create policy bd_pantry_items_insert on public.bd_pantry_items for insert to authenticated with check(owner_id = (select auth.uid()));
create policy bd_pantry_items_update on public.bd_pantry_items for update to authenticated
  using(owner_id = (select auth.uid())) with check(owner_id = (select auth.uid()));
create policy bd_pantry_movements_read on public.bd_pantry_movements for select to authenticated using(owner_id = (select auth.uid()));
create policy bd_pantry_movements_insert on public.bd_pantry_movements for insert to authenticated with check(owner_id = (select auth.uid()));

create function public.bd_adjust_pantry(p_item uuid, p_delta integer, p_revision bigint, p_key text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  item public.bd_pantry_items;
  prior public.bd_pantry_movements;
begin
  if auth.uid() is null or p_delta is null or p_delta = 0 or abs(p_delta::bigint) > 1000000 then raise exception 'invalid stock movement'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':' || p_key, 0));
  select * into prior from public.bd_pantry_movements where owner_id = auth.uid() and client_key = p_key;
  if found then
    if prior.item_id <> p_item or prior.delta <> p_delta or prior.expected_revision <> p_revision then raise exception 'idempotency conflict'; end if;
    return jsonb_build_object('quantity', prior.resulting_quantity, 'revision', prior.resulting_revision, 'duplicate', true);
  end if;
  select * into strict item from public.bd_pantry_items where id = p_item and owner_id = auth.uid() for update;
  if item.revision <> p_revision then raise exception 'revision conflict'; end if;
  if item.quantity::bigint + p_delta < 0 or item.quantity::bigint + p_delta > 1000000 then raise exception 'stock out of range'; end if;
  update public.bd_pantry_items set quantity = item.quantity + p_delta, revision = item.revision + 1 where id = p_item;
  insert into public.bd_pantry_movements(owner_id, client_key, item_id, delta, expected_revision, resulting_quantity, resulting_revision)
    values(auth.uid(), p_key, p_item, p_delta, p_revision, item.quantity + p_delta, item.revision + 1);
  return jsonb_build_object('quantity', item.quantity + p_delta, 'revision', item.revision + 1, 'duplicate', false);
end;
$$;
revoke all on function public.bd_adjust_pantry(uuid,integer,bigint,text) from public, anon;
grant execute on function public.bd_adjust_pantry(uuid,integer,bigint,text) to authenticated;
create index if not exists bd_runs_project on public.bd_runs(project_id);
create index if not exists bd_events_run_owner on public.bd_events(run_id,owner_id);
