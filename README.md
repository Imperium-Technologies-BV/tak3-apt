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
     the private tak3 repository and nothing else.
4. **Settings › Variables › `APT_URL`**: the address customers use, ideally your
   own domain (`https://apt.example.com`) so the host can change later.
5. **Settings › Pages**: deploy from branch `gh-pages`, folder `/`, custom domain
   as above.
6. **In the private tak3 repository**:
   - Variable `APT_REPOSITORY` = `<owner>/tak3-apt` — this switches publishing on.
   - Secret `APT_TRIGGER_TOKEN` — a fine-grained token with **Actions: read and
     write** on `tak3-apt` only. It can start this workflow and nothing else:
     it cannot change this repository's files or read its secrets.

## A release

Tag `v1.2.0` in the private repository. Its release workflow builds, tests and
makes the GitHub Release, then asks here. **Approve** the waiting run under
Actions › publish, and the packages are signed and served within minutes.
A pre-release tag (`v1.2.0-rc.1`) goes to the `testing` suite instead of
`stable`.
