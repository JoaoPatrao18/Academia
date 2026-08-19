# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-page PWA ("Treino Híbrido" — Portuguese for "Hybrid Training") that renders a personal
strength + running workout tracker. It is a hobby project with no build step, no package manager,
and no test suite — just two static files served as-is:

- `index.html` — the entire app: markup, CSS, and vanilla JS all inline in one file (~450 lines).
- `manifest.json` — PWA manifest (installable web app metadata).

There is no bundler, framework, or transpilation. Edit `index.html` directly; changes are live on
reload with no build command.

## Running it

Open `index.html` in a browser, or serve the directory with any static file server (e.g.
`npx serve .`) so the PWA manifest and relative paths resolve correctly.

## Architecture

The app is a thin client over a Supabase Postgres backend (loaded via the `@supabase/supabase-js`
CDN script). All state lives in Supabase tables; the client fetches everything on load and
re-renders from in-memory JS objects.

- `SUPABASE_URL` / `SUPABASE_ANON_KEY` / `ACCESS_CODE` are hardcoded near the top of the
  `<script>` block in `index.html`. There is no `.env` or config file.
- Full schema is checked in at `schema.sql` (idempotent — safe to re-run). Tables:
  - `days` — one row per weekday (`key`, `name`, `focus`, `badge_kind`/`badge_color`/`badge_kg`, `order_index`).
  - `exercises` — strength exercises per `day_key`, including `sets`, `scheme`, `alternatives`
    (JSON array of `{name, video}`), `howto` (JSON array of strings), `diagram_svg` (raw SVG
    markup), `video_id` (YouTube).
  - `run_sessions` — one running workout per `day_key` (`label`, `field`, `description`,
    `pace_tip`). `pace_tip` is the static text for the "Como calibrar o ritmo" panel — free text,
    editable straight in the Table Editor; see the pace-tip bullet below for how it's assembled
    with the calculated heart-rate line.
  - `run_progression` — week-by-week target distances, one row per training week, keyed by
    `week` with per-session-type columns referenced via `run_sessions.field`.
  - `settings` — key/value store. Known keys: `current_week` (running progression week) and
    `user_age` (age in years, used to calculate the heart-rate target zone — see below).
  - `set_logs` — write table for logged sets (`exercise_id`, `set_number`, `weight`, `reps`,
    `log_date`, `variant_name`). Unique on `(exercise_id, set_number, log_date)` — the client
    always `upsert`s on this key, so re-logging the same set on the same day updates the row
    instead of creating a duplicate. `variant_name` holds the alternative exercise name when the
    user logged an alternative instead of the main lift (see `selectedVariant` below); null means
    "did the main exercise."
  - `run_logs` — write table for logged runs (`day_key`, `log_date`, `distance_km`,
    `duration_min`, `rpe`, `avg_heart_rate`). `avg_heart_rate` (bpm) is optional — filled only if
    the user has a watch — and drives the post-run heart-rate feedback (see below).
  - `body_measurements` — write table for body weight tracking (`date` PK, `weight_kg`,
    `waist_cm`, `arm_cm`). `date` being the PK is what makes saving idempotent per day.
  - `skipped_days` — one row per calendar date (`log_date` PK) the user deliberately skipped,
    with the weekday it was (`day_key`) and an optional free-text `reason`. Distinct from just
    having no logs that day: it's shown as a neutral state (not a failure) in the weekly summary
    dots and the streak grid, and doesn't break `computeStreak()`'s current-streak count.

- Rendering flow: `init()` loads all read tables in parallel → `renderShell()` draws the day-tabs
  chrome (plus the weekly summary strip) once → `renderDay()` re-renders the active day's card
  (exercises + optional run box) and is called after every mutation (logging a set, logging a run,
  changing the progression week). There is no virtual DOM — `renderDay()` replaces the day area's
  `innerHTML` wholesale each time. `renderProgressView()` is a separate top-level view (streak
  grid, run log list, body-weight form/chart) that replaces `#root` entirely; `renderShell()` +
  `renderDay()` rebuild the normal view when the user goes back.
- Writes (`set_logs` upsert, `run_logs`, `body_measurements` upsert, `settings.current_week`) go
  straight to Supabase via the anon key on every user interaction — no local caching or
  optimistic-only state; `setStatus()` surfaces a footer message if a write fails, consistently
  across every write path (series, runs, body measurements, week stepper, skip/unskip). Every
  write is preceded by a native `confirm()` showing the value about to be saved.
- The initial load (`init()`) races the Supabase calls against a 9s timeout (`withTimeout()`). A
  timeout or a real connection error both land on `failWithRetry()`, which shows the message plus
  a "Tentar de novo" button that re-runs `init()` from scratch — there's no infinite "Carregando…"
  spinner if the backend is unreachable. `fail()` (no retry button) is reserved for
  non-transient issues that a retry can't fix: missing config, or tables that connected fine but
  are empty (needs `schema.sql`/seed data, not a network retry).
- Edit/delete for past entries lives in three places, all following the same pattern (fetch the
  row, prompt/form pre-filled with current values, confirm, `update`/`delete` by id, re-render just
  that section): the exercise history table (`editSetLog`/`deleteSetLog`), the run log list in
  Progress (`editRunLog`/`deleteRunLog`), and the body-weight list in Progress
  (`editBodyMeasurement`/`deleteBodyMeasurement`).
- `selectedVariant` (exercise_id → alternative name or null) tracks which alternative the user is
  doing today for each exercise, via a `<select>` on the exercise card. It resets to "main
  exercise" whenever the day tab changes and is not persisted — it only affects what gets written
  to `variant_name` on the next `logSet` call for that exercise.
- `currentWeek` drives which column of `run_progression` is shown in the run box and is persisted
  to `settings` so it survives reloads.
- "Pular hoje" (`loadAndRenderSkipBox()`) only renders on today's tab (`day.key === todayKey`),
  regardless of which day is being browsed — it upserts/deletes a single `skipped_days` row keyed
  by today's `log_date`. It's about marking today intentionally skipped, not the currently-viewed
  day.
- The weekly summary (`refreshWeekSummary()`) renders 7 dots (Mon–Sun) plus the "X/Y dias
  treinados essa semana" count. Each dot's `data-state` is one of: `off` (not a training day per
  `days.badge_kind`), `done` (has a `set_logs`/`run_logs` row that date), `skipped` (a
  `skipped_days` row, checked after `done`), `missed` (a past training day with neither), or
  `pending` (today/future, nothing logged yet). It's read-only and best-effort — swallows its own
  errors so a failure there never blocks the rest of the app, same as the streak grid in Progress.
- Weekly comparisons (exercise load and running pace/distance, "essa semana: X · semana passada:
  Y") only render when both weeks have data; otherwise the container is left empty rather than
  showing a misleading zero. Exercise comparison lives in `loadAndRenderHistory()` (reuses the
  already-fetched `historyCache` rows); running comparison is `loadAndRenderRunComparison()`,
  called whenever a day with a run box renders — not gated behind "Ver evolução".
- Pace can be displayed as `min/km` or `km/h`; the choice is global (not per-exercise/day),
  toggled via any "Unidade: … ⇄" button, and persisted with `getPaceUnit()`/`setPaceUnit()`
  (`localStorage`, wrapped in `try/catch` — falls back to an in-memory variable if storage is
  unavailable, e.g. private browsing, so the toggle still works within the session).
- The load suggestion (`computeSuggestion()`) is prescriptive, not just informational: it looks at
  the most recent session's rows for that exercise (`lastSessionRows`, built once per day-render
  in `loadLogsForDay()`) and proposes last-weight + 2.5kg if every set that session met the
  scheme's target reps (parsed from `scheme` via `parseTargetReps()`, which skips time-based
  schemes like `3×40s`), or the same weight to repeat if not. The suggested value is both shown as
  text on the card and pre-filled into the `logSet()` prompt.
- Stagnation (`computeStagnation()`, feeding `stagnantExercises`) flags an exercise when its last
  4 sessions (by best weight/reps per `log_date`, from the same `logsByEx` history pulled in
  `loadLogsForDay()`) show no improvement across any of the 3 most recent session-to-session
  transitions. Needs at least 4 distinct session dates in history; otherwise it's silently skipped
  (not enough data, not "no progress").
- The run week-advance/repeat nudge (`loadAndRenderRunSuggestion()`) looks only at the current
  day's last 2 `run_logs` rows by RPE: both ≤4 suggests advancing `currentWeek` (button calls
  `changeWeek(1)`, a real write); both ≥8 suggests staying (button just clears the message locally
  — there's nothing to persist since the week isn't changing). Mixed RPEs show nothing.
- Heart-rate target zone (`computeHRZone()`) is estimated-max-based: `220 - userAge`, zone =
  60–70% of that. `userAge` is loaded once in `init()` from `settings.user_age` (same pattern as
  `currentWeek`) and updated in memory by `saveUserAge()` on the Progress screen — no reload
  needed for it to take effect elsewhere. Without an age saved, `hrZoneLine()` falls back to the
  generic "60–70% da FC máxima estimada — fórmula: 220 − idade" text plus a prompt to fill it in.
- The "Como calibrar o ritmo" panel (`renderPaceTipLines()`) splits `run_sessions.pace_tip` on
  newlines and splices the calculated (or fallback) heart-rate line in as the 3rd bullet — between
  the "conversation test" and "don't watch the clock" lines. This assumes `pace_tip` has at least
  2 lines; if edited down to fewer, the HR line just gets appended at the end instead of spliced
  in the middle.
- The post-run heart-rate feedback (`computeHRFeedback()`) only renders when *both* `avg_heart_rate`
  (from the just-submitted log) and `userAge` are present — otherwise it's silently omitted, no
  error. It compares the logged bpm against `computeHRZone()`: above → "went out too fast" warning
  (yellow), below → reassurance that erring slow is fine (muted), inside → "well calibrated"
  (green). Shown once, inline with the "✓ registrado" confirmation after logging a run; not
  recomputed retroactively for past logs.

## Security: access-code gate on RLS

There's no real login — this is a single-user hobby app reachable only via the anon key, and the
anon key is necessarily visible to anyone who opens the deployed page's source (that's true of any
client-only Supabase app). To raise the bar above "found the URL, hit the REST API directly with
the anon key," every table's RLS policy also requires a second secret sent as a custom header:

- `index.html` sends `x-app-code: <ACCESS_CODE>` on every Supabase call (configured in
  `createClient(..., { global: { headers: { 'x-app-code': ACCESS_CODE } } })`).
- Each table's RLS policy (`"access code - <table>"`) calls `public.has_access_code()`, a
  `stable sql` function that reads the header via
  `current_setting('request.headers', true)::json->>'x-app-code'` (this is a documented PostgREST/
  Supabase mechanism) and compares it to the code hardcoded in the function body.
- Without the right header, PostgREST still returns `200 OK` but with an empty result — no error
  message that would hint at what's wrong, and no data leaks.
- This does **not** stop someone who opens the deployed page and reads its JS source (the code is
  right there next to the anon key, same trust model as before). What it stops is automated
  scanning/scraping that finds an exposed Supabase URL + anon key (e.g. via GitHub search) and
  hits the REST API directly without ever loading the app — those requests won't carry the header.

**To rotate/revoke the code** (e.g. if it ever leaks): generate a new random string, then run in
the Supabase SQL editor:

```sql
create or replace function public.has_access_code()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('request.headers', true)::json->>'x-app-code', '') = 'NEW_CODE_HERE';
$$;
```

...and update the `ACCESS_CODE` constant in `index.html` to match. The old code stops working the
moment the function is replaced; `schema.sql` keeps a placeholder (`TROQUE_ESTE_CODIGO`) rather
than the real value so the real secret only ever lives in the deployed function and in
`index.html`, not duplicated across files.

## PWA icon

`icon-192.png` / `icon-512.png` (dark background, red plate with "25", generated to match the
app's mono/industrial look) are referenced from `manifest.json` and linked in `index.html`'s
`<head>` (`<link rel="icon">` / `<link rel="apple-touch-icon">`, since Safari ignores the manifest
for home-screen icons).
