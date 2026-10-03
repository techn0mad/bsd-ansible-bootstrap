# FreeBSD implementation — Ansible bootstrap service

> **Status:** A fresh 15.1-RELEASE arm64 guest reached all five
> invariants on the first attempt, in eight changes: key stored, account
> created, controller key installed, `.ssh` and `authorized_keys`
> ownership set, `doas` installed from packages, passwordless `doas`
> configured, and `python314` installed. The shared engine, installer and
> controller-side tests are the same code the OpenBSD implementation
> runs, unmodified.
>
> That run was the first time **anywhere** that account creation and
> package-installed privilege escalation had executed — on OpenBSD the
> account always already existed and `doas` is in the base system.
>
> `lib/controller-test.sh -a` then passed 10/10 against that host,
> unmodified: key-only login, the *packaged* `doas` reached through the
> become plugin, an Ansible ping, fact gathering reporting Python
> 3.14.7 — the top of ansible-core 2.21's managed-node range — and a
> second `apply` making no changes. A `sysrc sshd_enable=NO` drift test
> was then repaired with exactly one change.
>
> A reboot then exercised the `rc.d` hook and found a bug in its
> `rcorder` placement — see *Boot integration* below. After the fix,
> `rcorder` places the hook at 170, behind `LOGIN` at 160 and `sshd` at
> 163, and a second reboot logged `no changes were needed`. The two boot
> blocks sit adjacent in the log, one change line and then none, which is
> the whole diagnosis:
>
> ```text
> --- 05:07:13 apply ---   change: Starting sshd   1 change made
> --- 05:14:09 apply ---                           no changes were needed
> ```
>
> All eight adapter functions have run on hardware. `adapter_service_start`
> was then exercised deliberately, by stopping `sshd` while leaving it
> enabled: `apply` logged one change, `Starting sshd` and not `Enabling
> sshd`, which is what distinguishes a working `adapter_service_enabled`
> from a broken one.
>
> Drift repair at boot has since been exercised too, by disabling `sshd`
> and rebooting. The hook logged two changes, `Enabling sshd` then
> `Starting sshd`, and the controller could reach the host again
> afterwards — confirming that `rcorder` ordering holds even when a
> `REQUIRE`'d service is disabled and `rc` skips it, which was the way
> this test could have stranded the guest.
>
> The package bound has since been verified on this host, and finding
> that it did not work is the most valuable thing this platform
> contributed — see *Bounding package operations* below. After the fix,
> a 15-second bound against a hung `pkg` cost 34 seconds rather than
> 617, and left no orphaned process.
>
> Still unexercised: that happening unattended during boot rather than
> from a hand-run `apply`. The repository-wide
> [README](../README.md) defines the contract both platforms must
> satisfy.

## What this contains

```text
FreeBSD/
├── README.md
├── adapter.sh       # engine adapter: accounts, packages, services, doas paths
├── boot-hook.sh     # installer adapter: the rc.d script and rc.conf variable
├── install.sh       # wrapper over lib/install.sh
└── rc.d/
    └── ansible_bootstrap
```

The engine, the installer and the controller-side tests are shared with
OpenBSD under `lib/`. These four files are the whole FreeBSD-specific
surface.

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
was the only version available. On the first real install this worked
exactly so: `python314` was chosen and `/usr/local/bin/python3.14`
reported to the controller.

## Where FreeBSD is not a renamed OpenBSD

The differences that shaped the adapter, and how each is handled.

**Privilege escalation is not in the base system.** This is the
substantive difference. On OpenBSD, `doas` is always present, so the
reconciliation order can configure escalation before touching the
package manager. On FreeBSD, both `doas` and `sudo` are packages, so
privilege escalation *depends on* a working package manager and a
reachable repository. That inverts part of the ordering and means a
mirror failure can block a prerequisite that is unconditionally
available on OpenBSD.

**Standardized on `doas`**, so the shared engine's `doas.conf` handling
— the marked block, the refusal to duplicate its own rule, the refusal
to outrank an administrator's — carries over unchanged, with only
`DOAS_BIN` and `DOAS_CONF` differing. `adapter_escalation_prepare`
installs it, bootstrapping `pkg` first if that stub has never run, and
both operations are bounded. On a host where the repository is
unreachable, `check` reports `doas: NOT READY` and `apply` fails with
the bounded-package diagnostic; there is no way to do better, because
the capability genuinely is not present.

**Bounding package operations.** This platform is where the bound was
found to be broken, and the bug was in shared code that OpenBSD had
never stressed. Forcing a genuine hang — by shadowing `pkg` with a
sleeper, since a misconfigured repository merely fails fast — held the
host for 617 seconds under a 15-second bound.

`ps` showed every process sharing the caller's process group: `set -m`
does not give a background job its own group in FreeBSD's `sh`, so the
group kill found nothing, only the direct child died, and the orphaned
grandchild kept the caller's command-substitution pipe open for its full
lifetime. The bound fired and logged correctly; it just did not bound
anything.

`run_bounded` now writes the command's stdout to a file rather than to
the caller's descriptor, so no surviving process can hold a pipe the
caller waits on, and walks the process tree with `pgrep -P` to signal
children before parents. Verified on both platforms: 34 seconds against
a hung `pkg` here, 25 against a hung `pkg_info` on OpenBSD, no orphans
either side.

**`pkg` may need bootstrapping.** A minimal FreeBSD installation may
have no `pkg` binary until `pkg bootstrap` runs, which is itself a
network operation. The existing bounded-package-operation helper
(`run_bounded`) should cover this too, and the same actionable
diagnostic applies.

**Boot integration is a real rc.d service.** Not a choice, as it turned
out: `/etc/rc` on 15.1 contains no reference to `rc.local` at all, so
the OpenBSD approach is unavailable rather than merely inferior.
[`rc.d/ansible_bootstrap`](rc.d/ansible_bootstrap) is `REQUIRE:
NETWORKING LOGIN sshd`, and every entry is load-bearing. The first
attempt used `NETWORKING` alone and a reboot showed why that is wrong:

```text
 81: /etc/rc.d/NETWORKING
 84: /usr/local/etc/rc.d/ansible_bootstrap
162: /etc/rc.d/LOGIN
167: /etc/rc.d/sshd
```

FreeBSD's `sshd` requires `LOGIN` and therefore starts late. Running at
84, the engine found `sshd` enabled but not yet started, "repaired" it by
starting it early, and reported a change on every boot of a host with
nothing wrong. Worse, a package operation there can consume the whole
`PKG_TIMEOUT` — which ordered before `LOGIN` would hold the console
unusable for minutes, in direct contradiction of the repository README's
requirement that the boot hook never prevent console access.

OpenBSD never showed this because `rc.local` runs at the end of
`/etc/rc`, after the daemons. Adding a managed service to the adapter
means adding it to the `REQUIRE` list too. It returns 0 even when reconciliation fails — the
failure is announced on the console and recorded in the log, and a later
boot retries, which is not worth risking the rest of the boot sequence
over. Its `status` command reports readiness rather than whether
something is running, because nothing is.

This is the easier half of the platform split, which is unusual for
FreeBSD here: the script is a whole file this service owns, so
installing it is idempotent by nature. OpenBSD has to locate its own
block inside the administrator's `rc.local`, replace it, preserve
unrelated content and leave ownership and mode alone.

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

## What is shared, not reimplemented

Most of the engine is not OS-specific and is not forked:

- public-key validation, fingerprint reporting, and the refusal to
  replace a configured controller key
- `authorized_keys` reconciliation, including the separation of key
  presence from file ownership and permissions
- the permission and ownership predicates
- the bounded-command helper
- the exit-status contract and the check/apply/report structure
- `controller-test.sh`, which turned out to be entirely
  platform-independent and now lives in `lib/`

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
