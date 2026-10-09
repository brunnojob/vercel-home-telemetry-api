create table public.bd_wallet_accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  name text not null check (length(name) between 1 and 80),
  currency text not null check (currency in ('BRL','USD','EUR')),
  balance_minor bigint not null default 0,
  revision bigint not null default 1,
  created_at timestamptz not null default now(),
  unique(id, owner_id)
);
create index bd_wallet_accounts_owner on public.bd_wallet_accounts(owner_id);
create table public.bd_wallet_entries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  account_id uuid not null,
  client_key text not null check(length(client_key) between 1 and 128),
  delta_minor bigint not null check(delta_minor <> 0 and delta_minor between -1000000000000 and 1000000000000),
  description text not null check(length(description) between 1 and 200),
  expected_revision bigint not null,
  resulting_balance bigint not null,
  resulting_revision bigint not null,
  created_at timestamptz not null default now(),
  unique(owner_id, client_key),
  foreign key(account_id, owner_id) references public.bd_wallet_accounts(id, owner_id)
);
create index bd_wallet_entries_account_owner_time on public.bd_wallet_entries(account_id, owner_id, created_at desc);
alter table public.bd_wallet_accounts enable row level security;
alter table public.bd_wallet_entries enable row level security;
revoke all on public.bd_wallet_accounts, public.bd_wallet_entries from anon, authenticated;
grant select, insert, update on public.bd_wallet_accounts to authenticated;
grant select, insert on public.bd_wallet_entries to authenticated;
create policy bd_wallet_accounts_read on public.bd_wallet_accounts for select to authenticated using(owner_id = (select auth.uid()));
create policy bd_wallet_accounts_insert on public.bd_wallet_accounts for insert to authenticated with check(owner_id = (select auth.uid()) and balance_minor = 0 and revision = 1);
create policy bd_wallet_accounts_update on public.bd_wallet_accounts for update to authenticated using(owner_id = (select auth.uid())) with check(owner_id = (select auth.uid()));
create policy bd_wallet_entries_read on public.bd_wallet_entries for select to authenticated using(owner_id = (select auth.uid()));
create policy bd_wallet_entries_insert on public.bd_wallet_entries for insert to authenticated with check(owner_id = (select auth.uid()));

create function public.bd_book_entry(p_account uuid,p_delta bigint,p_key text,p_description text,p_revision bigint)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare account public.bd_wallet_accounts; prior public.bd_wallet_entries;
begin
  if auth.uid() is null or p_delta is null or p_delta = 0 or p_delta not between -1000000000000 and 1000000000000 then raise exception 'invalid entry'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':' || p_key,0));
  select * into prior from public.bd_wallet_entries where owner_id=auth.uid() and client_key=p_key;
  if found then
    if prior.account_id <> p_account or prior.delta_minor <> p_delta or prior.description <> p_description or prior.expected_revision <> p_revision then raise exception 'idempotency conflict'; end if;
    return jsonb_build_object('balanceMinor',prior.resulting_balance,'revision',prior.resulting_revision,'duplicate',true);
  end if;
  select * into strict account from public.bd_wallet_accounts where id=p_account and owner_id=auth.uid() for update;
  if account.revision <> p_revision then raise exception 'revision conflict'; end if;
  if account.balance_minor + p_delta not between -9000000000000 and 9000000000000 then raise exception 'balance out of range'; end if;
  update public.bd_wallet_accounts set balance_minor=account.balance_minor+p_delta,revision=account.revision+1 where id=p_account;
  insert into public.bd_wallet_entries(owner_id,account_id,client_key,delta_minor,description,expected_revision,resulting_balance,resulting_revision)
    values(auth.uid(),p_account,p_key,p_delta,p_description,p_revision,account.balance_minor+p_delta,account.revision+1);
  return jsonb_build_object('balanceMinor',account.balance_minor+p_delta,'revision',account.revision+1,'duplicate',false);
end;
$$;
revoke all on function public.bd_book_entry(uuid,bigint,text,text,bigint) from public,anon;
grant execute on function public.bd_book_entry(uuid,bigint,text,text,bigint) to authenticated;
