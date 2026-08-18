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
  - `run_sessions` — one running workout per `day_key` (`label`, `field`, `description`).
  - `run_progression` — week-by-week target distances, one row per training week, keyed by
    `week` with per-session-type columns referenced via `run_sessions.field`.
  - `settings` — key/value store; currently only holds `current_week`.
  - `set_logs` — write table for logged sets (`exercise_id`, `set_number`, `weight`, `reps`,
    `log_date`, `variant_name`). Unique on `(exercise_id, set_number, log_date)` — the client
    always `upsert`s on this key, so re-logging the same set on the same day updates the row
    instead of creating a duplicate. `variant_name` holds the alternative exercise name when the
    user logged an alternative instead of the main lift (see `selectedVariant` below); null means
    "did the main exercise."
  - `run_logs` — write table for logged runs (`day_key`, `log_date`, `distance_km`, `duration_min`, `rpe`).
  - `body_measurements` — write table for body weight tracking (`date` PK, `weight_kg`,
    `waist_cm`, `arm_cm`). `date` being the PK is what makes saving idempotent per day.

- Rendering flow: `init()` loads all read tables in parallel → `renderShell()` draws the day-tabs
  chrome (plus the weekly summary strip) once → `renderDay()` re-renders the active day's card
  (exercises + optional run box) and is called after every mutation (logging a set, logging a run,
  changing the progression week). There is no virtual DOM — `renderDay()` replaces the day area's
  `innerHTML` wholesale each time. `renderProgressView()` is a separate top-level view (streak
  grid, run log list, body-weight form/chart) that replaces `#root` entirely; `renderShell()` +
  `renderDay()` rebuild the normal view when the user goes back.
- Writes (`set_logs` upsert, `run_logs`, `body_measurements` upsert, `settings.current_week`) go
  straight to Supabase via the anon key on every user interaction — no local caching or
  optimistic-only state; `setStatus()` surfaces a footer message if a write fails. Every write is
  preceded by a native `confirm()` showing the value about to be saved.
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
- The weekly summary ("X/Y dias treinados essa semana") counts, among the weekdays that actually
  have training scheduled (`days.badge_kind` is `plate` or `lane`), how many have at least one
  `set_logs`/`run_logs` row dated within the current Monday–Sunday window. It's read-only and
  best-effort (`refreshWeekSummary()` swallows its own errors so a failure there never blocks the
  rest of the app).

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
