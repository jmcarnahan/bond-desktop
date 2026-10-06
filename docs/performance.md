# Performance: where the database runs, and how to measure the UI

## Where the database runs

The app's one SQLite connection lives on a background isolate (`appExecutor`
in `app/lib/data/db.dart`): the isolate is spawned as the executor is built and
the connection opens there at first use. Before this,
every statement stepped on the UI isolate: a burst of SQL — an inbox reload
after an AI result, a storyline sweep, a mail arrival — was a frame stall,
because the isolate that draws the screen was the one waiting on
`sqlite3_step`.

What did not change: there is still ONE connection, still in WAL mode, behind
the same store API. sqlite-vec is registered in the background isolate before
the connection opens (`loadSqliteVecInIsolate`), and the launch log's
`sqlite-vec <version>` line is asked of that connection. Tests open the
same-isolate executor (`BondDatabase.memory()` / `BondDatabase.open`), because
a widget test's fake-async zone must never wait on a real isolate.

Stored vectors are read in place as float32 (`decodeEmbedding` returns a
`Float32List` view over the blob's bytes), so a storyline pass that reads
thousands of them builds no boxed double per element. And the clustering
index's backfill, which runs at the start of every sweep, no longer carries
every 4 KB vector across from the database isolate to find out that nothing
changed: it compares keys and hashes, and fetches a vector only for a row it
writes.

## What rides on a tick

Moving the database off the UI isolate does not make a read free; it only
moves where the wait is. So the two pulses that most reads follow are thinned
at the source. The inbox list reloads 400 ms after the last progress report
and at most 2 s into a burst (`Coalescer` in `app/lib/utils/coalescer.dart`),
however many items the drains finish meanwhile. The activity tick that eleven
read models follow — the activity pane, the Sync & data stamps, the cloud-draft
count, the context panes, the notification and pipeline reads, the Home pulse —
is thinned to one per 250 ms (`activityTickWindow`, `coalesceLatest`), where it
used to re-run all of them once per recorded event. The notification
coordinator still hears every event: it listens to the recorder's own stream,
not the tick.

## The trade

A read now queues behind a long write transaction on the one connection. The
UI stays live while it waits, but the data can arrive later than it used to.

The connection also waits up to five seconds for a lock rather than failing on
one (`waitOutLocks`), which only ever matters after a debug hot restart, while
the old isolate's connection is still being closed. On a `BOND_DB_UI_ISOLATE`
build that wait is on the UI isolate.

A read pool is deliberately not used yet, for one reason: a read outside a
transaction would stop waiting for an open one to commit, so code that reads
and then writes could act on the state from before a transaction that today
it always sees the end of. That needs an audit of every read-then-write in
the stores before it is safe. It is NOT held back by writes that return rows:
drift's pool sends a statement to the writer when it runs inside a transaction
or when its text contains `RETURNING` (matched literally, in capitals, which
is how every statement here spells it), and every write that hands rows back
goes through `customWriteReturning` so that it reads as the write it is.

## Measuring

Measure in profile mode, on one build, with the log on:
```sh
make app-profile BOND_PERF_LOG=1                      # after: the background connection
make app-profile BOND_PERF_LOG=1 BOND_DB_UI_ISOLATE=1 # before: SQLite back on the UI isolate
```

A debug build (`make app-run`) runs Dart several times slower, which inflates
every Dart-side cost (rebuilds, decoding, vector maths) but not the time SQLite
spends. It is not what to measure.

`BOND_PERF_LOG` prints two kinds of line to the run's console.

- `ui-stall <ms>ms` — a 10 ms heartbeat timer runs on the UI isolate, and a
  tick can only fire when that isolate is free, so how late it fires is how
  long the isolate was blocked, read at most 10 ms short (the timer keeps to
  a fixed grid, so a block that starts between two ticks loses the part of
  the gap already spent; at a 50 ms heartbeat a 100 ms freeze read as 54 to
  99 and was never logged, which is why it is 10). A lateness of 100 ms or
  more gets a line. Every 60 seconds a summary follows, `ui-stalls 60s:
  janks=<n> stalls=<n> max=<ms>ms blocked=<ms>ms`: `janks` counts heartbeats
  late by 33 ms or more (two frames, the first a person can see), `stalls`
  those late by 100 ms or more, `max` the worst, and `blocked` the sum of
  every lateness of a jank or more. It is printed even when everything is
  zero, so a quiet minute is visible.
- `db-slow <ms>ms <kind> <sql>` — a statement that took 50 ms or more as the
  UI isolate saw it: the wait in the connection's queue, the hop to the
  database isolate and back, and the execution. `<kind>` is `select`,
  `insert`, `update`, `delete`, `custom` or `batch`; `<sql>` is the statement
  text, whitespace collapsed and cut to 120 characters. Never the arguments:
  every statement is parameterised and the arguments are the user's mail.
  Three more kinds have `-` for their SQL because drift issues them itself:
  `open` (the first open with its migration, and every transaction's BEGIN —
  a slow `open` mid-session is a transaction waiting its turn behind another
  one), `commit` and `rollback`.

What to read first in a run: the `blocked` total and the `janks` count of the
minutes a burst covered, then the `db-slow` lines. A line shows only the first
120 characters of its statement, so know these by how they START: `select
SELECT c.*, ai.bucket AS bucket` is the inbox's list read, `select SELECT
conversation_key, source, source_message_id, from_address` is the attention
pass's read of every thread's newest message, and `open -` in the middle of a
session is a transaction that waited its turn. Those three say whether a click
that needs data is still waiting behind a reload.

The gates (`flutter analyze` and `flutter test`) cannot see performance. The
before and after numbers — janks, stalls, worst, blocked, and the slowest
statements — go in the PR description.

## A bench without the app

`make bench-ui` measures the same thing with no app and no server
(`app/test/ui_stall_bench_test.dart`, skipped in every ordinary run). It seeds
a fictional mailbox on a temp file and drives the real store while a
`UiStallMonitor` heartbeat runs on the test's own isolate, which stands in for
the UI isolate. Each scenario runs on both executors — `ui`, SQLite on that
isolate, which is what `main` did, and `bg`, SQLite on a background isolate —
and the two that changed algorithm run `main`'s version beside the branch's
(kept in the bench file as its baseline, nowhere else). It prints a table and
asserts only shape: a timing that holds on one machine fails for no defect on
another.

It runs under `flutter test`, so the Dart-side costs are several times a
release build's and SQLite's are not: read the rows against each other, not
as what a user sees. `BENCH_UI_THREADS`, `BENCH_UI_RELOADS`, `BENCH_UI_ARRIVAL`
and `BENCH_UI_LABEL` size and name a run; `BENCH_UI_OUT=<dir>` also writes the
rows as JSON. Run each row twice and keep the second, and record the keeper
here: the JSON is disposable, this table is the record.

**2026-10-06, M-series Mac, the round that moved the database off the UI
isolate.** `worst` is the longest the isolate was blocked in one go, in
milliseconds, read at most 10 short; `blocked` is the sum of every block of
33 ms or more, so a 0 there means no jank, not no work; a reload row is ten
reloads, so its `worst` is one reload.

| Scenario | Threads | `main` (its algorithm, `ui`): worst / blocked | Branch (`bg`): worst / blocked | Time per reload, branch |
|---|---|---|---|---|
| Reload ×10 | 2,000 | 523 / 5,015 | 3 / 0 | about 100 |
| Reload ×10 | 5,000 | 1,362 / 13,136 | 13 / 0 | about 290 |
| Arrival of 200 messages | 2,000 | 37 / 37 | 1 / 0 | n/a |
| Index backfill ×5, corpus unchanged | 2,000 | 82 / 82 | 2 / 0 | n/a |
| Index backfill ×5, corpus unchanged | 5,000 | 265 / 265 | 9 / 0 | n/a |

What the rows say. Every reload `main` made was a stall, half a second at
2,000 threads and about 1.4 s at 5,000; on the branch no reload is
even a jank (nothing reaches 33 ms). The two changes need each other: `main`'s
transaction-per-thread pass run on the background connection blocks nothing
but takes LONGER end to end (6.8 s against 5.4 s for ten reloads at 2,000
threads, a round trip per statement), and the branch's batched pass run on the
UI isolate still freezes it for about 100 ms a reload. The last column is the
trade in numbers: it is a whole reload end to end, this isolate's own share
included, so it is the most a read that needs the connection can wait behind
one. The backfill's own change (keys and hashes instead of every vector)
saves little time at these sizes — 79 ms against 82 for five passes on the
`ui` arm — and reading vectors in place saves 16 ms per 2,000; what took those
two off the UI isolate was the background connection.

## A second opinion: the VM-service probe

The probe below measures from outside the app, through the VM service, and
pulls a CPU profile of each stall it sees. Needs Python 3 with `websockets`. Find the VM service URL in the `flutter run`
output (or the DDS redirect: connecting to the raw VM service URL while DDS is
attached returns an error naming the DDS URL to use). Get the main isolate id
with a `getVM` call. Run it from a scratch directory, not inside the repo.

```python
# probe.py  URI ISOLATE_ID SECONDS OUTDIR
# Pings the main isolate every 100 ms; after a stall > 120 ms, waits, then
# pulls the CPU samples covering the stall into OUTDIR/stall_NN.json.
import asyncio, json, sys, time, os, websockets
URI, ISO, DUR, OUT = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
os.makedirs(OUT, exist_ok=True); pending = {}; nid = [0]

async def main():
    async with websockets.connect(URI, max_size=None) as ws:
        pings, captures = [], []
        async def reader():
            async for raw in ws:
                m = json.loads(raw)
                if "id" in m and m["id"] in pending:
                    pending.pop(m["id"]).set_result(m)
        async def call(method, params=None):
            nid[0] += 1; i = str(nid[0])
            f = asyncio.get_event_loop().create_future(); pending[i] = f
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": i,
                                      "method": method, "params": params or {}}))
            return await f
        rt = asyncio.create_task(reader())
        m0 = time.monotonic(); k = 0
        while time.monotonic() - m0 < DUR:
            vs = (await call("getVMTimelineMicros"))["result"]["timestamp"]
            s = time.monotonic()
            await call("ext.flutter.timeDilation", {"isolateId": ISO})  # runs on main isolate
            ms = (time.monotonic() - s) * 1000
            pings.append((round(s - m0, 1), round(ms, 1)))
            if ms > 120 and k < 12:
                await asyncio.sleep(1.5)
                now = (await call("getVMTimelineMicros"))["result"]["timestamp"]
                r = await call("getCpuSamples", {"isolateId": ISO,
                    "timeOriginMicros": vs - 2_000_000,
                    "timeExtentMicros": now - vs + 2_000_000})
                json.dump(r.get("result", r), open(f"{OUT}/stall_{k:02d}.json", "w"))
                captures.append((round(s - m0, 1), round(ms), k)); k += 1
                await asyncio.sleep(1.0)  # let the profiler's own stall pass
            await asyncio.sleep(0.1)
        json.dump({"pings": pings, "captures": captures}, open(f"{OUT}/run.json", "w"))
        rt.cancel()

asyncio.run(main())
```

Pitfall: an isolate-scoped VM service call such as `getCpuSamples` executes on
the main isolate. Polling it periodically produces regular stalls that are the
profiler's own. Pull samples only after a stall, as the script does.

To read a capture, walk `samples[].stack` (indices into `functions[]`), count
each function once per sample for inclusive time, and filter to frames whose
script URI is in the app package plus `sqlite3_step` / Drift `runSelect`.
