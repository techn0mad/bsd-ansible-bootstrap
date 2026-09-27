# FreeBSD implementation — Ansible bootstrap service

> **Status: planned. Nothing in this directory is implemented yet.**
> This document records the intended FreeBSD adapter and the decisions
> that have to be made before code is written. The
> [OpenBSD implementation](../OpenBSD/README.md) is the working
> reference; the repository-wide [README](../README.md) defines the
> contract both platforms must satisfy.

## What this will contain

Per the layout in the repository README:

```text
FreeBSD/
├── README.md
├── install.sh
├── ansible-bootstrap
└── rc.d/
    └── ansible_bootstrap
```

The OpenBSD prototype deliberately remains a single script while its
behavior is validated. Splitting a shared POSIX-shell engine from the
OS adapters should wait until the FreeBSD requirements below are
concrete — that is the point at which the real abstraction boundaries
become visible rather than guessed.

## Readiness contract on FreeBSD

The five invariants are unchanged; only the mechanisms differ.

| Prerequisite | FreeBSD mechanism | Notes |
| --- | --- | --- |
| SSH service | Base-system `sshd`, `sysrc sshd_enable=YES`, `service sshd start` | `sshd -t` validates the configuration as on OpenBSD. |
| Service account | `pw useradd`, home `/home/ansible` | Login shell must **not** be `/bin/ksh`: FreeBSD has no ksh in base. |
| SSH public-key access | Same root-owned key source, account-owned `authorized_keys` | Logic is platform-independent and should move to the shared engine unchanged. |
| Python | `pkg install`, interpreters in `/usr/local/bin` | Same discovery approach and the same `PYTHON_MIN`/`PYTHON_MAX` question. |
| Privilege escalation | `doas` or `sudo`, **from packages** | Neither is in the FreeBSD base system. See below. |

## Confirmed on 15.1-RELEASE (arm64)

Probed on a real guest rather than assumed. These are settled and
[`adapter.sh`](adapter.sh) is written against them:

| Question | Answer |
| --- | --- |
| Login shell | `/bin/sh`, `/bin/csh`, `/bin/tcsh` in base — **no ksh**, so OpenBSD's `/bin/ksh` cannot carry over |
| `/home` | a real directory, not the historical symlink to `/usr/home`, so the shared home-directory check needs no loosening |
| doas | not installed, and no `doas.conf` in either `/etc` or `/usr/local/etc` |
| `wait` under `set -m` | returns the real status, so `run_bounded` works on ash as it does on pdksh |
| `ls -ldn` | same column layout as OpenBSD, so the permission checks port unchanged |
| `getent passwd` | works — but note it returns the **password hash** in field 2 when run as root, where OpenBSD returns `*`. Nothing reads that field; do not start. |
| `rc.local` | `/etc/rc` contains no reference to it at all, so `rc.d` is not merely preferred here, it is the only option |
| Interpreter query | `pkg rquery -g '%n %v' 'python3*'` works; `pkg search -q '^python3[0-9]*$'` returns nothing |
| Probe cost | every service query is 0.01s and even `service -e` is 0.24s, so there is no equivalent of OpenBSD's 22-second `rcctl ls on` trap |

The interpreter catalog needs care. It offers `python310` through
`python315`, and three kinds of entry must not be selected:

```text
python3     3_4        a meta package; "3_4" is not an interpreter version
python313t  3.13.15    free-threaded build -- a different runtime
python315   3.15.0.b2  a pre-release
```

The version comes from `%v` rather than the package name, since the name
squashes it (`python313`). Requiring at least one digit after `python3`
drops the meta package and requiring the name to end there drops the
`t` variants. The pre-release needs no special case **while a maximum is
configured**: `PYTHON_MAX=3.14` selects `python314` and leaves
`python315` alone. With no maximum it would install the beta — which is
a sharper argument for setting one than OpenBSD could offer, where 3.13
was the only version available.

## Decisions that must be made first

These are the places where FreeBSD is not merely a renamed OpenBSD,
and each one needs confirming on a real target release rather than
assuming the OpenBSD answer transfers.

**Privilege escalation is not in the base system.** This is the
substantive difference. On OpenBSD, `doas` is always present, so the
reconciliation order can configure escalation before touching the
package manager. On FreeBSD, both `doas` and `sudo` are packages, so
privilege escalation *depends on* a working package manager and a
reachable repository. That inverts part of the ordering and means a
mirror failure can block a prerequisite that is unconditionally
available on OpenBSD. Decide which tool to standardize on, and decide
what `check` should report on a host where the package is missing and
the repository is unreachable.

**`pkg` may need bootstrapping.** A minimal FreeBSD installation may
have no `pkg` binary until `pkg bootstrap` runs, which is itself a
network operation. The existing bounded-package-operation helper
(`run_bounded`) should cover this too, and the same actionable
diagnostic applies.

**Boot integration is a real rc.d service, not `rc.local`.** FreeBSD
has `rc.local`, but the documented mechanism is an `rc.d` script with
`sysrc ansible_bootstrap_enable=YES`. It still must be a short-lived
boot task, not a daemon: `PROVIDE`, `REQUIRE: NETWORKING`, a
one-shot command, and no dependency loop that can delay or block
multi-user boot. `rc.d` gives better ordering control than `rc.local`,
which is a genuine improvement over the OpenBSD arrangement.

**Getting the files onto the host.** The OpenBSD README fetches an
archive with base `ftp(1)`; FreeBSD has no `ftp` for this and uses
`fetch(1)` instead, which also follows redirects:

```sh
fetch -o - "https://codeload.github.com/techn0mad/bsd-ansible-bootstrap/tar.gz/$rev" |
    tar xzf -
cd "bsd-ansible-bootstrap-$rev/FreeBSD"
```

The two `tar` implementations differ here and the difference bites.
FreeBSD's is libarchive and accepts `--strip-components=1`, including
after `f -`; OpenBSD's is the `pax` binary, which reads trailing
arguments as member-name patterns instead, so an option there causes a
silent extraction of nothing. The form above passes no options beyond
`xzf` and works on both, which is why it is the documented one.

Certificate verification needs a CA bundle. FreeBSD 12.2 and later
ship one in base via `certctl(8)`; older releases need
`security/ca_root_nss`. Confirm this on the target release — on
OpenBSD it is unconditionally present, so this is a new failure mode
rather than a renamed one.

**Login shell.** `/bin/ksh` does not exist on FreeBSD. `/bin/sh` is
the obvious choice. The bootstrap program itself is already
`#!/bin/sh` and FreeBSD's `/bin/sh` is POSIX, but every shell
construct the engine uses should be re-verified against it — including
`set -m` job control in `run_bounded` and the `ls -ldn` column parsing
in the permission checks.

**Account management.** `pw useradd -n ... -d ... -s ... -m` replaces
`useradd`, and its handling of the primary group differs. The engine
already reads uid and gid from the `passwd` entry rather than assuming
a group named after the account, which should carry over unchanged,
but confirm it.

## What should be shared, not reimplemented

Most of the engine is not OS-specific and should not be forked:

- public-key validation, fingerprint reporting, and the refusal to
  replace a configured controller key
- `authorized_keys` reconciliation, including the separation of key
  presence from file ownership and permissions
- the permission and ownership predicates
- the bounded-command helper
- the exit-status contract and the check/apply/report structure
- `controller-test.sh`, which is almost entirely platform-independent:
  only the become method and the interpreter path differ, and both are
  already options rather than constants

The genuinely platform-specific surface is small: account creation,
package installation, privilege-escalation configuration, service
management, and the boot hook. Keep the adapters that size and resist
building a framework for two operating systems.

## Validation

The validation plan in the repository README applies unchanged, on a
disposable FreeBSD VM. Add one case that OpenBSD does not need:
bootstrap the host with the privilege-escalation package absent *and*
the package repository unreachable, and confirm the failure is
bounded, diagnosable, and recoverable on a later boot.
