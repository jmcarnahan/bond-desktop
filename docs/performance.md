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

A read pool is deliberately not used yet. Four `INSERT … RETURNING`
statements run through `customSelect` (two in `context_store.dart`, two in
`message_store.dart`), which a pool would send to a reader connection — the
other statements that write and return rows use `customWriteReturning` and
would be unaffected; and a read outside a transaction would stop waiting for an open
one to commit, so code that reads and then writes could act on the state from
before a transaction that today it always sees the end of.

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

- `ui-stall <ms>ms` — a 50 ms heartbeat timer runs on the UI isolate, and a
  tick can only fire when that isolate is free, so how late it fires is how
  long the isolate was blocked. A lateness of 100 ms or more gets a line.
  Every 60 seconds a summary follows, `ui-stalls 60s: n=<count> max=<ms>ms
  total=<ms>ms`, printed even when the count is zero so a quiet minute is
  visible.
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

The gates (`flutter analyze` and `flutter test`) cannot see performance. The
before and after numbers — stall count, worst stall, total, and the slowest
statements — go in the PR description.

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
