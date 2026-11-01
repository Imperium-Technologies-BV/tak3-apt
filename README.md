# tak3 apt repository

The signed apt repository customers install tak3 from. This folder is the
whole of a separate **public** repository (`tak3-apt`): copy it there as the
`main` branch. GitHub Pages serves the `gh-pages` branch, which
`.github/workflows/publish.yml` writes.

Why separate, and why public: the signing key every customer's apt trusts
lives only here, in an environment that waits for the owner's approval. On a
free plan a private repository cannot have such an environment; a public one
can. The private repository where tak3 is built holds no signing material at
all — its release workflow can only ask this one to run.

## Setting it up, once

1. **The key.** On a trusted machine:
   `gpg --quick-gen-key "tak3 packages <packages@your-domain>" ed25519 sign 3y`, then
   `gpg --armor --export-secret-keys <fingerprint>` for the secret below. Keep an
   offline copy; publish the fingerprint on your website.
2. **This repository**, public, with this folder's files on `main`.
3. **Settings › Environments › New: `apt`**
   - Required reviewers: yourself. Prevent self-review off (you are the only one).
   - Deployment branches: `main` only.
   - Secrets: `APT_SIGNING_KEY`, `APT_SIGNING_PASSPHRASE` (if the key has one),
     `RELEASES_TOKEN` — a fine-grained token with **Contents: read-only** on
     the private tak3 repository and nothing else. Its **resource owner** is
     the account that owns that repository (the organisation, not you): a
     token can only reach repositories of the owner it was made for, and that
     cannot be changed afterwards.
4. **Settings › Variables › `APT_URL`**: the address customers use, ideally your
   own domain (`https://apt.example.com`) so the host can change later.
5. **The domain.**
   - Verify it for GitHub Pages on the **account that owns this repository**.
     For an organisation: Organisation settings › Pages › Add a domain, then
     the TXT record it shows (`_github-pages-challenge-<owner>`). A domain
     verified on another account, your personal one for instance, is refused
     here, and GitHub drops the custom domain at the next deployment.
   - At your DNS provider: a CNAME from the apt host to `<owner>.github.io`.
   - **Settings › Pages**: deploy from branch `gh-pages`, folder `/`, custom
     domain as above, **Enforce HTTPS** once GitHub offers it.
6. **In the private tak3 repository**:
   - Variable `APT_REPOSITORY` = `<owner>/tak3-apt` — this switches publishing on.
   - Secret `APT_TRIGGER_TOKEN` — a fine-grained token with **Actions: read and
     write** on `tak3-apt` only, its resource owner the account that owns
     `tak3-apt`. It can start this workflow and nothing else: it cannot change
     this repository's files or read its secrets.

## A release

Tag `v1.2.0` in the private repository. Its release workflow builds, tests and
makes the GitHub Release, then asks here. **Approve** the waiting run under
Actions › publish, and the packages are signed and served within minutes.
A pre-release tag (`v1.2.0-rc.1`) goes to the `testing` suite instead of
`stable`.

## Moving the repositories to another owner

Customers only ever see the apt address, so a move is invisible to them if it
is done in this order:

1. **Verify the domain on the new owner first** (step 5 above), so the custom
   domain survives the first deployment after the move.
2. **Move** `tak3-apt` (and the private repository). Secrets, the `apt`
   environment, variables and the Pages settings go with it.
3. **DNS**: point the apt host's CNAME at `<new owner>.github.io`.
4. **Tokens**: both are tied to the owner they were made for. Make new ones
   with the new owner as resource owner and store them without echoing:
   `gh secret set RELEASES_TOKEN --env apt --repo <owner>/tak3-apt` and
   `gh secret set APT_TRIGGER_TOKEN --repo <owner>/<private repository>`.
   Then delete the old tokens.
5. **`APT_REPOSITORY`** in the private repository: `<new owner>/tak3-apt`.
6. **Check**: run publish for the latest tag by hand and approve it. If the
   address answered 404 at any point, GitHub's CDN may keep serving those 404s
   for a while; a rebuild clears them:
   `gh api -X POST repos/<owner>/tak3-apt/pages/builds`.
   Then `apt update` against the address from a clean machine.
