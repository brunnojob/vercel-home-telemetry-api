create or replace function public.bd_adjust_pantry(p_item uuid, p_delta integer, p_revision bigint, p_key text)
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
  insert into public.bd_pantry_movements(owner_id, client_key, item_id, delta, expected_revision, resulting_quantity, resulting_revision)
    values(auth.uid(), p_key, p_item, p_delta, p_revision, item.quantity + p_delta, item.revision + 1);
  return jsonb_build_object('quantity', item.quantity + p_delta, 'revision', item.revision + 1, 'duplicate', false);
end;
$$;

create or replace function public.bd_book_entry(p_account uuid,p_delta bigint,p_key text,p_description text,p_revision bigint)
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
  insert into public.bd_wallet_entries(owner_id,account_id,client_key,delta_minor,description,expected_revision,resulting_balance,resulting_revision)
    values(auth.uid(),p_account,p_key,p_delta,p_description,p_revision,account.balance_minor+p_delta,account.revision+1);
  return jsonb_build_object('balanceMinor',account.balance_minor+p_delta,'revision',account.revision+1,'duplicate',false);
end;
$$;

create function public.bd_guard_stock() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if new.id <> old.id or new.owner_id <> old.owner_id or new.created_at <> old.created_at then raise exception 'immutable identity'; end if;
  if (new.quantity <> old.quantity or new.revision <> old.revision) and pg_trigger_depth() < 2 then raise exception 'stock movement required'; end if;
  return new;
end;
$$;
create trigger bd_stock_guard before update on public.bd_pantry_items for each row execute function public.bd_guard_stock();
create function public.bd_apply_stock() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare item public.bd_pantry_items;
begin
  select * into strict item from public.bd_pantry_items where id=new.item_id and owner_id=auth.uid() for update;
  if new.owner_id <> auth.uid() or new.expected_revision <> item.revision or new.resulting_revision <> item.revision+1
     or new.resulting_quantity <> item.quantity::bigint+new.delta then raise exception 'invalid stock movement'; end if;
  update public.bd_pantry_items set quantity=new.resulting_quantity,revision=new.resulting_revision where id=new.item_id;
  return new;
end;
$$;
create trigger bd_stock_apply after insert on public.bd_pantry_movements for each row execute function public.bd_apply_stock();
create function public.bd_guard_balance() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if new.id <> old.id or new.owner_id <> old.owner_id or new.created_at <> old.created_at or new.currency <> old.currency then raise exception 'immutable account'; end if;
  if (new.balance_minor <> old.balance_minor or new.revision <> old.revision) and pg_trigger_depth() < 2 then raise exception 'ledger entry required'; end if;
  return new;
end;
$$;
create trigger bd_balance_guard before update on public.bd_wallet_accounts for each row execute function public.bd_guard_balance();
create function public.bd_apply_balance() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare account public.bd_wallet_accounts;
begin
  select * into strict account from public.bd_wallet_accounts where id=new.account_id and owner_id=auth.uid() for update;
  if new.owner_id <> auth.uid() or new.expected_revision <> account.revision or new.resulting_revision <> account.revision+1
     or new.resulting_balance <> account.balance_minor+new.delta_minor or abs(new.resulting_balance) > 9000000000000 then raise exception 'invalid ledger entry'; end if;
  update public.bd_wallet_accounts set balance_minor=new.resulting_balance,revision=new.resulting_revision where id=new.account_id;
  return new;
end;
$$;
create trigger bd_balance_apply after insert on public.bd_wallet_entries for each row execute function public.bd_apply_balance();
create function public.bd_claim_gateway(p_nonce text,p_method text,p_path text) returns uuid
language plpgsql security invoker set search_path = '' as $$
declare result uuid;
begin
  if auth.uid() is null or p_nonce is null or p_nonce !~ '^[A-Za-z0-9_-]{16,128}$'
     or p_method is null or p_method !~ '^[A-Z]{3,12}$' or p_path is null or length(p_path) not between 1 and 256 then raise exception 'invalid request'; end if;
  perform pg_advisory_xact_lock(hashtextextended('gateway:'||auth.uid()::text,0));
  if exists(select 1 from public.bd_runs where owner_id=auth.uid() and project_id='zero-trust-auth-gateway' and client_key='request:'||p_nonce) then raise exception 'replayed request'; end if;
  if (select count(*) from public.bd_runs where owner_id=auth.uid() and project_id='zero-trust-auth-gateway' and kind='request.audit' and created_at > now()-interval '1 minute') >= 60 then raise exception 'rate limit'; end if;
  insert into public.bd_runs(owner_id,project_id,client_key,kind,result) values(auth.uid(),'zero-trust-auth-gateway','request:'||p_nonce,'request.audit',jsonb_build_object('method',p_method,'path',p_path)) returning id into result;
  return result;
end;
$$;
revoke all on function public.bd_guard_stock(),public.bd_apply_stock(),public.bd_guard_balance(),public.bd_apply_balance(),public.bd_claim_gateway(text,text,text) from public,anon;
grant execute on function public.bd_guard_stock(),public.bd_apply_stock(),public.bd_guard_balance(),public.bd_apply_balance(),public.bd_claim_gateway(text,text,text) to authenticated;
