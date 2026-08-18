-- Treino Híbrido — schema Supabase
-- Rode este arquivo no SQL Editor do projeto Supabase (uma vez) para criar as
-- tabelas usadas por index.html. Depois rode seed.sql (se existir) para
-- popular days/exercises/run_sessions/run_progression.
--
-- Todas as tabelas usam RLS "allow all" (to public) porque este é um app
-- pessoal de usuário único acessado só com a chave anon — não há login.

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
  description text
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

-- ── Tabelas de registro (histórico do usuário) ──────────────────────────────

create table if not exists public.set_logs (
  id bigint generated always as identity primary key,
  created_at timestamptz default now(),
  log_date date default current_date,
  exercise_id bigint not null references public.exercises(id),
  set_number integer not null,
  weight numeric,
  reps integer
);

create table if not exists public.run_logs (
  id bigint generated always as identity primary key,
  created_at timestamptz default now(),
  log_date date default current_date,
  day_key text not null,
  distance_km numeric,
  duration_min numeric,
  rpe integer,
  notes text
);

create table if not exists public.body_measurements (
  date date primary key default current_date,
  weight_kg numeric not null,
  waist_cm numeric,
  arm_cm numeric,
  created_at timestamptz default now()
);

-- ── RLS ─────────────────────────────────────────────────────────────────────

alter table public.days enable row level security;
alter table public.exercises enable row level security;
alter table public.run_sessions enable row level security;
alter table public.run_progression enable row level security;
alter table public.settings enable row level security;
alter table public.set_logs enable row level security;
alter table public.run_logs enable row level security;
alter table public.body_measurements enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['days','exercises','run_sessions','run_progression','settings','set_logs','run_logs','body_measurements']
  loop
    if not exists (
      select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'allow all - ' || t
    ) then
      execute format('create policy %I on public.%I for all to public using (true) with check (true);', 'allow all - ' || t, t);
    end if;
  end loop;
end $$;
