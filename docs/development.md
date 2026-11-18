# Development

nova-updater is bash (`bin/nova`, `bin/nova-release`, `install.sh`,
`get-nova.sh`, the root helper in `data/`) and one Python/GTK 4 program
(`gui/nova-gui`).

## Tests

Two test scripts. Both need root, create a user and write to `/etc`,
`/usr/local` and `/var/lib`, so they refuse to run outside a container.

| Script | What it does |
|---|---|
| `tests/repro.sh` | The full suite: one check per finding of every audit, with the network, `systemctl` and `pkexec` stubbed. Prints `ok` or `BUG` per check. `bash tests/repro.sh H1 M2` runs only some. |
| `tests/smoke.sh` | A real install over the network: user install, first `nova list`, root setup of the tree under test, `nova doctor`, installing a real app. |
| `tests/check-version.sh` | The release gate: versions agree, scripts are executable in git, the release key's three copies are equal. Safe to run anywhere. |

Run them in a container, for example on Fedora:

```bash
podman run --rm -v "$PWD":/src:ro,z fedora:latest bash -c \
  'dnf -y -q install git-core gawk util-linux shadow-utils procps-ng python3 openssl openssh-clients >/dev/null &&
   bash /src/tests/repro.sh && bash /src/tests/smoke.sh'
```

The package lists for the other distributions are in
[`.github/workflows/ci.yml`](https://github.com/schlingel-bernd/nova-updater/blob/main/.github/workflows/ci.yml).
Use `:z`, not `:Z`, when several containers mount the same directory at once.

Also run before a pull request:

```bash
shellcheck -S warning bin/nova bin/nova-release install.sh get-nova.sh \
  data/nova-system-update data/bash-completion/nova templates/install.sh tests/*.sh
python3 -m py_compile gui/nova-gui
bash tests/check-version.sh
```

## CI

Every push and pull request runs:

- **lint** — shellcheck, `py_compile`, `check-version.sh`;
- **distros** — `repro.sh` and `smoke.sh` on Fedora, Debian 13, Ubuntu 24.04,
  Arch, openSUSE Tumbleweed and Alpine;
- **busybox** — stock Alpine must stop with the package line, not fail halfway.

Package setup retries three times, because runners sometimes cannot reach a
distribution mirror. A leg that fails at `docker run` or package setup is the
runner, not nova: re-run it.

## Rules the code keeps

- **Root never runs a file the user can write**, and never reads its
  configuration from one.
- **A failed step is never reported as success**, in the exit code or in the
  installed marker.
- **What `nova info` and `nova list` show is what `install` and `update` do.**
- **Nothing asks for a password unless the root work can succeed.**
- **Nothing from a catalog or a manifest is ever interpreted** — not as an
  option, not as shell code, not as terminal control sequences, not as markup.
- `nova list --porcelain` fields are only ever appended.

The audits that produced these rules, with one test per finding, are in
[FIXPLAN.md](https://github.com/schlingel-bernd/nova-updater/blob/main/FIXPLAN.md)
and
[FIXPLAN-2.4.md](https://github.com/schlingel-bernd/nova-updater/blob/main/FIXPLAN-2.4.md).
Distribution support is planned in
[PORTPLAN.md](https://github.com/schlingel-bernd/nova-updater/blob/main/PORTPLAN.md).

## Releasing nova-updater

1. CI is green.
2. `VERSION` in `nova.manifest` equals `NOVA_VERSION` in `bin/nova`.
3. `CHANGELOG.md` has a dated `## X.Y.Z — YYYY-MM-DD` section.
4. Merge, then on `main`:
   ```bash
   nova-release tag --push
   ```
5. The release workflow checks the signature and publishes the release.
   Machines with the root part pick it up on their next timer run, without a
   password.

The release key is carried in three places (`.github/allowed_signers`,
`get-nova.sh`, `install.sh`); see [Signed releases](signing.md).
