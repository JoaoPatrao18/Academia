-- Treino Híbrido — schema Supabase
-- Rode este arquivo no SQL Editor do projeto Supabase (uma vez) para criar as
-- tabelas usadas por index.html. Depois rode seed.sql (se existir) para
-- popular days/exercises/run_sessions/run_progression.
--
-- Este é um app pessoal de usuário único, sem login de verdade: o acesso é
-- protegido por um "código de acesso" simples checado nas policies RLS via
-- a função public.has_access_code() (ver seção RLS abaixo e CLAUDE.md).

-- ── Tabelas de conteúdo (dias, exercícios, corrida) ─────────────────────────

create table if not exists public.days (
  key text primary key,
  name text not null,
  focus text not null,
  badge_kind text not null,       -- 'plate' | 'lane' | outro (descanso)
  badge_kg integer,
  badge_color text,               -- 'yellow' | 'red' | 'green' | 'blue'
  order_index integer not null
);

create table if not exists public.exercises (
  id bigint generated always as identity primary key,
  day_key text not null references public.days(key),
  section text not null default 'forca',
  order_index integer not null,
  name text not null,
  scheme text,
  sets integer,
  note text,
  video_id text,
  howto jsonb default '[]'::jsonb,          -- array de strings
  alternatives jsonb default '[]'::jsonb,   -- array de {name, video}
  diagram_svg text
);

create table if not exists public.run_sessions (
  id bigint generated always as identity primary key,
  day_key text not null references public.days(key),
  field text not null,            -- coluna correspondente em run_progression (curta/media/longa)
  label text not null,
  description text,
  pace_tip text                   -- texto estático do painel "Como calibrar o ritmo" (editável no Table Editor)
);

create table if not exists public.run_progression (
  week integer primary key,
  curta numeric,
  media numeric,
  longa numeric,
  recuo boolean default false
);

create table if not exists public.settings (
  key text primary key,
  value text
);
-- chaves conhecidas: 'current_week' (semana da progressão de corrida),
-- 'user_age' (idade em anos, usada pra calcular a zona de FC alvo)

-- ── Tabelas de registro (histórico do usuário) ──────────────────────────────

create table if not exists public.set_logs (
  id bigint generated always as identity primary key,
  created_at timestamptz default now(),
  log_date date default current_date,
  exercise_id bigint not null references public.exercises(id),
  set_number integer not null,
  weight numeric,
  reps integer,
  variant_name text,          -- nome da alternativa feita em vez do exercício principal (null = principal)
  unique (exercise_id, set_number, log_date)  -- 1 registro por série/dia; refazer a mesma série faz upsert
);

create table if not exists public.run_logs (
  id bigint generated always as identity primary key,
  created_at timestamptz default now(),
  log_date date default current_date,
  day_key text not null,
  distance_km numeric,
  duration_min numeric,
  rpe integer,
  avg_heart_rate integer,         -- FC média opcional (bpm), usada no feedback pós-corrida
  notes text
);

create table if not exists public.body_measurements (
  date date primary key default current_date,
  weight_kg numeric not null,
  waist_cm numeric,
  arm_cm numeric,
  created_at timestamptz default now()
);

create table if not exists public.skipped_days (
  log_date date primary key default current_date,  -- 1 registro por data: pular é por dia, não por sessão
  day_key text not null,
  reason text,
  created_at timestamptz default now()
);

-- índices usados pelas comparações semana-atual-vs-anterior e pela detecção de
-- estagnação (index.html filtra/ordena set_logs e run_logs por essas colunas)
create index if not exists idx_set_logs_exercise_date on public.set_logs (exercise_id, log_date);
create index if not exists idx_run_logs_day_date on public.run_logs (day_key, log_date);

-- Texto padrão do painel "Como calibrar o ritmo" — index.html insere a linha de
-- zona de FC calculada entre a 2ª e a 3ª linha deste texto (ver
-- renderPaceTipLines() em index.html). Editável depois pelo Table Editor.
update public.run_sessions
set pace_tip = 'Teste da conversa: você deve conseguir falar frases completas correndo, sem ficar ofegante. Se não consegue completar uma frase, está rápido demais. É mais seguro errar para o lado devagar do que para o lado rápido, principalmente construindo base.
Referência de pace pra começar (só ponto de partida, não meta): entre 6:00 e 7:30 min/km — mais lento do que a maioria espera na primeira vez.
Nas primeiras semanas, não presta atenção no relógio pra ritmo — só corre no ritmo de conversa e deixa tempo/distância caírem onde caírem.'
where pace_tip is null;

-- ── RLS: proteção por código de acesso ──────────────────────────────────────
--
-- index.html envia um header "x-app-code" em toda chamada ao Supabase
-- (constante ACCESS_CODE no topo do <script>). A função abaixo compara esse
-- header com o código configurado; as policies de cada tabela só liberam
-- leitura/escrita se a função retornar true. Sem o header certo, a API
-- responde 200 com resultado vazio (não vaza dado nem erro revelador).
--
-- Para trocar/revogar o código: rode este CREATE OR REPLACE FUNCTION de novo
-- com um novo valor, e atualize ACCESS_CODE em index.html com o mesmo valor.

create or replace function public.has_access_code()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('request.headers', true)::json->>'x-app-code', '') = 'TROQUE_ESTE_CODIGO';
$$;

revoke all on function public.has_access_code() from public;
grant execute on function public.has_access_code() to anon, authenticated;

alter table public.days enable row level security;
alter table public.exercises enable row level security;
alter table public.run_sessions enable row level security;
alter table public.run_progression enable row level security;
alter table public.settings enable row level security;
alter table public.set_logs enable row level security;
alter table public.run_logs enable row level security;
alter table public.body_measurements enable row level security;
alter table public.skipped_days enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['days','exercises','run_sessions','run_progression','settings','set_logs','run_logs','body_measurements','skipped_days']
  loop
    execute format('drop policy if exists %I on public.%I;', 'allow all - ' || t, t);
    execute format('drop policy if exists %I on public.%I;', 'access code - ' || t, t);
    execute format('create policy %I on public.%I for all to public using (public.has_access_code()) with check (public.has_access_code());', 'access code - ' || t, t);
  end loop;
end $$;
