# bond-desktop — notes for Claude

Flutter macOS app (in `app/`) driving local LLM servers via the `Makefile`.
This repo is PUBLIC: fixtures stay fictional, secrets stay in `.env`/`local.mk`
(both git-ignored).

## Gates

Before any commit: `.claude/hooks/gate.sh <label>` — it runs
`cd app && flutter analyze && flutter test` offline and serverless, tees the
full output to a /tmp log, prints a ~20-line summary, and records the green
stamp the commit hook checks. Live `make` bench targets are never part of the
gates. Executor gotchas (schema sequence, test idioms) live in `app/CLAUDE.md`;
the hooks in `.claude/hooks/` enforce the house rules (`BOND_HOOKS_OFF=1`
disables them for a session).

## Evaluating models and runtimes

`docs/model-bakeoff.md` is the authority: the run protocol, every knob, the
oMLX install story (including the xgrammar dylib workaround), the run matrix
with exact commands, and the ledger of measured results. Read it before
benching anything. The short version:

- One command per evaluation: `make bench` / `bench-prose` / `ab` /
  `ab-membership` / `drain`, pointed with `BENCH_URL`/`BENCH_MODEL`/
  `BENCH_LABEL` (bulk slot) or `PROSE_*` (prose slot). Result JSON lands in
  git-ignored `tmp/bench/`; `make bench-compare A=… B=…` diffs two runs
  (absolute paths — the tool runs from `app/`).
- `make bench-verify` runs automatically first and is the only live test that
  asserts: it checks facts about a server's configuration (schema honoured,
  decoding constrained, usage reported), not judgements. Every other live
  bench prints its answers and asserts shape only — never add accuracy
  thresholds to a live bench; a model swap would fail them for no defect.
- Throughput is time-weighted: sum tokens and sum milliseconds, divide once.
  Never average per-call rates.
- Run each row twice, keep the second (caches). Record keeper numbers in the
  ledger in `docs/model-bakeoff.md` — result JSONs are disposable, the ledger
  is the record.
- Adopting a winner is config, not code: `local.mk` with plain `=` for the
  `*_URL`/`*_MODEL` vars, then `make app-run`.

## Makefile conventions

Why-comments sit ABOVE assignments; recipes split server-launch lines from
`$(MAKE)` wait lines so `make -n` stays a dry run; `?=` vars that users
override live AFTER the `-include local.mk` line.
