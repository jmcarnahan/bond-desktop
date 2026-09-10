# Bond quickstart

From a bare Apple Silicon Mac to the desktop inbox running against three local
model servers and signed in. Every block below is meant to be pasted as-is;
the text between blocks tells you what to expect.

This is the build-from-source path for developers. `README.md` is the
reference for everything else: the agent REPL, the benchmarks, and every
Makefile knob.

## 0. What you get, what you need

Bond runs three `llama-server` processes on this machine and never sends mail
content anywhere at inference time:

| Server | Port | Model | Download |
|---|---|---|---|
| prose (names storylines, drafts replies) | 8080 | Qwen3.8-27B Q4_K_M | ~19 GB + 0.6 GB vision projector |
| bulk (triage, extraction) | 8082 | Qwen3-4B-Instruct Q8_0 | ~4.3 GB |
| embeddings (clustering) | 8081 | EmbeddingGemma-300M | ~0.6 GB |

You need:

- **An Apple Silicon Mac.** Intel Macs are not supported.
- **Memory.** 48 GB or more is comfortable with the defaults. 32 GB works with
  a smaller context. 16 to 24 GB needs a smaller prose model. Step 2 shows the
  one-line overrides.
- **Disk.** About 30 GB free: the weights above plus the app build.
- **macOS 14 or newer** with Xcode installed. That is the Mac you build on;
  the app itself deploys back to macOS 12. Xcode 26 on macOS 15 and 26 is
  what has been tested.
- **A bond-mcps server URL** from the project owner. It never appears in this
  repository. It is the only secret-ish thing you need, and it is not a secret:
  you sign in to that server with your own login.

## 1. Toolchain

Command line tools, Homebrew, Flutter:

```sh
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask flutter
flutter doctor
flutter --version
```

`flutter --version` must say **3.47 or newer** (Dart 3.13 or newer). If
`flutter doctor` asks you to accept the Xcode license, do that and run it
again. Ignore any Android or Chrome complaints; only the macOS row matters.
There is no CocoaPods step: the macOS plugins use Swift Package Manager.

If `flutter` works in your shell but `make` later says `flutter: command not
found`, make's `/bin/sh` is not reading your shell profile. Pass the path once:

```sh
make app-run FLUTTER="$(which flutter)"
```

## 2. Clone and configure

```sh
git clone https://github.com/jmcarnahan/bond-desktop.git
cd bond-desktop
cp .env.example .env
```

Open `.env` and set the one line that matters:

```
BOND_MCP_SERVER_URL=https://<the URL you were given>/mcp
```

Leave the three `MICROSOFT_*` lines blank. They are only for "This device"
mode (see the appendix), which needs an Entra app registration you control.

**Smaller Macs.** Create a git-ignored `local.mk` next to the `Makefile` with
whichever lines apply. Nothing else in the repo needs to change:

```make
# local.mk — personal overrides, never committed
# 32 GB: keep the default models, halve the context window.
CTX_SIZE = 16384
# 16–24 GB: a smaller prose model. Its prose quality has not been benchmarked.
# MODEL_HF = ggml-org/Qwen3-8B-GGUF:Q8_0
# Ports, if something on your machine already uses one of ours.
# MODEL_PORT = 8080
# FAST_PORT  = 8082
# EMBED_PORT = 8081
```

## 3. Models and servers

```sh
make setup
make embed
make status
```

What happens:

- `make setup` installs `llama.cpp` from Homebrew, starts the prose server on
  :8080 and the bulk server on :8082, downloads their weights into
  `~/.cache/huggingface/hub/`, waits for both to answer `/health`, hashes the
  downloaded files, and runs one real completion. **The first run downloads
  about 23 GB and takes ten minutes or more.** It prints an elapsed-time line
  every 60 seconds so you can tell it is alive, and waits up to 30 minutes
  for each of the two servers.
- `make embed` starts the embeddings server on :8081. `make setup` does not
  start this one yet, and the app degrades quietly without it (no storyline
  clustering, no explanation), so do not skip it.
- `make status` should show `model`, `embed` and `fast` as `[up]` with a pid.
  A fourth row, `omlx`, is a benchmarking runtime this path never starts;
  `[down]` there is correct.

Early in the first run you will see this from `make model`, and it is not a
failure:

```
  ! model has not bound :8080 after 120s
    On the FIRST run this is EXPECTED, not a failure: llama-server
    downloads ~19GB of weights for ggml-org/Qwen3.8-27B-GGUF:Q4_K_M
    before it binds the port.
    Watch it:   make logs
    'make status' flips to [up] once loading finishes.
```

The download continues in the background; `make setup` keeps polling. Watch
progress with:

```sh
make logs
```

`make setup` is idempotent. Re-running it against servers that are already up
just re-verifies and re-smokes.

Loading the 27B takes tens of seconds on a warm machine and a couple of
minutes cold; `[up]` in `make status` means the port is bound, and the first
request may still wait for the load to finish.

## 4. Run the app

```sh
make app-install
make app-run
```

The first build takes a few minutes. The app opens on a sign-in screen:

1. Press **Sign in**. Your browser opens the bond-mcps login. Sign in there
   and come back to the app; it picks the session up on its own.
2. If your workspace has never connected a Microsoft account, a second step,
   **Connect your Microsoft account**, hands you to the platform's consent
   page. Finish it and press **I've connected — continue**.
3. The inbox syncs. Mail arrives first; the rail shows a `Triaging N
   remaining…` counter while the bulk server works through it, and storylines
   and drafts fill in over the next few minutes.

Two things you may see and can ignore:

- `Failed to foreground app; open returned 1` in the terminal on launch. The
  app launches anyway.
- A macOS notification permission prompt the first time Bond has something
  worth telling you. Allow it if you want system notifications; the setting
  is under Settings → Notifications either way.

To confirm the app sees the servers, open the avatar menu → **Settings** →
**Models** and press **Check server** on each row. All three should report
reachable with the model listed.

## 5. Day to day

The servers are independent of the app. They survive app restarts and the
weights are memory-mapped, so a second start is fast. After a reboot, or after
`make stop`, bring them back yourself; the app does not start them.

```sh
make status
make model fast embed
```

The three start one after another, and each gives up after two minutes if its
port has not bound, so on a cold cache start them one at a time.

Stop them when you need the memory back:

```sh
make stop fast-stop embed-stop
```

Rebuild the app after a `git pull`:

```sh
make app-install
make app-run
```

## 6. Troubleshooting

**A port is busy.** `make model` (and `fast`, `embed`) refuse to reuse a port
held by anything that is not a `llama-server`; they print the pid and command.
Either free the port or move ours in `local.mk` (step 2). Then point the app at
the new port: for the prose and bulk slots, Settings → Models → edit the Server
URL and Save. The embeddings URL is fixed at build time, so a moved embeddings
port means one rebuild:

```sh
make app-run EMBED_URL=http://localhost:9081/v1/embeddings
```

**Sign-in cannot start: "Port 8766 is in use".** The bond-mcps sign-in listens
on a fixed loopback port for the browser to come back to. Find the holder and
quit it, then press Sign in again:

```sh
lsof -nP -iTCP:8766 -sTCP:LISTEN
```

**"Microsoft sign-in is not configured".** The app is in "This device" mode.
Switch back to **MCP** under Settings → Microsoft connection, or see the
appendix if you meant to use a direct Microsoft connection.

**The model outputs garbage: endless `0`s, or never stops.** A corrupted
download. Every cheap check passes on it; only the hash catches it.

```sh
make verify
make stop fast-stop embed-stop
make clean-model && make setup && make embed
```

`make clean-model` refuses to run while any `llama-server` is alive, which is
why all three are stopped first.

**The model never binds, or the Mac swaps and stalls.** Not enough memory for
the model plus its context. Lower `CTX_SIZE` or choose the smaller prose model
in `local.mk` (step 2), then:

```sh
make stop && make model
```

**Nothing is being annotated.** `make status`: any server `[down]` parks the
work that needs it until it comes back. Start the missing one.

**`flutter: command not found` from make.** See the `FLUTTER=` note in step 1.

## Appendix

**Where things live**

- Weights: `~/.cache/huggingface/hub/` (shared with anything else that uses
  llama.cpp's `-hf`; `make clean-model` deletes only the prose model's directory)
- Server logs: `tmp/logs/model-<port>.log`
- App data (database, attachments, settings):
  `~/Library/Containers/com.bondinbox.app/Data/Library/Application Support/`

**Uninstall**

```sh
make stop fast-stop embed-stop
make clean-model
rm -rf ~/Library/Containers/com.bondinbox.app
```

Delete the other two model directories under `~/.cache/huggingface/hub/` by
hand if you want the space back, and `brew uninstall llama.cpp` if nothing
else uses it.

**"This device" mode (direct Microsoft Graph)**

Only for someone who holds an Entra app registration for Bond. Fill the three
`MICROSOFT_*` lines in `.env` (client id, tenant id, and, while the
registration has no public-client platform, the client secret), rebuild with
`make app-run`, and choose **This device** under Settings → Microsoft
connection. The sign-in redirect uses `localhost:8001`, which must be free.
The registration is single-tenant. Details: the "Microsoft backends" section
of `README.md`.

**Going further**

`README.md` covers the agent REPL (`make chat`), the benchmarks,
`docs/model-bakeoff.md` covers swapping models and runtimes, and
`docs/settings.md` documents every setting in the app.
