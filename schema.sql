-- ============================================================
-- Controle de Estoque — schema do banco de dados (Supabase)
-- ============================================================
-- Como usar:
-- 1. Crie um projeto gratuito em https://supabase.com
-- 2. No painel do projeto, abra "SQL Editor" → "New query"
-- 3. Cole TODO o conteúdo deste arquivo e clique em "Run"
-- 4. Depois, vá em "Project Settings" → "API" e copie a
--    "Project URL" e a chave "anon public"
-- 5. Cole os dois valores no arquivo estoque_2.html, nas
--    constantes SUPABASE_URL e SUPABASE_ANON_KEY, perto do
--    início do <script>
-- ============================================================

-- ---------- tabelas ----------

create table if not exists categories (
  key text primary key,
  label text not null,
  color text not null default '#4F46E5'
);

create table if not exists branches (
  key text primary key,
  label text not null
);

create table if not exists users (
  id text primary key,
  username text unique not null,
  password_hash text not null,
  role text not null default 'editor',
  created_at timestamptz not null default now()
);

create table if not exists items (
  id text primary key,
  category text not null,
  name text not null,
  unit text not null default 'un',
  qty numeric not null default 0,
  min numeric not null default 0,
  ideal numeric not null default 0,
  avg_cost numeric not null default 0
);

create table if not exists movements (
  id text primary key,
  type text not null,
  item_id text,
  item_name text,
  category_key text,
  unit text,
  qty numeric not null,
  unit_value numeric not null default 0,
  total_value numeric not null default 0,
  branch text,
  withdrawal_name text,
  note text,
  occurred_at timestamptz not null default now(),
  registered_by text
);

-- Log de auditoria: registra tudo que é criado e movimentado (e quem
-- apagou o quê), mesmo depois que o registro original é excluído.
-- "snapshot" guarda uma cópia da linha no momento da ação/exclusão.
create table if not exists audit_log (
  id text primary key,
  entity_type text not null,          -- 'item' | 'movement' | 'system'
  entity_id text,
  action text not null,               -- 'criado' | 'entrada' | 'saida' | 'excluido' | 'deleted'
  description text not null,
  snapshot jsonb,
  performed_by text,
  occurred_at timestamptz not null default now()
);

create index if not exists idx_movements_occurred_at on movements (occurred_at desc);
create index if not exists idx_audit_log_occurred_at on audit_log (occurred_at desc);

-- ---------- dados iniciais ----------
-- (categorias, filiais e o usuário admin padrão já vêm prontos;
--  login inicial: admin / admin123 — troque assim que entrar)

insert into categories (key, label, color) values
  ('insumos', 'Insumos', '#4F46E5'),
  ('limpeza', 'Limpeza', '#0D9488'),
  ('higiene', 'Higiene', '#7C3AED'),
  ('brindes', 'Brindes', '#DB2777'),
  ('uniformes', 'Uniformes', '#78350F'),
  ('escritorio', 'Escritório', '#475569')
on conflict (key) do nothing;

insert into branches (key, label) values
  ('leaf-1', 'Leaf 1'),
  ('leaf-2', 'Leaf 2')
on conflict (key) do nothing;

insert into users (id, username, password_hash, role) values
  ('u-admin', 'admin', 'a63f45da_8', 'admin')
on conflict (id) do nothing;

-- ---------- segurança (RLS) ----------
-- Observação importante: como este é um app 100% estático (sem
-- servidor próprio), o controle de quem pode fazer o quê continua
-- sendo feito pelo login/senha dentro do próprio app, e não pelo
-- Supabase. Por isso as políticas abaixo liberam acesso via a
-- chave "anon" (pública) — é o mesmo nível de proteção que o app
-- já tinha, só que agora compartilhado entre computadores.

alter table categories enable row level security;
alter table branches enable row level security;
alter table users enable row level security;
alter table items enable row level security;
alter table movements enable row level security;
alter table audit_log enable row level security;

drop policy if exists "allow all categories" on categories;
create policy "allow all categories" on categories for all using (true) with check (true);

drop policy if exists "allow all branches" on branches;
create policy "allow all branches" on branches for all using (true) with check (true);

drop policy if exists "allow all users" on users;
create policy "allow all users" on users for all using (true) with check (true);

drop policy if exists "allow all items" on items;
create policy "allow all items" on items for all using (true) with check (true);

drop policy if exists "allow all movements" on movements;
create policy "allow all movements" on movements for all using (true) with check (true);

drop policy if exists "allow all audit_log" on audit_log;
create policy "allow all audit_log" on audit_log for all using (true) with check (true);

-- ---------- funções (registram entrada/saída de forma atômica) ----------
-- Usar essas funções (em vez de fazer UPDATE + INSERT direto do
-- navegador) evita que duas pessoas mexendo no estoque ao mesmo
-- tempo, em computadores diferentes, "pisem" uma no cálculo da
-- outra. Elas também gravam no log de auditoria automaticamente.

create or replace function criar_item_inicial(
  p_id text, p_category text, p_name text, p_unit text, p_qty numeric,
  p_min numeric, p_ideal numeric, p_valor_unit numeric, p_registrado_por text
) returns void as $$
begin
  insert into items (id, category, name, unit, qty, min, ideal, avg_cost)
  values (p_id, p_category, p_name, p_unit, p_qty, p_min, p_ideal,
          case when p_qty > 0 then p_valor_unit else 0 end);

  insert into audit_log (id, entity_type, entity_id, action, description, snapshot, performed_by, occurred_at)
  values (
    p_id || '-log-' || floor(extract(epoch from clock_timestamp()))::text,
    'item', p_id, 'criado',
    'Item "' || p_name || '" criado (' || p_qty || ' ' || coalesce(p_unit,'') || ')',
    jsonb_build_object('id', p_id, 'category', p_category, 'name', p_name, 'unit', p_unit, 'qty', p_qty, 'min', p_min, 'ideal', p_ideal, 'valor_unit', p_valor_unit),
    p_registrado_por, now()
  );

  if p_qty > 0 then
    insert into movements (id, type, item_id, item_name, category_key, unit, qty, unit_value, total_value, note, occurred_at, registered_by)
    values (p_id || '-init', 'entrada', p_id, p_name, p_category, p_unit, p_qty, p_valor_unit, p_qty * p_valor_unit, 'Estoque inicial', now(), p_registrado_por);
  end if;
end;
$$ language plpgsql security definer;

create or replace function registrar_entrada(
  p_id text, p_item_id text, p_qtd numeric, p_valor_unit numeric,
  p_ocorrido_em timestamptz, p_registrado_por text
) returns void as $$
declare
  v_qty numeric; v_avg numeric; v_new_qty numeric; v_new_avg numeric;
  v_item_name text; v_category text; v_unit text;
begin
  select qty, avg_cost, name, category, unit into v_qty, v_avg, v_item_name, v_category, v_unit
  from items where id = p_item_id for update;

  if not found then
    raise exception 'Item não encontrado';
  end if;

  v_new_qty := v_qty + p_qtd;
  v_new_avg := case when v_new_qty > 0 then ((v_qty * v_avg) + (p_qtd * p_valor_unit)) / v_new_qty else 0 end;

  update items set qty = v_new_qty, avg_cost = v_new_avg where id = p_item_id;

  insert into movements (id, type, item_id, item_name, category_key, unit, qty, unit_value, total_value, occurred_at, registered_by)
  values (p_id, 'entrada', p_item_id, v_item_name, v_category, v_unit, p_qtd, p_valor_unit, p_qtd * p_valor_unit, p_ocorrido_em, p_registrado_por);

  insert into audit_log (id, entity_type, entity_id, action, description, snapshot, performed_by, occurred_at)
  values (
    p_id || '-log', 'movement', p_id, 'entrada',
    'Entrada de ' || p_qtd || ' ' || coalesce(v_unit,'') || ' em "' || coalesce(v_item_name,'?') || '" (valor unit. ' || p_valor_unit || ')',
    jsonb_build_object('movement_id', p_id, 'item_id', p_item_id, 'item_name', v_item_name, 'qty', p_qtd, 'unit_value', p_valor_unit, 'occurred_at', p_ocorrido_em),
    p_registrado_por, now()
  );
end;
$$ language plpgsql security definer;

create or replace function registrar_saida(
  p_id text, p_item_id text, p_qtd numeric, p_nome_retirada text, p_filial text,
  p_ocorrido_em timestamptz, p_registrado_por text
) returns void as $$
declare
  v_qty numeric; v_avg numeric; v_item_name text; v_category text; v_unit text;
begin
  select qty, avg_cost, name, category, unit into v_qty, v_avg, v_item_name, v_category, v_unit
  from items where id = p_item_id for update;

  if not found then
    raise exception 'Item não encontrado';
  end if;

  if p_qtd > v_qty then
    raise exception 'Quantidade maior que o estoque disponível';
  end if;

  update items set qty = v_qty - p_qtd where id = p_item_id;

  insert into movements (id, type, item_id, item_name, category_key, unit, qty, unit_value, total_value, branch, withdrawal_name, occurred_at, registered_by)
  values (p_id, 'saida', p_item_id, v_item_name, v_category, v_unit, p_qtd, v_avg, p_qtd * v_avg, p_filial, p_nome_retirada, p_ocorrido_em, p_registrado_por);

  insert into audit_log (id, entity_type, entity_id, action, description, snapshot, performed_by, occurred_at)
  values (
    p_id || '-log', 'movement', p_id, 'saida',
    'Saída de ' || p_qtd || ' ' || coalesce(v_unit,'') || ' de "' || coalesce(v_item_name,'?') || '" para ' || coalesce(p_filial,'?') || ' (' || coalesce(p_nome_retirada,'') || ')',
    jsonb_build_object('movement_id', p_id, 'item_id', p_item_id, 'item_name', v_item_name, 'qty', p_qtd, 'branch', p_filial, 'withdrawal_name', p_nome_retirada, 'occurred_at', p_ocorrido_em),
    p_registrado_por, now()
  );
end;
$$ language plpgsql security definer;

-- Exclui um item, mas primeiro grava uma cópia completa dele no log
-- de auditoria (rastreável mesmo depois de apagado). Chamada apenas
-- pelo app quando o usuário logado é administrador.
create or replace function excluir_item(p_item_id text, p_excluido_por text) returns void as $$
declare
  v_row items%rowtype;
  v_mov movements%rowtype;
begin
  select * into v_row from items where id = p_item_id;
  if not found then
    raise exception 'Item não encontrado';
  end if;

  -- Remove também as movimentações do item, para que seus valores
  -- saiam dos Relatórios; cada uma é copiada para o log de auditoria
  -- antes de ser apagada, para manter a rastreabilidade.
  for v_mov in select * from movements where item_id = p_item_id loop
    insert into audit_log (id, entity_type, entity_id, action, description, snapshot, performed_by, occurred_at)
    values (
      v_mov.id || '-del-' || floor(extract(epoch from clock_timestamp()))::text,
      'movement', v_mov.id, 'excluido',
      'Movimento de ' || v_mov.type || ' do item "' || coalesce(v_mov.item_name, v_row.name) || '" (' || v_mov.qty || ' ' || coalesce(v_mov.unit,'') || ') excluído junto com o item',
      to_jsonb(v_mov), p_excluido_por, now()
    );
  end loop;

  delete from movements where item_id = p_item_id;

  insert into audit_log (id, entity_type, entity_id, action, description, snapshot, performed_by, occurred_at)
  values (
    p_item_id || '-del-' || floor(extract(epoch from clock_timestamp()))::text,
    'item', p_item_id, 'excluido',
    'Item "' || v_row.name || '" excluído (estoque no momento: ' || v_row.qty || ' ' || coalesce(v_row.unit,'') || ')',
    to_jsonb(v_row), p_excluido_por, now()
  );

  delete from items where id = p_item_id;
end;
$$ language plpgsql security definer;

-- Exclui uma movimentação (entrada/saída), gravando uma cópia
-- completa dela no log de auditoria antes de apagar. Admin apenas.
create or replace function excluir_movimento(p_movement_id text, p_excluido_por text) returns void as $$
declare
  v_row movements%rowtype;
begin
  select * into v_row from movements where id = p_movement_id;
  if not found then
    raise exception 'Movimento não encontrado';
  end if;

  insert into audit_log (id, entity_type, entity_id, action, description, snapshot, performed_by, occurred_at)
  values (
    p_movement_id || '-del-' || floor(extract(epoch from clock_timestamp()))::text,
    'movement', p_movement_id, 'deleted',
    'Movimento de ' || v_row.type || ' do item "' || coalesce(v_row.item_name, '?') || '" (' || v_row.qty || ' ' || coalesce(v_row.unit,'') || ') excluído',
    to_jsonb(v_row), p_excluido_por, now()
  );

  delete from movements where id = p_movement_id;
end;
$$ language plpgsql security definer;

-- Apaga movimentações e registros de log anteriores a uma data de
-- corte (para não lotar o limite gratuito do banco), registrando um
-- resumo da limpeza no próprio log. Admin apenas. Não afeta os itens.
create or replace function purgar_periodo(p_ate timestamptz, p_executado_por text) returns integer as $$
declare
  v_count_mov integer;
  v_count_log integer;
begin
  select count(*) into v_count_mov from movements where occurred_at < p_ate;
  select count(*) into v_count_log from audit_log where occurred_at < p_ate;

  delete from movements where occurred_at < p_ate;
  delete from audit_log where occurred_at < p_ate;

  insert into audit_log (id, entity_type, entity_id, action, description, snapshot, performed_by, occurred_at)
  values (
    'purge-' || floor(extract(epoch from clock_timestamp()))::text,
    'system', null, 'deleted',
    'Limpeza de dados: removidos ' || v_count_mov || ' movimento(s) e ' || v_count_log || ' registro(s) de log anteriores a ' || to_char(p_ate, 'DD/MM/YYYY'),
    jsonb_build_object('movimentos_removidos', v_count_mov, 'logs_removidos', v_count_log, 'ate', p_ate),
    p_executado_por, now()
  );

  return v_count_mov + v_count_log;
end;
$$ language plpgsql security definer;

-- Tamanho atual do banco (em bytes), usado pelo app para avisar
-- quando o uso chegar perto do limite gratuito do Supabase (500 MB).
create or replace function get_db_size() returns bigint as $$
  select pg_database_size(current_database());
$$ language sql stable security definer;

grant execute on function criar_item_inicial to anon, authenticated;
grant execute on function registrar_entrada to anon, authenticated;
grant execute on function registrar_saida to anon, authenticated;
grant execute on function excluir_item to anon, authenticated;
grant execute on function excluir_movimento to anon, authenticated;
grant execute on function purgar_periodo to anon, authenticated;
grant execute on function get_db_size to anon, authenticated;

-- Habilita o Supabase Realtime nas tabelas do app, para que o
-- front-end receba as mudanças na hora (sem precisar clicar em
-- "Atualizar").
alter publication supabase_realtime add table items;
alter publication supabase_realtime add table movements;
alter publication supabase_realtime add table categories;
alter publication supabase_realtime add table branches;
alter publication supabase_realtime add table users;
alter publication supabase_realtime add table audit_log;

-- Fim do script. Se tudo rodou sem erro, seu banco está pronto.
