# Bond quickstart

From a bare Apple Silicon Mac to the desktop inbox, signed in and sorting
mail. You run the app from this checkout: there is no installer step. Every
block below is meant to be pasted as-is; the text between blocks tells you
what to expect.

`README.md` is the reference for everything else: the agent REPL, the
benchmarks, and every Makefile knob.

## 0. What you get, what you need

Bond uses three models, one per role. A new environment starts like this:

| | Default | Where it comes from | Change it |
|---|---|---|---|
| **AI processing** | off | | the **AI processing** switch in the sidebar, or Settings, Processing |
| **Decision model** (sorts and flags every message, judges storylines) | ModernBERT v3 swap, on this Mac, about 0.8 GB | downloaded from your model registry when it is not on disk | Settings, Models |
| **Generative model** (summaries, storyline titles and recaps, drafts) | Qwen3.8 27B on **Your server** | the server address and access key in `local.mk` | Settings, Models |
| **Embeddings** (clustering, search) | Qwen3-Embedding-0.6B, on this Mac, about 0.6 GB | downloaded from Hugging Face | always this Mac |

So this Mac downloads about 1.4 GB, and the large model stays on the server.
Mail content goes to no model server you have not named.

You need:

- **An Apple Silicon Mac.** Intel Macs are not supported. 16 GB of memory is
  enough for this setup. Running the generative model on this Mac instead is
  Appendix B.
- **About 5 GB of free disk**: the two models plus the app build.
- **macOS 14 or newer** with Xcode installed. Xcode 26 on macOS 15 and 26 is
  what has been tested.
- **Five values from the project owner.** None of them appears in this
  repository:
  1. the bond-mcps server URL (you sign in to it with your own login);
  2. the model registry address;
  3. a READ token for that registry;
  4. your server's address, which is the GPU box that runs the 27B;
  5. your server's access key.

## 1. Toolchain

Command line tools, Homebrew, Flutter, and the model runtime:

```sh
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask flutter
brew install llama.cpp
flutter doctor
flutter --version
```

`flutter --version` must say **3.47 or newer** (Dart 3.13 or newer). If
`flutter doctor` asks you to accept the Xcode license, do that and run it
again. Ignore any Android or Chrome complaints; only the macOS row matters.
There is no CocoaPods step: the macOS plugins use Swift Package Manager.

`llama.cpp` is needed even though the large model runs on your server: the
app runs one `llama-server` of its own for the decision and embedding models.
A Homebrew install is found without any configuration.

## 2. Clone and configure

```sh
git clone https://github.com/jmcarnahan/bond-desktop.git
cd bond-desktop
cp .env.example .env
cp local.mk.example local.mk
```

Both copies are git-ignored. Never commit either one.

**`.env`** takes one line. Leave the `MICROSOFT_*` lines blank (they are only
for "This device" mode, Appendix C):

```
BOND_MCP_SERVER_URL=https://<the URL you were given>/mcp
```

**`local.mk`** takes four lines. It is the one place an environment is
configured:

```make
BOND_REGISTRY_URL = https://artifactory.example.com/artifactory/bond-models
BOND_REGISTRY_TOKEN = <the registry read token>
BOND_BOX_URL = https://box.example.com
BOND_BOX_KEY = <the server access key>
```

- `BOND_REGISTRY_URL` is the repository URL, with nothing after the
  repository name. Use the https address when your registry has one.
- `BOND_BOX_URL` is the server's origin, with no path. The app adds
  `/prose/v1/chat/completions` itself.
- Write each value with a plain `=` and no comment after it on the same
  line. `local.mk.example` explains why, and how to write a `$` or a `#`.

Each of the four is a default the app is built with. All of them can be
changed later in the app (step 5). The token and the key are compiled only
into a build made from this checkout, and `make -n` never prints them.

Now check the environment before the first build:

```sh
make app-doctor
```

It prints one line per check and exits non-zero when any fails:

| Line | Means |
|---|---|
| `✓ Flutter 3.47…` | the toolchain is found |
| `✓ llama-server at …` | the model runtime is found |
| `✓ BOND_MCP_SERVER_URL is set in …/.env` | sign-in has a server to talk to |
| `✓ the registry has bond-decide-mbl-v3swap` | the address and token work and the decision model is there |
| `✓ your server answers at …` | the address and key work |

A `✗` names what is wrong: a value that is not set, a refused token or key
(`HTTP 401` or `403`), a registry address that answers with a web page, a
redirect or `HTTP 404`, or an address that does not answer. It prints status
codes only, never a token or a key. Fix `local.mk` and run it again until
every line is a `✓`.

## 3. Run the app

```sh
make app-install
make app-run
```

The first build takes a few minutes. The first launch opens the setup wizard,
nine screens:

1. **Welcome to Bond.** Press **Get started**.
2. **Your Mac.** The chip, the memory, and which models this Mac takes.
3. **Where the models run.** Two questions. The **Decision model** opens on
   **This Mac · recommended**: leave it. The **Generative model** opens on
   **Your server · recommended** with the address from `local.mk` filled in
   and the hint `Using the key from this build. Type to replace` in the key
   field. Press **Continue**: the app asks the server which model it serves
   and takes the name it lists.
4. **Models.** The two downloads and their sizes.
5. **Storage.** Where the models are kept. The default is fine.
6. **Download.** Two bars, about 1.4 GB together. **Continue** waits for the
   embedding model only. If the decision model's bar fails it says why, adds
   `Bond tries again after setup, and under Settings, Models. You can
   continue.`, and does not hold you here (step 6 below has the fixes).
7. **Sign in.** Your browser opens the bond-mcps login. Sign in there and
   come back to the app; it picks the session up on its own. If your
   workspace has never connected a Microsoft account, a second step hands you
   to the consent page.
8. **Notifications.** Your choice.
9. **All set.** Press **Finish**.

The inbox opens and mail syncs. Nothing is sorted or summarised yet: AI
processing is off until you turn it on (step 4).

**Skipping the wizard.** On a machine that has been set up before, add this
to `local.mk` and rebuild. The app goes straight to sign-in, and the models
this setup needs still download in the background:

```make
BOND_DEV_SKIP_SETUP = 1
```

Two things you may see and can ignore: `Failed to foreground app; open
returned 1` in the terminal on launch, and a macOS notification permission
prompt the first time Bond has something worth telling you.

## 4. Turn AI processing on

It starts off on purpose, so you can look before any mail is sent to a model.

1. Open the avatar menu, then **Settings**, then **Models**. The first line
   is about Bond's own model server on this Mac, and says processing is off.
   Under it are four blocks:
   - **Decision model**: This Mac, on disk and loaded. While it is still
     arriving the line reads `Downloading NN%`.
   - **Generative model**: Your server, with your address and the model name
     the server reported.
   - **Embeddings**: on this Mac.
   - **Model registry**: your address. Press **Check**; it should answer
     `Registry reachable.`
2. Switch **AI processing** on in the sidebar.

Mail is sorted first; the rail shows a `Triaging N remaining…` counter while
the decision model works through it (a fraction of a second a message).
Summaries fill in behind it from the generative model, and storylines and
drafts over the next few minutes.

Switching it off again stops new work at once and keeps everything already
done.

## 5. Changing things later

Everything in `local.mk` has a field under **Settings, Models**:

| `local.mk` | In the app |
|---|---|
| `BOND_REGISTRY_URL`, `BOND_REGISTRY_TOKEN` | **Model registry**: address, access token, **Save**, **Remove token**, **Check** |
| `BOND_BOX_URL`, `BOND_BOX_KEY` | **Generative model**, Your server: address, access key, **Remove key** |

- A value saved in the app wins over `local.mk`, on this Mac only.
- **Remove token** and **Remove key** return to the value from `local.mk`.
- A key or token typed in the app is kept in the macOS keychain and shown
  nowhere. The one from `local.mk` is only ever sent to the address from
  `local.mk`: type a different host and you type its key too.
- Each role can be moved between **This Mac** and **Your server** there.
  Moving a role to this Mac downloads its model; each block has a
  **Download** button and says `Not downloaded yet.` until it has landed.
- A changed `local.mk` takes effect on the next `make app-run`.
- **Set up again**, at the foot of the page, re-runs the wizard. It keeps the
  models on disk and the signed-in session.

After a `git pull`, rebuild:

```sh
make app-install
make app-run
```

## 6. Troubleshooting

Start with `make app-doctor`. It finds most of these before the app does.

**"The model registry has no address. Add one under Settings, Models."**
`BOND_REGISTRY_URL` was empty when the app was built. Add it to `local.mk`
and rebuild, or type it under Settings, Models and press **Save**.

**"The model registry refused the access token."** The token is wrong, has
expired, or cannot read this repository. Replace it in `local.mk` and
rebuild, or type the new one under Settings, Models. If you once typed a
token in the app, that one is still winning: **Remove token** goes back to
the one in `local.mk`.

**"The model registry does not have this model. Check its address."** The
address reaches a registry but not the repository that holds the decision
model. It should end at the repository name, for example
`…/artifactory/bond-models`.

**"The model registry answered with a web page, not a model. Check its
address."** The address reaches a login page or a proxy. An http address
that the server upgrades to https also loses the token on the way: use the
https address.

**"The decision model is not downloaded yet. Open Settings, Models."** New
mail waits at triage until the decision model is on disk. Settings, Models
gives the reason under the Decision model and a **Download** button; once the
registry answers, press it. `Download again` appears when a file on disk does
not match what the app expects, and replaces it.

**"The generative model has no server address. Add one under Settings,
Models."** `BOND_BOX_URL` was empty when the app was built and no address has
been typed. Summaries and drafts wait; the app does not fall back to a model
on this Mac by itself. Add the address, or choose **This Mac** (Appendix B).

**The server refuses the key.** Settings, Models says so under the
Generative model. Replace `BOND_BOX_KEY` and rebuild, or type the key there.
A key typed in the app wins until you press **Remove key**.

**"The model runtime is missing from this build".** `llama-server` was not
found when the app was built. `brew install llama.cpp`, or set
`BOND_LLAMA_SERVER` in `local.mk` to a binary elsewhere, then rebuild.

**"Bond's model server is starting or stopped. See Settings, Models".** The
app's own server takes a few seconds after launch and restarts when a model
lands. If it stays that way, the log is
`~/Library/Application Support/com.bondinbox.app/logs/llama-server.log`.

**Nothing is being sorted or summarised.** AI processing is off (step 4). If
it is on, the rail says which model the work is waiting for.

**`flutter: command not found` from make.** Make's `/bin/sh` is not reading
your shell profile. Pass the path once, or put `FLUTTER = /path/to/flutter`
in `local.mk`:

```sh
make app-run FLUTTER="$(which flutter)"
```

**Sign-in cannot start: "Port 8766 is in use".** Rare, and only against a
server that offers no client registration. Find the holder, quit it, and
press Sign in again:

```sh
lsof -nP -iTCP:8766 -sTCP:LISTEN
```

**"Microsoft sign-in is not configured".** The app is in "This device" mode.
Switch back to **MCP** under Settings, Microsoft connection.

## Appendix A: a model registry on this Mac

The model registry is a JFrog Artifactory generic repository. The app reads
two files from it, each checked against a sha256 pinned in the app:

```
<BOND_REGISTRY_URL>/bundles/bond-decide-mbl-v3swap/model-f16.gguf
<BOND_REGISTRY_URL>/bundles/bond-decide-mbl-v3swap/heads.json
```

Where there is no shared registry, a local Artifactory in Docker stands in
for it. It is not part of this repository: the training project keeps its
compose file and publishes the bundle into it. Once it is up:

```make
BOND_REGISTRY_URL = http://localhost:18082/artifactory/bond-models
```

- Bring it up with `docker compose up -d` in its folder before `make
  app-doctor` or the first launch. When it is down the decision model cannot
  download; a model already on disk keeps working.
- It refuses anonymous reads, so `BOND_REGISTRY_TOKEN` is still needed.
- **Use a read token, not the admin one.** The token is compiled into your
  build. Mint a token scoped to read this one repository and put that in
  `local.mk`.

## Appendix B: models on this Mac

**The generative model on this Mac.** Settings, Models, **Generative model**,
**This Mac**, or the same card on the wizard's third screen. A Mac with
40 GiB of memory or more runs the 27B (about a 19 GB download); a smaller one
runs the 4B (about 4 GB). With every role on this Mac nothing leaves the
machine, and `BOND_BOX_URL` and `BOND_BOX_KEY` can stay empty; `make
app-doctor` will then show a `✗` on those two lines, which is expected.

**The decision model on your server.** Settings, Models, **Decision model**,
**Your server**. A ModernBERT server returns vectors and the app applies the
heads file here, so this Mac still downloads the decision model's files. The
server must serve the same v3 swap model the app pins:
`docs/inference-endpoint.md`.

**Servers you start by hand.** For bench work, or to keep models loaded
across app restarts:

```make
# local.mk
BOND_DEV_HAND_SERVERS = 1
BOND_DEV_SKIP_SETUP = 1
```

```sh
make decide-fetch
make decide embed
make status
```

`make decide-fetch` downloads the decision model from the registry into the
same folder the app uses, sha-checked, so a model the app has already
downloaded needs no fetch. `make decide` serves it on :8083 and `make embed`
serves embeddings on :8081. `make setup` adds the 27B on :8080 and the
bench-only 4B on :8082 (about 23 GB of downloads into
`~/.cache/huggingface/hub/`), for a generative model on this Mac: set the
Generative model to **This Mac** too, or the app keeps using your server. With `BOND_DEV_HAND_SERVERS = 1` the app uses those ports and starts no
server of its own; after a reboot you bring them back yourself. Stop them
with `make stop fast-stop embed-stop decide-stop`. Ports, context size and
model overrides are in `README.md`.

## Appendix C: everything else

**A sample mailbox.** `BOND_SAMPLE_DIR = /absolute/path/to/sample-v2` in
`local.mk`, then `make app-run`, serves a recorded sample directory instead
of Microsoft. Every stage after the backend runs as it does on a real
account.

- It is read-only: send, drafts and chat writes refuse with a sentence that
  says "sandbox".
- It uses its own database file, `bond_inbox-sample.db`. Remove the line and
  rebuild to go back.
- A fresh file means fresh settings: the wizard shows unless
  `BOND_DEV_SKIP_SETUP = 1` is set too.
- The default lookback is one day and a recording ends on a fixed date, so
  the first sync finds nothing. Set the window under Settings, Sync & data,
  press **Forget everything and re-sync** once with AI processing off, then
  turn AI processing on. Widening without that step ingests the sample as
  quiet backfill and every thread reads Waiting.
- Teams is pulled with **Refresh**.
- The path must be absolute. The sample is real mail: nothing from it goes
  into the repo.

**Where things live**

- Models the app downloads:
  `~/Library/Application Support/com.bondinbox.app/models/`, or the folder
  chosen on the wizard's Storage step. The decision model is in
  `artifactory_bond-decide-mbl-v3swap/` there.
- App data (database, attachments, settings):
  `~/Library/Application Support/com.bondinbox.app/`
- The app's own server: its log is `logs/llama-server.log` and its files are
  in `servers/`, both under the app data folder.
- Hand-started servers: logs in `tmp/logs/model-<port>.log`, weights in
  `~/.cache/huggingface/hub/`.
- An older checkout installed the decision model by hand into
  `models/local_bond-decide/`. Nothing reads that folder now; delete it to
  get about 0.8 GB back.

**Uninstall**

```sh
rm -rf ~/Library/Application\ Support/com.bondinbox.app
rm -rf ~/Library/Containers/com.bondinbox.app   # only if an older build ran here
```

If you ran servers by hand: `make stop fast-stop embed-stop decide-stop`,
`make clean-model`, and delete what is left under
`~/.cache/huggingface/hub/`. `brew uninstall llama.cpp` if nothing else uses
it.

**"This device" mode (direct Microsoft Graph).** Only for someone who holds
an Entra app registration for Bond. Fill the three `MICROSOFT_*` lines in
`.env`, rebuild, and choose **This device** under Settings, Microsoft
connection. The sign-in redirect uses `localhost:8001`, which must be free.
Details: the "Microsoft backends" section of `README.md`.

**Going further.** `README.md` covers the agent REPL (`make chat`) and the
benchmarks. `docs/settings.md` documents every setting in the app.
`docs/model-bakeoff.md` covers swapping models and runtimes.
`docs/inference-endpoint.md` covers running the generative model on a rented
AWS GPU (`tools/inference.sh`). `docs/install.md` is the guide for the
installer build, which is not how the app is shared yet.
