# An inference endpoint on AWS

For running the app's prose model on a rented GPU instead of this Mac: one
script stands the box up, watches it boot, tests it, opens a tunnel for the
bench harness, extends its life and tears it down. It also tests any
OpenAI-compatible endpoint you point it at. The measurements that motivated
it are in `docs/model-bakeoff.md` ("A GPU box as a target" and run matrix
row 7); this page is how to use it.

```sh
tools/inference.sh up --type g6e.xlarge --days 1     # launch, watch the boot, test
tools/inference.sh up --bulk-model Qwen/Qwen3-4B-Instruct-2507-FP8   # …with the 4B beside the 27B
tools/inference.sh restart --bulk-model …             # push a new configuration to a running box
tools/inference.sh status                             # every box, hours up, $ so far, shutdown time
tools/inference.sh tunnel                             # the local URLs for PROSE_URL / BENCH_URL
tools/inference.sh test                               # this box; or --url … --model … for any endpoint
tools/inference.sh extend --days 2                    # move the self-termination timer
tools/inference.sh down                               # terminate
tools/inference.sh persist --domain box.example.com … # always-on, TLS, an access key
tools/inference.sh --help                             # every option
```

By default a box is private to the operator: vLLM answers on the box's
loopback and an SSH tunnel is the only way in. **Persistent mode** is the
other shape, described below: one hostname, TLS, an access key, no timer.
That is the shape the app's testers point at.

## What you need

- **The AWS CLI (v2), signed in** to the account that will pay. A profile
  works: `--profile NAME` on every command. `--account 123456789012` makes the
  script refuse to run against any other account, for the day two are
  configured. The identity needs EC2 (run, describe, terminate, key pairs,
  security groups), `ssm:GetParameter` for the AMI lookup and, for the price
  column, `pricing:GetProducts`; the pricing call may fail and the script
  prints `?` instead of a price.
- **`jq`, `ssh`, `curl`, `lsof`** — all on a stock Mac with Homebrew's `jq`.
- **An SSH key.** `~/.ssh/id_ed25519` and its `.pub` by default; `--ssh-key`
  names another. The public half is imported to EC2 once per region as the
  key pair `bond-inference`.
- **A G-instance vCPU quota** in at least one region. New accounts often
  have 0; the launch then fails with a quota error rather than "no capacity".

## Standing a box up

```sh
tools/inference.sh up --type g6e.xlarge --days 1
```

What happens, in order:

1. **Region hop.** Each region in `--regions` (default `us-west-2,us-east-2,
   us-east-1`) is tried until one accepts the launch. GPU capacity is scarce
   and moves hour to hour; on 2026-09-16 every zone of us-west-2 and
   us-east-1 was empty and us-east-2 was not. `--spot` asks for a spot
   instance instead (cheaper, interruptible, same pools).
2. **Launch.** The latest Deep Learning Base AMI (Ubuntu 24.04 with the NVIDIA
   driver and Docker), a 200 GB root volume (`--disk`), a boot script that
   pulls `vllm/vllm-openai` (`--image`), downloads the model (`--model`,
   default `Qwen/Qwen3.8-27B-FP8`) and starts vLLM serving it under the alias
   `qwen3.8` (`--served-name`), which is what the Makefile's `PROSE_MODEL` and
   `BENCH_MODEL` already default to. Every GPU on the instance is used
   (`--tensor-parallel-size` is set from `nvidia-smi`). `--mtp 2` turns on the
   model's own multi-token-prediction head, the configuration the bakeoff
   recommends; `--mtp 0` for a model without one. `--max-len` (32768) and
   `--vllm-args` / `--extra-args` cover the rest.
3. **The timer.** The box runs `shutdown -h` for `--days` from boot with
   "terminate on shutdown" set, so it ends itself whether or not anyone
   remembers it. Fractions work: `--days 0.25` is six hours.
4. **Progress.** One line per change as the box boots — the instance state,
   SSH coming up, the boot stage (image pull, weights, serve), the weight
   cache growing in GB, and vLLM's own milestones (weights loaded, compile
   times, KV-cache size, startup complete). A cold boot of the 27B takes about
   16 minutes; most of it is the 30 GB image and the 29 GB of weights.
5. **The test** (below) through a fresh tunnel, then the `make` commands to
   run next, with the tunnel's URL already filled in.

A second box at the same time needs a name: `--name big --type g6e.12xlarge`.
Everything else takes `--name` to say which box it means; the default name is
`default`.

## Two slots on one card

The app runs two servers, the 27B for prose and the 4B for bulk work, and a
box can mirror that: `--bulk-model Qwen/Qwen3-4B-Instruct-2507-FP8` adds a
second vLLM container on the box's :8001, served as `qwen3-4b`
(`--bulk-served`). Each slot has its own share of the GPU. On one L40S the
27B's weights and CUDA graphs take about 34 GB, so with a bulk slot present
the prose slot drops to 80% of the card with an FP8 KV cache and a 16K
context (what `local.mk` already uses), and the bulk slot takes 16% with FP8
KV and an 8K context — a 26K-token cache, enough for eight 3K prompts in
flight, more than the local server's four slots. CUDA graphs stay on for
both: turning them off on the 4B saved a gigabyte and cost 3.5× per stream. `--mem`, `--bulk-mem`, `--max-len`, `--bulk-max-len`
and `--bulk-args` move those. The tunnel forwards both slots on adjacent
local ports and `test` checks both.

`restart` applies any of the model options to a running box without a
relaunch. Options not given keep what the box runs: the models come from the
instance's tags, so `restart --bulk-args "…"` changes only the 4B's flags, and
`--bulk-model none` drops the slot. It pushes the slot files and `/opt/bond/serve.sh` over SSH,
restarts the prose container, waits for it, starts the bulk container, and
follows the same milestones `up` shows. The weights are cached, so the 27B
is back in about eight minutes and the 4B in two. On the box,
`/opt/bond/serve.sh prose` or `… bulk` restarts one slot by hand, with any
extra vLLM flags appended.

## What the test checks

`tools/inference.sh test` runs, in order, the four things `make bench-verify`
demands of any target and two throughput reads:

| check | what passes |
|---|---|
| models | `/v1/models` lists the served name (Bedrock has no listing; the next line decides) |
| completion + usage | a plain chat completion answers with a `usage` block |
| enable_thinking=false | the answer contains no `<think>` |
| constrained json_schema | a `response_format` with an enum of three letters, asked for a fourth, answers with one of the three — decoding is constrained, not suggested |
| one stream | tokens per second for a 256-token answer |
| four streams | aggregate tokens per second with four such requests in flight |

Any endpoint can be tested the same way:

```sh
tools/inference.sh test --url http://localhost:8080 --model qwen3.8          # the local 27B
tools/inference.sh test --url https://host:port --model NAME --bearer KEY     # a keyed server
```

The script's numbers are a smoke read. The bakeoff's `make bench-prose` and
`make golden-prose` are the measurement, and `test` prints them ready to run.

## Using it from the bench harness

`tunnel` (and `up`, and `test` on a named box) opens `ssh -N -L` from a local
port to vLLM on the box and prints the URL. Local ports start at 18100 and go
up; 8000 is never used, because the local servers and MCPs live in that range.
Then:

```sh
make bench-verify-prose PROSE_URL=http://localhost:18100/v1/chat/completions PROSE_MODEL=qwen3.8 PROSE_LABEL=vllm-g6e.xlarge/Qwen3.8-27B-FP8
make bench-prose        PROSE_URL=… PROSE_MODEL=qwen3.8 PROSE_LABEL=…
make golden-prose       PROSE_URL=… PROSE_MODEL=qwen3.8 PROSE_LABEL=…
```

and, for the bulk slot (the next port up), the same three as `BENCH_URL` /
`BENCH_MODEL=qwen3-4b` / `BENCH_LABEL` on `make bench`, `make drain` and
`make golden`. The tunnel dies when this Mac sleeps or the
terminal closes; `tunnel` reopens it. The harness prices a localhost URL at
$0.00, so a ledger row from a box is priced by hand at the instance's hourly
rate: `1000 / (msgs_per_min × 60) × $/h`.

## Persistent mode

A persistent box is always on and reachable at one hostname over TLS, by
anyone who has the access key. No tunnel, no timer. Giving `--domain` is what
makes a box persistent: an endpoint the app points at must not walk away
mid-session, so the self-termination timer is left off. `--persistent` on its
own does the same for a box with no hostname. Either build one that way:

```sh
tools/inference.sh up --domain box.example.com \
  --route53-zone ZONEID --api-key-file ~/.bond/box.key --acme-email you@example.com \
  --bulk-model Qwen/Qwen3-4B-Instruct-2507-FP8
```

or convert a box that is already running and serving:

```sh
tools/inference.sh persist --domain box.example.com \
  --route53-zone ZONEID --api-key-file ~/.bond/box.key --acme-email you@example.com
```

What that builds:

- **The front door.** Caddy runs on the box in host networking mode and holds
  443 and 80. Requests under `/prose/` go to the 27B on the box's loopback
  :8000 and requests under `/bulk/` to the 4B on :8001, with the prefix
  stripped, so vLLM sees the plain `/v1/…` paths it expects. Both proxies set
  `flush_interval -1`, which turns response buffering off. Drafts stream as
  server-sent events, and a buffering proxy would hold every token back until
  the answer was finished. Any other path answers `bond inference` with a 200.
- **The certificate.** Let's Encrypt, ordered by Caddy the first time it
  starts. Port 80 is open because that is where the HTTP-01 challenge lands.
  `--acme-email` is the address Let's Encrypt sends expiry notices to. The
  account key and the certificate live in `/opt/bond/caddy/data`, mounted into
  the container, so a restart or a stop and start reuses them instead of
  ordering again. Five certificates per hostname per week is the limit, which
  is why the script waits for DNS rather than letting an order fail.
- **The access key.** `--api-key-file` names a file holding the key, mode 600.
  `--api-key` takes it on the command line instead, which puts it in your
  shell history. The key travels over ssh standard input, never as an
  argument, and lands in `/opt/bond/api.env` at mode 600. vLLM reads it as
  `VLLM_API_KEY` through `--env-file`, so it appears in no process listing on
  the box. It is still readable in `docker inspect` under `.Config.Env`, on a
  box only the operator can reach. Both slots check it.
- **The address and the record.** An Elastic IP is allocated, tagged for the
  box's name and associated with it, so the hostname stays true across a stop
  and a start. With `--route53-zone` the script writes the A record itself at
  TTL 60. Without one it prints the record for you to create. Either way it
  polls `dig` until the name answers with that address, for up to ten minutes,
  and stops rather than letting Caddy ask for a certificate for a name that
  does not resolve yet.

`persist` does all of that to a running box, in this order: cancel the
shutdown timer, tag the instance, attach a second security group
`bond-inference-web` carrying 443 and 80, close any open tunnel, allocate and
associate the Elastic IP, write and wait for the A record, push the key,
restart both slots so they read it, check the Caddyfile with `caddy validate`
and only then start Caddy, confirm the container is still running a moment
later, wait for `https://box.example.com/` to answer 200 so the certificate is
really in place, and run the same checks through the new hostname with the
key. The public address changes when the
Elastic IP is attached, so an open tunnel dies at that point and `tunnel`
reopens it against the new one.

`extend` refuses on a persistent box, because there is no timer to move.
`down` is what ends one, and it releases the Elastic IP as it goes, because an
address held but attached to nothing is billed by the hour. `--keep-ip` holds
it for the next box. `status` prints `persistent` in the shutdown column and
the hostname beside the models.

The two URLs the app wants:

```
https://box.example.com/prose/v1/chat/completions   model qwen3.8
https://box.example.com/bulk/v1/chat/completions    model qwen3-4b
```

`BOND_BOX_URL=https://box.example.com` in `.env` fills in both addresses under
**User defined**. The key is typed into the app and kept in the keychain. From a
terminal:

```sh
tools/inference.sh test --url https://box.example.com/prose --bearer KEY --model qwen3.8
tools/inference.sh test --url https://box.example.com/bulk --bearer KEY --model qwen3-4b
curl -s -o /dev/null -w '%{http_code}\n' https://box.example.com/prose/v1/models
```

The last line sends no key and must answer 401. That is the check that the key
is enforced rather than merely accepted.

## Security

- vLLM listens on the box's loopback only, on 8000 and 8001. On a tunnelled
  box nothing but SSH answers on the public address. On a persistent box Caddy
  is the only other listener, on 443 and 80, and all it does is forward to
  those two loopback ports.
- SSH is allowed from the caller's current public IP alone, in a security
  group named `bond-inference-ssh`. The IP is re-allowed on every command
  that connects, because home IPs move. The first spike box went unreachable
  overnight for exactly that reason. Persistent mode does not widen port 22:
  the second group `bond-inference-web` carries 443 and 80 and nothing else.
- On a tunnelled box there is no access key, and the tunnel is the credential.
  Anyone who can SSH to the box can reach the model and nobody else can.
- On a persistent box the access key is the credential. Both slots answer 401
  without it. Rotate it by running `persist` again with a new key file, which
  rewrites `/opt/bond/api.env` and restarts both slots. The key belongs in no
  committed file. It lives in a 600 file on this Mac, in the app's keychain
  entry, and in `.env` for the bench recipes, and all three are outside git.
- Prompts carrying mail content cross the internet to a persistent box, under
  TLS, to an EC2 instance the owner of the install rents and runs. It is not a
  third-party model vendor, which is why the app does not treat the box as one
  and asks for no cloud consent before sending to it.
- The box holds nothing but public model weights and the key file. Nothing
  from the mailbox is stored on it. Prompts pass through vLLM's memory, vLLM
  logs no prompt text at its default level, and the Caddyfile turns on no
  access log.

## Cost, and what is left behind

- A `g6e.xlarge` (one L40S, 48 GB) was $1.86 an hour on-demand in September
  2026; `status` shows each box's hours and dollars so far. The root volume
  is deleted with the instance.
- **A persistent box is billed for every hour of the month.** At $1.86 an hour
  on demand that is about $1,360 a month, and nothing stops it but `down`.
  A timed box that ends itself is the cheaper shape for a measurement run;
  persistent mode is for the shared endpoint testers point at.
- An Elastic IP costs nothing while it is attached to a running instance and
  is billed by the hour when it is not, which is why `down` releases it unless
  `--keep-ip` says to hold it.
- `down` terminates the instance. The key pair and both security groups stay
  in each region the script has touched; all of them are free.
- The script keeps `tmp/inference/<name>.env` (git-ignored) as a cache of
  region, instance id, tunnel, hostname and Elastic IP allocation; the tags on
  the instance are the truth, so `status`, `test`, `persist` and `down` work
  from any clone.

## When something is off

- **`ssh to … failed`** on `test` / `tunnel` right after a network change:
  run the same command again — it re-allows the new IP, and the first attempt
  raced the rule.
- **`no region in […] had … capacity`**: wait, try `--spot`, add regions, or a
  neighbouring size (`g6e.2xlarge` is the same single GPU with more CPU).
- **`the vLLM container exited`**: on the box, `docker logs vllm`. Out of
  GPU memory means a smaller `--max-len` or a smaller model; a rejected flag
  means `--vllm-args` needs changing for that model. `/opt/bond/serve.sh`
  restarts the container with extra flags appended. vLLM 0.29 takes its
  `*-config` flags as JSON, not `key=value`:
  `--structured-outputs-config '{"backend":"guidance"}'` starts,
  `--structured-outputs-config backend=guidance` exits with a pydantic
  `Invalid JSON` error.
- **A container exits during `restart` or `up`** with `ValueError: To serve
  at least one request with the model's max seq len …`: that slot's share of
  the card does not hold its weights plus one full-context KV cache. The 27B
  with MTP needs 80% of an L40S for a 16K context (at 72% it had 0.38 GiB
  left against the 1.19 GiB needed); lower `--max-len`, raise `--mem`, or
  shrink the other slot. `docker logs vllm-prose` / `vllm-bulk` on the box
  has the numbers.
- **The box vanished**: its timer ran out. `status` shows the shutdown time;
  `extend --days N` moves it.
- **`… still does not resolve to …` after ten minutes**: the A record is
  missing or points somewhere else. Fix it, then resume with `persist`, not
  with `up`: the instance exists by then, so `up` would only say the box is
  already running. Nothing was lost. The key, the groups and the Elastic IP
  are already in place and `persist` picks up where the first run stopped.
- **The certificate never arrives.** On the box, `docker logs caddy`. Port 80
  must be reachable for the HTTP-01 challenge, and the name must already
  resolve. To exercise the plumbing without spending a real certificate, put
  `acme_ca https://acme-staging-v02.api.letsencrypt.org/directory` in the
  Caddyfile's global block, then take it out for the real one. Five
  certificates per hostname per week, and failed orders count against a
  tighter limit.
