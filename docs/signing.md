# Signed releases

nova installs an app's newest **version tag**. For an app with a root half,
that tag is code root runs. Since 2.4.0, root updates a system app **without a
password** only to a tag signed by the SSH key it pinned for that app. Since
2.5.1, nova's own installers check nova's signature before they install
anything.

This page has three parts:

- [What users see](#what-users-see)
- [App authors: signing your releases](#app-authors-signing-your-releases), which takes two commands with `nova-release`
- [nova-updater's own releases](#nova-updaters-own-releases)

---

## What users see

- **Pinning.** Root keeps one key per system app, in
  `/etc/nova-updater/signers/<app>`, trusted on first use:
  - normally, the key in the release you installed with your password;
  - on a machine from before 2.4, the key in the release already installed;
  - for nova-updater itself, the key its installer carries.
- **What updates without a password.** A version tag signed by that key.
- **What waits for your password.** An unsigned release, a branch, or
  `HEAD`. nova says it could not verify it.
- **What is refused, password or not:**
  - a release signed by **another** key;
  - an unsigned release of an app whose releases were signed.
- **If the project really changed its key:**
  ```bash
  nova trust --system <app>      # forget the pinned key
  nova update <app>              # with your password: pins the new release's key
  ```
- **`nova doctor`** tells you if `ssh-keygen` is missing. git needs it to check
  signatures. The package is openssh-client(s), openssh, or openssh-keygen,
  depending on the distro; `nova pkg-hint ssh-keygen` prints yours.

User-scope apps run with your own rights; their tags are not checked.

---

## App authors: signing your releases

### Once per app

1. **Make a release key.**

   ```bash
   ssh-keygen -t ed25519 -C "myapp releases" -f ~/.ssh/myapp-release
   ```

   - Give it a passphrase. Better, use a hardware key: `-t ed25519-sk`.
   - Keep it `chmod 600`: `ssh-keygen` refuses to sign with a key others can
     read.
   - Keep it out of synced folders and off CI. A workflow that can sign makes
     its token the key.
   - One key can sign several of your apps.

2. **Set up the repository**, from its root:

   ```bash
   nova-release setup --key ~/.ssh/myapp-release
   git add .github && git commit -m "Signed releases"
   ```

   This:

   - writes `.github/allowed_signers` with your public key, which the release
     workflow checks;
   - copies nova's release workflow to `.github/workflows/release.yml`;
   - sets this repo's git config: `gpg.format=ssh`, `user.signingkey`,
     `tag.gpgSign`.

   `nova-release` is installed next to `nova`. It is also in nova-updater's
   repository as `bin/nova-release`.

### Every release

1. Bump `VERSION=` in `nova.manifest` and add a `## <version> — <date>`
   section to `CHANGELOG.md`. The workflow publishes that section as the
   release notes.
2. Commit and merge as usual.
3. On the release commit:

   ```bash
   nova-release tag --push
   ```

   It tags `v<VERSION>`, signed. It refuses if any of these holds:

   - the tree is dirty;
   - the tag exists;
   - the version is not newer than your newest release;
   - your `tests/check-version.sh` (if you have one) fails.

   It verifies the signature against `.github/allowed_signers` before it
   pushes. The release workflow then checks the same things again on GitHub
   and publishes the release.

4. Check any tag later with `nova-release check [vX.Y.Z]`.

### Doing it by hand

`nova-release` only wraps these:

```bash
git config gpg.format ssh
git config user.signingkey ~/.ssh/myapp-release
git tag -s v1.2.0 -m v1.2.0
git -c gpg.ssh.allowedSignersFile=.github/allowed_signers verify-tag v1.2.0
git push origin v1.2.0
```

`.github/allowed_signers` has one line per key, in ssh-keygen's *ALLOWED
SIGNERS* format:

```
yourname namespaces="git" ssh-ed25519 AAAA…
```

### Changing keys

Don't, unless you have to: every machine with your app's system half pinned
the old key and will refuse the new one.

If you must:

1. Add the new key to `.github/allowed_signers`. Keep the old line until
   nobody needs to verify old tags.
2. Release with the new key.
3. Say in the release notes that users must run
   `nova trust --system <app>` and update once with their password.

### Protect the branch

Signed tags stop a pushed tag from being trusted. They don't stop a pushed
commit from being *signed later by you* without anyone noticing. Protect
`main` (pull requests and review), and read what you sign.

---

## nova-updater's own releases

The same flow, with two additions:

- **The key is carried in three places:** `.github/allowed_signers`,
  `get-nova.sh` and `install.sh` (`NOVA_SIGNER`).
  - `get-nova.sh` refuses a release that key didn't sign, before installing
    anything.
  - The root bootstrap refuses one before root runs it, then pins the key as
    root's signer for nova-updater.
  - `tests/check-version.sh` fails if the three copies differ.
  - Changing the key means changing all three, in a release signed with the
    *old* key.
- **Release checklist:**
  1. CI is green on the six-distro matrix.
  2. `VERSION` in `nova.manifest` matches `NOVA_VERSION` in `bin/nova`
     (`tests/check-version.sh`).
  3. `CHANGELOG.md` has a dated `## X.Y.Z — YYYY-MM-DD` section.
  4. Merge, then on `main`: `nova-release tag --push`.
  5. The release workflow publishes. Machines with the system scope pick the
     release up on their next timer run without a password.

A fork that installs root from its own repository names it in a root-owned
`/etc/nova-updater/self-url`, and its key in a root-owned
`/etc/nova-updater/self-signers` (the same format). Without `self-signers`, the
fork's releases are installed unchecked, and nova says so.
