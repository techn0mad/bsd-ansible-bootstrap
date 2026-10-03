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
> **Since then this platform's default escalation tool changed from
> `doas` to `sudo`** — see
> [Where FreeBSD is not a renamed OpenBSD](#where-freebsd-is-not-a-renamed-openbsd)
> below. The same guest was re-validated after the switch: 10/10 again,
> with `become method sudo (detected)`, and [eight fault-injection
> cases](#escalation-fault-injection) against the new policy writer all
> behaved correctly.
>
> A **pristine** 15.1 guest was then installed from scratch on the
> `sudo` default — 8 changes, the same count the `doas` build took — and
> the boot hook was validated against it: with the drop-in deleted *and*
> `sshd_enable=NO`, one boot repaired both unattended in three changes,
> and a second boot with no drift made none. `rcorder` placed the hook
> at 170, behind `LOGIN` at 160 and `sshd` at 163.
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
> That has since been exercised [unattended during
> boot](#a-boot-with-the-package-repository-unreachable--done) rather
> than from a hand-run `apply`, and cost the same 34 seconds — two
> bounded calls, not one, which is this platform's distinguishing
> number. The repository-wide [README](../README.md) defines the
> contract all three platforms must satisfy.

## What this contains

```text
FreeBSD/
├── README.md
├── adapter.sh       # engine adapter: accounts, packages, services, escalation paths
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
| Privilege escalation | `sudo`, **from packages** | Neither `doas` nor `sudo` is in the FreeBSD base system; the Handbook treats `sudo` as the standard, so that is the default here. See below. |

## Confirmed on 15.1-RELEASE (arm64)

Probed on a real guest rather than assumed. These are settled and
[`adapter.sh`](adapter.sh) is written against them:

| Question | Answer |
| --- | --- |
| Login shell | `/bin/sh`, `/bin/csh`, `/bin/tcsh` in base — **no ksh**, so OpenBSD's `/bin/ksh` cannot carry over |
| `/home` | a real directory, not the historical symlink to `/usr/home`, so the shared home-directory check needs no loosening |
| doas | not installed, and no `doas.conf` in either `/etc` or `/usr/local/etc` |
| sudo | also not installed. The `sudo` package provides `/usr/local/bin/sudo` and `/usr/local/sbin/visudo`, creates `/usr/local/etc/sudoers` (`0440`) and `/usr/local/etc/sudoers.d` (`0755`), and the shipped `sudoers` ends with `@includedir /usr/local/etc/sudoers.d` as its last effective line — so a drop-in is read, and is evaluated last |
| `visudo -c -f FILE` | exits 0 when the file parses, 1 when it does not, and 1 for a missing file — usable as the pre-install validator |
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

**Configured through `sudo`.** FreeBSD's own Handbook treats `sudo` as
the standard ("The most used application is currently Sudo") and
describes `doas` as "an alternative to the widely used sudo(8) command".
Since neither is in base, there is no native tool to defer to, and
`sudo` is additionally what `ansible-core` supports without the
`community.general` collection. See
[the repository README](../README.md#which-escalation-tool-and-why-it-differs-per-platform)
for the full reasoning.

This platform was initially implemented with `doas`, for reuse of the
engine's existing `doas.conf` writer. That traded the platform's
convention for shared code, and the trade was reversed: the engine now
holds both writers, dispatched on `ESCALATION_STYLE`, and the adapter
supplies only paths.

The `sudo` shape is the simpler of the two. A `sudoers.d` drop-in is a
file this service owns outright, so there is no marked block to locate
and no unrelated content to preserve — but equally no marker saying
"this is mine", so drift is detected by comparing content, ownership and
mode against what the engine would write. That matters more than it
sounds: `sudo` *ignores* a drop-in owned by a non-root uid, which was
confirmed directly —

```text
sudo: /usr/local/etc/sudoers.d/ansible-bootstrap is owned by uid 1002, should be 0
```

— so the ownership comparison is part of whether the rule takes effect,
not hygiene.

`adapter_escalation_prepare` installs the package, bootstrapping `pkg`
first if that stub has never run, and both operations are bounded. On a
host where the repository is unreachable, `check` reports
`escalation: NOT READY` and `apply` fails with the bounded-package
diagnostic; there is no way to do better, because the capability
genuinely is not present.

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

### A boot with the package repository unreachable — done

The case this README listed as unexercised since the `run_bounded`
repair: the bound firing *unattended during boot* rather than from a
hand-run `apply`. A misconfigured repository fails fast and does not
test the bound, so `pkg` has to be made to hang. The engine's `PATH`
starts with `/sbin`, so a file there shadows both `/usr/sbin/pkg` (the
bootstrap stub the engine actually resolves) and the real
`/usr/local/sbin/pkg`:

```sh
sed 's/^PKG_TIMEOUT=300$/PKG_TIMEOUT=15/' /usr/local/libexec/ansible-bootstrap > /tmp/e
cp /tmp/e /usr/local/libexec/ansible-bootstrap && rm /tmp/e
pkg delete -y python314                   # so apply must reach the repository
printf '#!/bin/sh\nsleep 600\n' > /sbin/pkg
chmod +x /sbin/pkg
reboot
```

The console showed `FAILED`, boot completed normally, and SSH still
worked. The log:

```text
ansible-bootstrap: No compatible Python interpreter is installed; querying packages
ansible-bootstrap: Exceeded 15s; terminating: pkg update
ansible-bootstrap: Exceeded 15s; terminating: pkg rquery -g %n %v python3*
ansible-bootstrap: Could not query the package repository within 15s.
ansible-bootstrap: Check network reachability and PKG_PATH.
ansible-bootstrap: Boot continues; a later boot or a manual apply will retry.
ansible-bootstrap: ERROR: No installable Python interpreter found
```

**Two** bounded calls, not one: `adapter_python_packages` runs `pkg
update` before `pkg rquery`, and the update's failure is deliberately
tolerated. Total cost 34 seconds — the same figure the original
`run_bounded` repair measured by hand, now reproduced at boot. **The
other four invariants stayed OK**, because `apply_python` runs last in
`apply_all`; only Python was broken. Removing the shadow and running
`apply` reinstalled `python314` in one change, in 7 seconds.

That two-call multiplier is the thing to know about the default. At
`PKG_TIMEOUT=300` this platform can stall a boot for **ten minutes**
before giving up, against five on OpenBSD, which makes one call. The
bound works; the default is generous for something that runs before a
console login.

Clean up promptly; `/sbin/pkg` shadows `pkg` for everything:

```sh
rm -f /sbin/pkg
```

Unlike OpenBSD, nothing spurious appears in the log here: FreeBSD's
`/bin/sh` stays silent about a signal-killed child even when the
bounded command is a shell script. Measured, not assumed — see
[the OpenBSD note](../OpenBSD/README.md#a-terminated-line-that-is-the-tests-fault-not-the-engines).

### Escalation fault injection

Run against the 15.1 guest when the default changed from `doas` to
`sudo`, and repeated on the NetBSD guest with identical results. Each
case was injected, reconciled, and the outcome read back off the host:

| Injected fault | Expected | Result |
| --- | --- | --- |
| drop-in deleted | written | `change: Configuring passwordless sudo` |
| drop-in truncated to empty | rewritten | content restored |
| drop-in `chmod 0666` | mode repaired | back to `-r--r-----` |
| drop-in given to the `ansible` account | ownership repaired | back to `0 0`; `sudo` had been refusing it as "owned by uid 1002, should be 0" |
| `sudo` package removed entirely | reinstalled, then configured | 2 changes — exercises `adapter_escalation_prepare` |
| drop-in correct but `@includedir` removed from `sudoers`, so it is ignored | refuse, change nothing | `ERROR: Refusing to rewrite a correct sudoers drop-in`; drop-in left untouched |
| `ansible ALL=(ALL) !ALL` added to `sudoers` | refuse, write nothing | `ERROR: Refusing to override administrator sudo policy`; no drop-in created |
| `ansible ALL=(ALL) NOPASSWD: ALL` added to `sudoers`, drop-in absent | already satisfied | `escalation: OK`, `no changes were needed`, nothing written |

The last two are the pair that matters: this service refuses to outrank
an administrator's decision in either direction — it will not grant
over a denial, and it will not duplicate a grant that already exists.
