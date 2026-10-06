# Installing Bond

> **This is the guide for the installer build, which is not how Bond is
> shared yet.** To run Bond today, follow [QUICKSTART.md](../QUICKSTART.md):
> you run the app from the repository with `make app-run`.

For someone who wants to *use* Bond on their Mac. There is no toolchain here,
nothing to compile, and nothing to type in a terminal. If you are building
from source instead, read [QUICKSTART.md](../QUICKSTART.md).

## What you need

- **An Apple silicon Mac** — M1 or newer. Intel Macs are not supported at all:
  the app is built for Apple silicon only, so on an Intel Mac the disk image
  opens and macOS then refuses to open Bond itself. There is nothing to click
  past and no setup screen to reach.
- **macOS 12 or newer.**
- **About 5 GB free.** With the generative model on your server, this Mac
  downloads about 1.4 GB. Running the generative model on this Mac instead
  adds about 19 GB, so plan on about 35 GB free for that.
- **A Bond workspace login.** The same one you would use for anything else on
  your team's Bond server. If you do not have one, ask whoever runs it.
- **Four values from whoever runs your Bond setup.** An installer build
  carries none of them, so you type them into the app: the model registry
  address and its access token, and your server's address and its access key.

Memory matters only for the generative model, and only when it runs on this
Mac. With it on your server, 16 GB is enough. On this Mac, 40 GB or more runs
the 27B, and a smaller Mac runs the 4B. Bond tells you which case you are in.

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
3. **Where the models run** — two questions, each with two cards: **This
   Mac** and **Your server**. The **Decision model** opens on **This Mac ·
   recommended**: Bond downloads it from your model registry and runs it
   here. The **Generative model** opens on **Your server · recommended**, with
   a short form: **Generative model address** and **Access key**. Type the
   address and key you were given. **Continue** checks the server, takes the
   model name it lists, and keeps the key in the macOS keychain and nowhere
   else. Choosing **This Mac** for the generative model downloads it and runs
   it here instead, and nothing leaves the machine, at the cost of about
   19 GB more on the next screens. The embedding model always runs on this
   Mac.
4. **Models** — the models this Mac will download, what each one does, how
   big it is, and the licence it comes under. Nothing downloads yet.
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
   stopped. **Continue** waits for the embedding model and any model being
   downloaded from Hugging Face. The embedding model, and the decision model
   when it runs on this Mac, come from your model registry, and an installer
   build has no registry address yet, so their bars say `The model registry
   has no address. Add it below.` and the step shows the **Model registry**
   fields: type the address and the access token and press **Save**, and the
   download starts again, from where it stopped. The fields stay on the step
   whenever a registry download has failed, for any reason: a mistyped
   address can also fail as `The connection dropped too many times. Check the
   network and try again.`, and is fixed in the same fields. The decision
   model's bar also says `Bond tries again after setup, and under
   Settings, Models. You can continue.` It does not hold you here; the
   embedding model does, until it is downloaded.
7. **Sign in** — your browser opens on the Bond login. Sign in there and come
   back; Bond picks the session up on its own. If your workspace has never
   connected a Microsoft account, there is one more step in the browser and a
   button here to continue once you have finished it.
8. **Notifications** — macOS asks whether Bond may notify you when a message
   needs your attention. Saying yes moves on. Saying no keeps you on this
   screen once, with an **Open System Settings** button for changing your mind;
   the next **Continue** moves on.
9. **All set** — what was set up, said back. **Finish** starts Bond's own
   model server and opens the inbox.

The inbox opens and mail syncs, but nothing is sorted or summarised yet. AI
processing starts off, so you can finish setting up before any mail goes to a
model:

1. Open **Settings → Models** from the avatar menu at the top of the inbox.
2. Under **Model registry**, check what you entered on the Download step:
   the **Registry address** is there and the token field hints `Stored. Type
   to replace`. Press **Check**; it should say `Registry reachable.` If the
   decision model's bar had failed, the Decision model block offers
   **Download**, and shows `Downloading NN%` until it lands.
3. Switch **AI processing** on, at the top of the sidebar or under
   **Settings → Processing**. Bond remembers where you left it.

## Where things live

Everything Bond keeps is under one folder:

`~/Library/Application Support/com.bondinbox.app/`

| | |
|---|---|
| `bond_inbox.db` | your mail, your storylines, your drafts and every setting |
| `models/` | the model files: about 1.4 GB, or about 21 GB with the generative model on this Mac |
| `logs/llama-server.log` | what the model server printed, when something goes wrong |
| `servers/` | the model server's configuration and the file that lets Bond clean up after itself |

To open that folder: in Finder, **Go → Go to Folder…**, and paste the path.

If you pointed the setup at a different models folder, the weights are there
instead and everything else is still here.

## Changing things later

Everything the setup asked is under **Settings → Models**, from the avatar
menu at the top of the inbox. The page opens with one line about Bond's own
model server on this Mac; **Show log** appears there only when the server has
failed, and hands the log to the Mac's own viewer. Under it are four blocks:

- **Decision model** and **Generative model** each choose **This Mac** or
  **Your server**. On This Mac the block names the model with its size and
  whether it is on disk and loaded, with a **Download** button while it is
  `Not downloaded yet.` Choosing This Mac for a role downloads its model.
  On Your server the block is the same form the setup used, with
  **Connect** as its word: an address and an **Access key**. A stored key
  leaves the field empty on purpose and typing replaces it; **Remove key**
  is the only thing that forgets one. **Connect** asks the server which model
  it serves and takes the name it lists, so nothing is typed twice. A server
  that offers several shows a picker, and a second **Connect** takes what is
  showing, unless one of the names it lists is the one this install already
  uses, which connects on the first press.
- **Embeddings** always runs on this Mac.
- **Model registry** is where the decision and embedding models are
  downloaded from: a **Registry address** and an **Access token**, with
  **Save**, **Remove token** and **Check**.
- **Set up again** — runs the whole flow from the top, and is how the models
  folder changes. It keeps what is expensive and
  still true: the models stay on disk and you stay signed in, so those two
  screens are a **Continue** each. It is not a commitment: the first screen
  carries **Back to the inbox**, which puts you back exactly where you were.
  If a download is running it keeps running either way.

## Uninstalling

1. Quit Bond.
2. Drag **Bond Desktop** from Applications to the Trash.
3. Delete `~/Library/Application Support/com.bondinbox.app/` — this is what
   frees the space the models took.
4. Open **Keychain Access**, search for `bond`, and delete the login items
   named after the app. That is the stored sign-in.

If you chose a different models folder during setup, delete that too.
