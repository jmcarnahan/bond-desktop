# Installing Bond

For someone who wants to *use* Bond on their Mac. There is no toolchain here,
nothing to compile, and nothing to type in a terminal. If you are building
from source instead, read [QUICKSTART.md](../QUICKSTART.md).

## What you need

- **An Apple silicon Mac** — M1 or newer. Intel Macs are not supported at all:
  the app is built for Apple silicon only, so on an Intel Mac the disk image
  opens and macOS then refuses to open Bond itself. There is nothing to click
  past and no setup screen to reach.
- **macOS 12 or newer.**
- **About 35 GB free.** The models are ~22 GB; the rest is room for macOS to
  load them.
- **A Bond workspace login.** The same one you would use for anything else on
  your team's Bond server. If you do not have one, ask whoever runs it.

Memory matters for one of the three models. 32 GB or more runs everything
comfortably; on 16 GB the inbox works — reading, sorting, search — and the
model that writes drafts will be slow. Bond tells you which case you are in.

## Getting the app

1. Open the **Releases** page of the `bond-desktop` repository on GitHub.
2. Download the `.dmg` from the newest release.
3. Open it and drag **Bond Desktop** into your **Applications** folder.
4. Eject the disk image and open Bond from Applications. The app is **Bond
   Desktop** in Finder; the window it opens is titled **Bond Inbox**.

### "Bond Desktop can't be opened"

You should not see this. Released builds are checked and approved by Apple
before they are published, so Bond opens on the first double-click with no
warning and nothing to click past.

If you do see it, you have a **test build** — one sent to you directly, before
release, by someone who will have said so. Those are not sent to Apple, and
macOS blocks anything it has not been told about. It is one detour, once:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the bottom. There is a line about Bond Desktop being blocked, with
   an **Open Anyway** button beside it.
3. Press it, then confirm in the dialog macOS puts up.

macOS remembers, so this happens on the first launch of that build and never
again.

## Setting up

The first launch opens a setup flow. Nine screens, a counter in the corner,
and a back arrow that is on every one of them — grey and unpressable on the
first, because there is nothing behind it.

1. **Welcome to Bond** — what Bond does and what setup costs. If you had an
   older version of Bond on this Mac, this screen also tells you whether your
   mailbox came across. Press **Get started**.
2. **Your Mac** — the chip, the memory and the macOS version Bond found, and
   whether the models will run here. Too little memory for the writing model
   is a warning, not a refusal. (An Intel Mac never gets this far — macOS will
   not open the app there in the first place.)
3. **Where the models run** — two cards. **GPU server · recommended** is
   already chosen when your build came with the project's server address, and
   the address is filled in. Paste the access key you were given, press
   **Check server**, and two lines answer, one for the writing model and one
   for the inbox model. **Continue** keeps the key in the macOS keychain and
   nowhere else. **This Mac** is the other card: everything runs here and
   nothing leaves the machine, at the cost of the larger download on the next
   screens. On the GPU server only the embedding model is downloaded, because
   it always runs on this Mac.
4. **Models** — the models this Mac will download, what each one does, how
   big it is, and the licence it comes under. Three on This Mac, one on the
   GPU server. Nothing downloads yet.
5. **Storage** — where the weights will go, and whether they fit. **Change
   folder…** puts them somewhere else — an external disk, for instance. If
   there is not enough room, Bond says how much more it needs and will not
   continue until there is. Bond also tries writing a file there while you
   look at the screen: a folder it cannot write to — a read-only disk, or one
   belonging to another account — says `Bond can't write to this folder.
   Choose another one.` and is not a folder it will go on from.
6. **Download** — one progress bar per model, smallest first, with a rate and
   an estimate. **You can quit.** Closing Bond mid-download is safe: the next
   launch comes back to this screen and picks up the same file where it
   stopped. **Continue** waits for every bar, because Bond's model server
   will not start with a file missing.
7. **Sign in** — your browser opens on the Bond login. Sign in there and come
   back; Bond picks the session up on its own. If your workspace has never
   connected a Microsoft account, there is one more step in the browser and a
   button here to continue once you have finished it.
8. **Notifications** — macOS asks whether Bond may notify you when a message
   needs your attention. Saying yes moves on. Saying no keeps you on this
   screen once, with an **Open System Settings** button for changing your mind;
   the next **Continue** moves on.
9. **All set** — what was set up, said back. **Finish** turns Bond's own model
   server on and opens the inbox.

The models take a minute or two to load the first time. The inbox is readable
while that happens; the reading and sorting fill in behind it. Processing is
on from the start, and the switch that pauses it is at the top of the sidebar
and under **Settings → Processing**. Bond remembers where you left it.

## Where things live

Everything Bond keeps is under one folder:

`~/Library/Application Support/com.bondinbox.app/`

| | |
|---|---|
| `bond_inbox.db` | your mail, your storylines, your drafts and every setting |
| `models/` | the three model files — this is the big one, ~22 GB |
| `logs/llama-server.log` | what the model server printed, when something goes wrong |
| `servers/` | the model server's configuration and the file that lets Bond clean up after itself |

To open that folder: in Finder, **Go → Go to Folder…**, and paste the path.

If you pointed the setup at a different models folder, the weights are there
instead and everything else is still here.

## Changing things later

Everything the setup asked is under **Settings → Models**, from the avatar
menu at the top of the inbox. The page asks one question, where the models
run, and answers it with the same form the setup used:

- **GPU server · recommended** — the address and the access key. The key
  field is empty on purpose once a key is stored; typing replaces it. **Check
  server** asks both models. **Save** moves the work there.
- **This Mac** — **Use this Mac** moves the work back here. Under it sits the
  Local server card, and everything below is about that server:
- **Bond runs the model server** — off puts Bond back to expecting servers
  started by hand, which is a developer's setup rather than yours.
- **Port** — change it if something else on your Mac already uses 8080.
  **Pick a free port** finds one for you. Saving restarts the server.
- **Models folder** — move the weights to another disk. Bond restarts the
  server pointed at the new place; it does not move the files for you.
- **Set up again** — runs the whole flow from the top. It keeps what is
  expensive and still true: the models stay on disk and you stay signed in, so
  those two screens are a **Continue** each. It is not a commitment: the first
  screen carries **Back to the inbox**, which puts you back exactly where you
  were. If a download is running it keeps running either way.

Three lines under the form say which model answers for each role, the big
model, the small model and embeddings, each with its own **Check**. Anything
finer, the per-step picks and extra servers, is behind **Advanced** at the
bottom of the page.

## Uninstalling

1. Quit Bond.
2. Drag **Bond Desktop** from Applications to the Trash.
3. Delete `~/Library/Application Support/com.bondinbox.app/` — this is what
   frees the 22 GB.
4. Open **Keychain Access**, search for `bond`, and delete the login items
   named after the app. That is the stored sign-in.

If you chose a different models folder during setup, delete that too.
