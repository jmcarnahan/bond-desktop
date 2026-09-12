# `docs/appcast/`

`appcast.xml` beside this file is Bond Desktop's **update feed**: the RSS-shaped
document Sparkle reads to find out whether a newer release exists. Each item in
it names a version, the URL of that version's DMG on GitHub Releases, and an
EdDSA signature of those exact bytes. An installed copy of Bond verifies the
signature against the `SUPublicEDKey` baked into its own `Info.plist` and
installs nothing that fails.

**It is generated, never hand-edited.** `make dist-appcast` runs Sparkle's own
`generate_appcast` over the released DMG — it reads the version numbers out of
the app inside the image, computes the signature, and rewrites the file. Editing
the XML by hand gets you an item whose signature no longer matches its
enclosure, which every installed copy silently refuses. If something in it is
wrong, fix the input and re-run the tool.

**It is served by GitHub Pages** from the `main` branch's `/docs` directory, so
the file is live once it is committed and pushed and Pages has redeployed:

```
https://jmcarnahan.github.io/bond-desktop/appcast/appcast.xml
```

That URL is what `dist/bundle.sh` writes into each build as `SUFeedURL`, which
is why it has to keep working for the life of every build that carries it.

**Installed copies read it about once a day** (`SUScheduledCheckInterval`,
86400 seconds) and never on a first launch — Sparkle deliberately waits until
the app has been opened again. So a release reaches its users over the day
after the push, not the minute of it.

The whole story — key generation, hosting, what the user sees, and what
switching keys would cost — is in
[`docs/distribution.md` → Updates](../distribution.md).
