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

- `SUPABASE_URL` / `SUPABASE_ANON_KEY` are hardcoded near the top of the `<script>` block in
  `index.html`. There is no `.env` or config file.
- Expected schema (queried in `init()`, not present in this repo — must exist in the linked
  Supabase project, provisioned via `schema.sql` + `seed.sql` mentioned in code comments but not
  checked in here):
  - `days` — one row per weekday (`key`, `name`, `focus`, `badge_kind`/`badge_color`/`badge_kg`, `order_index`).
  - `exercises` — strength exercises per `day_key`, including `sets`, `scheme`, `alternatives`
    (JSON array of `{name, video}`), `howto` (JSON array of strings), `diagram_svg` (raw SVG
    markup), `video_id` (YouTube).
  - `run_sessions` — one running workout per `day_key` (`label`, `field`, `description`).
  - `run_progression` — week-by-week target distances, one row per training week, keyed by
    `week` with per-session-type columns referenced via `run_sessions.field`.
  - `settings` — key/value store; currently only holds `current_week`.
  - `set_logs` — write table for logged sets (`exercise_id`, `set_number`, `weight`, `reps`, `log_date`).
  - `run_logs` — write table for logged runs (`day_key`, `log_date`, `distance_km`, `duration_min`, `rpe`).

- Rendering flow: `init()` loads all read tables in parallel → `renderShell()` draws the day-tabs
  chrome once → `renderDay()` re-renders the active day's card (exercises + optional run box) and
  is called after every mutation (logging a set, logging a run, changing the progression week).
  There is no virtual DOM — `renderDay()` replaces the day area's `innerHTML` wholesale each time.
- Writes (`set_logs`, `run_logs`, `settings.current_week`) go straight to Supabase via the anon
  key on every user interaction (dot tap, run-log button, week stepper) — no local caching or
  optimistic-only state; `setStatus()` surfaces a footer message if a write fails.
- `currentWeek` drives which column of `run_progression` is shown in the run box and is persisted
  to `settings` so it survives reloads.
