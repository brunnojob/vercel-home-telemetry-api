create table public.bd_projects (
  id text primary key check (length(id) between 1 and 100),
  domain text not null,
  repository_url text not null
);

create table public.bd_runs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  project_id text not null references public.bd_projects(id),
  client_key text not null check (length(client_key) between 1 and 128),
  kind text not null check (kind ~ '^[a-z][a-z0-9_.-]{0,63}$'),
  result jsonb not null check (jsonb_typeof(result) = 'object' and octet_length(result::text) <= 196608),
  events jsonb not null default '[]' check (jsonb_typeof(events) = 'array' and jsonb_array_length(events) <= 500),
  created_at timestamptz not null default now(),
  unique (owner_id, project_id, client_key),
  unique (id, owner_id)
);
create index bd_runs_owner_project_time on public.bd_runs(owner_id, project_id, created_at desc);

create table public.bd_events (
  run_id uuid not null,
  owner_id uuid not null,
  sequence integer not null check (sequence >= 0),
  payload jsonb not null check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 16384),
  primary key (run_id, sequence),
  foreign key (run_id, owner_id) references public.bd_runs(id, owner_id)
);
create index bd_events_owner on public.bd_events(owner_id);

create table public.bd_telemetry (
  id bigint generated always as identity primary key,
  owner_id uuid not null default auth.uid() references auth.users(id),
  device_id varchar(64) not null check (device_id ~ '^[a-zA-Z0-9_-]{1,64}$'),
  temperature_c double precision check (temperature_c between -40 and 85),
  humidity_pct double precision check (humidity_pct between 0 and 100),
  soil_moisture integer check (soil_moisture between 0 and 4095),
  event_at timestamptz not null,
  received_at timestamptz not null default now(),
  check (temperature_c is not null or humidity_pct is not null or soil_moisture is not null)
);
create index bd_telemetry_owner_device_time on public.bd_telemetry(owner_id, device_id, event_at desc);

create table public.bd_work_orders (
  id bigint generated always as identity primary key,
  owner_id uuid not null default auth.uid() references auth.users(id),
  asset_tag text not null check (asset_tag ~ '^[A-Z0-9_-]{1,32}$'),
  title text not null check (length(title) between 4 and 160),
  priority text not null check (priority in ('low','medium','high','critical')),
  status text not null default 'open' check (status in ('open','acknowledged','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index bd_work_orders_owner_status on public.bd_work_orders(owner_id, status, created_at desc);

create table public.bd_inspections (
  record_id uuid not null,
  owner_id uuid not null default auth.uid() references auth.users(id),
  form_id text not null check (form_id ~ '^[a-zA-Z0-9_-]{1,48}$'),
  asset_tag text not null check (asset_tag ~ '^[A-Z0-9_-]{1,32}$'),
  answers jsonb not null check (jsonb_typeof(answers) = 'object' and octet_length(answers::text) <= 32000),
  captured_at timestamptz not null,
  received_at timestamptz not null default now(),
  primary key (owner_id, record_id)
);

alter table public.bd_projects enable row level security;
alter table public.bd_runs enable row level security;
alter table public.bd_events enable row level security;
alter table public.bd_telemetry enable row level security;
alter table public.bd_work_orders enable row level security;
alter table public.bd_inspections enable row level security;

revoke all on public.bd_projects, public.bd_runs, public.bd_events, public.bd_telemetry,
  public.bd_work_orders, public.bd_inspections from anon, authenticated;
grant select on public.bd_projects to anon, authenticated;
grant select, insert on public.bd_runs, public.bd_events, public.bd_telemetry, public.bd_inspections to authenticated;
grant select, insert, update on public.bd_work_orders to authenticated;
grant usage on sequence public.bd_telemetry_id_seq, public.bd_work_orders_id_seq to authenticated;

create policy bd_projects_read on public.bd_projects for select to anon, authenticated using (true);
create policy bd_runs_read on public.bd_runs for select to authenticated using (owner_id = (select auth.uid()));
create policy bd_runs_insert on public.bd_runs for insert to authenticated with check (owner_id = (select auth.uid()));
create policy bd_events_read on public.bd_events for select to authenticated using (owner_id = (select auth.uid()));
create policy bd_events_insert on public.bd_events for insert to authenticated with check (owner_id = (select auth.uid()));
create policy bd_telemetry_read on public.bd_telemetry for select to authenticated using (owner_id = (select auth.uid()));
create policy bd_telemetry_insert on public.bd_telemetry for insert to authenticated with check (owner_id = (select auth.uid()));
create policy bd_work_orders_read on public.bd_work_orders for select to authenticated using (owner_id = (select auth.uid()));
create policy bd_work_orders_insert on public.bd_work_orders for insert to authenticated with check (owner_id = (select auth.uid()));
create policy bd_work_orders_update on public.bd_work_orders for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy bd_inspections_read on public.bd_inspections for select to authenticated using (owner_id = (select auth.uid()));
create policy bd_inspections_insert on public.bd_inspections for insert to authenticated with check (owner_id = (select auth.uid()));

create function public.bd_record_run(p_project text, p_client_key text, p_kind text, p_result jsonb, p_events jsonb default '[]')
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  run public.bd_runs;
begin
  if auth.uid() is null then raise exception 'authenticated user required'; end if;
  if p_events is null or jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 500 then
    raise exception 'invalid events';
  end if;
  insert into public.bd_runs(owner_id, project_id, client_key, kind, result, events)
    values(auth.uid(), p_project, p_client_key, p_kind, p_result, p_events)
    on conflict (owner_id, project_id, client_key) do nothing returning * into run;
  if run.id is null then
    select * into strict run from public.bd_runs where owner_id = auth.uid() and project_id = p_project and client_key = p_client_key;
    if run.kind <> p_kind or run.result <> p_result or run.events <> p_events then raise exception 'idempotency conflict'; end if;
    return run.id;
  end if;
  insert into public.bd_events(run_id, owner_id, sequence, payload)
    select run.id, auth.uid(), ordinality - 1, value from jsonb_array_elements(p_events) with ordinality;
  return run.id;
end;
$$;
revoke all on function public.bd_record_run(text,text,text,jsonb,jsonb) from public, anon;
grant execute on function public.bd_record_run(text,text,text,jsonb,jsonb) to authenticated;

create function public.bd_work_order_guard() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if new.owner_id <> old.owner_id or new.asset_tag <> old.asset_tag or new.created_at <> old.created_at then
    raise exception 'immutable identity';
  end if;
  if new.status <> old.status and not ((old.status = 'open' and new.status = 'acknowledged') or
      (old.status = 'acknowledged' and new.status = 'closed')) then raise exception 'invalid state transition'; end if;
  new.updated_at = now();
  return new;
end;
$$;
revoke all on function public.bd_work_order_guard() from public, anon, authenticated;
create trigger bd_work_order_transition before update on public.bd_work_orders
  for each row execute function public.bd_work_order_guard();

insert into public.bd_projects(id, domain, repository_url) values
('Badges4-README.md-Profile','software','https://github.com/brunnojob/Badges4-README.md-Profile'),
('android-offshore-field-console','industrial','https://github.com/brunnojob/android-offshore-field-console'),
('arduino-air-quality-monitor','industrial','https://github.com/brunnojob/arduino-air-quality-monitor'),
('arduino-cloud-telemetry','industrial','https://github.com/brunnojob/arduino-cloud-telemetry'),
('arduino-smart-irrigation','industrial','https://github.com/brunnojob/arduino-smart-irrigation'),
('bank-crypto-ledger','software','https://github.com/brunnojob/bank-crypto-ledger'),
('bet-admin-dashboard','software','https://github.com/brunnojob/bet-admin-dashboard'),
('brunnojob','software','https://github.com/brunnojob/brunnojob'),
('c-file-integrity-audit','software','https://github.com/brunnojob/c-file-integrity-audit'),
('c-household-budget','software','https://github.com/brunnojob/c-household-budget'),
('casino-simulator-brunnodev','software','https://github.com/brunnojob/casino-simulator-brunnodev'),
('cpp-safe-task-queue','software','https://github.com/brunnojob/cpp-safe-task-queue'),
('cpp-water-leak-alarm','software','https://github.com/brunnojob/cpp-water-leak-alarm'),
('csharp-pantry-api','software','https://github.com/brunnojob/csharp-pantry-api'),
('eletrical-comands-and-teory','industrial','https://github.com/brunnojob/eletrical-comands-and-teory'),
('faceclock-yolo','software','https://github.com/brunnojob/faceclock-yolo'),
('fuckup','software','https://github.com/brunnojob/fuckup'),
('industrial-iot-sentinel','industrial','https://github.com/brunnojob/industrial-iot-sentinel'),
('java-fuel-efficiency','software','https://github.com/brunnojob/java-fuel-efficiency'),
('java-medication-schedule','software','https://github.com/brunnojob/java-medication-schedule'),
('java-neighborhood-repair-log','software','https://github.com/brunnojob/java-neighborhood-repair-log'),
('nodered-industrial-automation','software','https://github.com/brunnojob/nodered-industrial-automation'),
('offshore-scada-simulator','industrial','https://github.com/brunnojob/offshore-scada-simulator'),
('painel-admin-aposta','software','https://github.com/brunnojob/painel-admin-aposta'),
('pair-extraordinaire-badge','software','https://github.com/brunnojob/pair-extraordinaire-badge'),
('pid-pressure-control','industrial','https://github.com/brunnojob/pid-pressure-control'),
('plc-modbus-safety-controller','industrial','https://github.com/brunnojob/plc-modbus-safety-controller'),
('scada-code-studio','industrial','https://github.com/brunnojob/scada-code-studio'),
('secure-payment-pos-core','software','https://github.com/brunnojob/secure-payment-pos-core'),
('trazorbypasssafe7','software','https://github.com/brunnojob/trazorbypasssafe7'),
('vercel-home-telemetry-api','software','https://github.com/brunnojob/vercel-home-telemetry-api'),
('zero-trust-auth-gateway','software','https://github.com/brunnojob/zero-trust-auth-gateway');

