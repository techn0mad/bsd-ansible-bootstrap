# NetBSD implementation — Ansible bootstrap service

> **Status:** A pristine 11.0 aarch64 guest reached all five invariants
> in nine changes: key stored, account created, controller key
> installed, `.ssh` and `authorized_keys` ownership set, `doas`
> installed from pkgsrc, `/usr/pkg/etc` created, passwordless `doas`
> configured, and `python314` installed at `/usr/pkg/bin/python3.14`.
> One more change than FreeBSD, the extra being the `PKG_SYSCONFDIR`
> that pkgsrc does not create.
>
> **Since then this platform's default escalation tool changed from
> `doas` to `sudo`** — see
> [Privilege escalation has no native tool here](#privilege-escalation-has-no-native-tool-here)
> below. The same guest was re-validated after the switch: 10/10 again,
> with `become method sudo (detected)`, and the eight fault-injection
> cases tabulated in
> [the FreeBSD README](../FreeBSD/README.md#escalation-fault-injection)
> all behaved identically here.
>
> `lib/controller-test.sh -a` then passed 10/10 against that host,
> unmodified — the same script the other two platforms use. The
> `rc.conf` marked block, this platform's most distinctive mechanism,
> was exercised by appending a last-wins `sshd=NO`: `check` reported
> `sshd: NOT READY`, `apply` wrote the block, and the result was still
> valid shell.
>
> A reboot then exercised the `rc.d` hook: `apply` ran at boot, repaired
> nothing, logged one clean block, and the console showed the announce
> lines. No spurious `Starting sshd`, so the `REQUIRE` ordering holds in
> practice and not merely in `rcorder`'s output.
>
> All eight adapter functions have run on hardware.
> `adapter_service_start` was exercised by stopping `sshd` while leaving
> it enabled: `apply` logged one change, `Starting sshd` and not
> `Enabling sshd`, which is what distinguishes a working
> `adapter_service_enabled` from a broken one.
>
> Not yet exercised: drift repair unattended at boot rather than by
> hand, and a boot with the package repository unreachable.
>
> The shared engine, installer and controller-side tests are byte-identical
> to what [OpenBSD](../OpenBSD/README.md) and
> [FreeBSD](../FreeBSD/README.md) run; the repository-wide
> [README](../README.md) defines the contract all three satisfy.

## What this contains

```text
NetBSD/
├── README.md
├── adapter.sh       # engine adapter: accounts, packages, services, escalation paths
├── boot-hook.sh     # installer adapter: the rc.d script and rc.conf assignment
├── install.sh       # wrapper over lib/install.sh
└── rc.d/
    └── ansible_bootstrap
```

Adding this platform required **no change to shared code**, which is
the first evidence that the adapter contract was cut at the right place
rather than merely shaped to fit two examples.

## Confirmed on 11.0 (aarch64)

Probed on a real guest rather than assumed.

| Question | Answer |
| --- | --- |
| Login shell | `/bin/ksh` is in base — like OpenBSD, unlike FreeBSD |
| Account tool | `useradd`, no `pw` — like OpenBSD |
| `/etc/skel/.ssh` | **absent** — like FreeBSD, so a fresh account costs four changes, not two |
| Package tooling | pkgsrc's `pkg_add`/`pkg_info` in `/usr/sbin`, **no pkgin** — same *names* as OpenBSD's, different implementation |
| `PYTHON_DIR` | `/usr/pkg/bin` — pkgsrc's prefix, not `/usr/local/bin` |
| `doas` | **not present at all**, and no `doas.conf` anywhere — must come from pkgsrc. Neither is NetBSD's native tool: `man.netbsd.org` has no `doas.1` or `sudo.8`, and base offers only `su(1)`. |
| `sudo` | also absent. The pkgsrc `sudo` package provides `/usr/pkg/bin/sudo` (setuid, `4511`) and `/usr/pkg/sbin/visudo`, and — unlike the `doas` package — **does** create its `PKG_SYSCONFDIR`: `/usr/pkg/etc/sudoers` (`0440`) and `/usr/pkg/etc/sudoers.d` (`0755`). The shipped `sudoers` ends with `@includedir /usr/pkg/etc/sudoers.d` as its last effective line, so a drop-in is read and is evaluated last. |
| Service enable/disable | no `rcctl`, no `sysrc`; `service(8)` exists but has no enable subcommand |
| Boot | `rc.d` and `rcorder`; `/etc/rc.local` exists but is run by `rc.d/local` |
| Shared-engine assumptions | `getent`, `ls -ldn` layout, `pgrep -P`, `mktemp /var/run`, and `wait` under `set -m` all behave as the engine expects |

### Querying service state

`service -e NAME` prints the script path and exits `0` when the service
is enabled for boot, and prints nothing and exits `1` when it is not.
That is the O(1) query the engine needs.

**Do not substitute `rcvar`.** It exits `0` either way and differs only
in what it prints:

```text
/etc/rc.d/sshd rcvar        → sshd=YES          exit 0
/etc/rc.d/accounting rcvar  → accounting=NO     exit 0
```

Using its status would report every service as enabled, including one
that will not survive a reboot — the precise failure the contract
separates "enabled" from "running" to catch.

`onestatus` and `onestart` are used rather than `status` and `start`,
because the latter consult `rcvar` first and refuse for a disabled
service. That would conflate "not running" with "not enabled", which
the engine asks as separate questions.

### Enabling a service

NetBSD has no tool for this: enablement is an assignment in
`/etc/rc.conf`, the administrator's file, sourced as shell so the last
assignment wins. The adapter writes into a marked block at the end —
the same discipline the engine applies to `doas.conf`, and for the same
reason. A block already carrying the assignment while the service is
still not enabled is reported as a conflict rather than appended to
again, because a boot-time reconciler that appends on every failed
check would grow the administrator's file without bound.

The generated file is validated with `sh -n` before being installed.
`/etc/rc.conf` is sourced by `/etc/rc`, so a syntax error there would
break boot — the same role `doas -C` plays for `doas.conf`.

Worth knowing: the guest's `rc.conf` already contained `sshd=NO` *and*
`sshd=YES`, on different lines. Duplicate keys are normal here and
last-wins is the rule, which is exactly why appending is safe and
in-place editing would not be.

### Boot integration must be rc.d, not rc.local

NetBSD has `rc.local`, but `rcorder` places it too early:

```text
 39: /etc/rc.d/NETWORKING
 86: /etc/rc.d/DAEMON
 95: /etc/rc.d/local        ← rc.local runs here
110: /etc/rc.d/LOGIN
112: /etc/rc.d/sshd         ← sshd starts here
```

A hook in `rc.local` would run before the service whose state it
inspects — reporting a spurious repair on every boot — and before the
console is usable, where a package operation consuming the whole
`PKG_TIMEOUT` would hold `LOGIN` for minutes. That is the bug FreeBSD
cost a boot cycle to find; here the order was read first, and
`rc.d/ansible_bootstrap` is `REQUIRE: NETWORKING LOGIN sshd`, which
`rcorder` places at 133.

**The script carries no `KEYWORD` line, and must not.** `nostart` was
tried first, by analogy with the FreeBSD script's `nojail`. It means the
opposite of what it reads like:

```sh
/etc/rc:153:  files=$(rcorder -s nostart ${rc_rcorder_flags} ${scripts})
```

`/etc/rc` *skips* scripts carrying it, so the keyword removes a script
from the boot sequence entirely — `rcorder` listed the hook at 133 while
`rcorder -s nostart` did not list it at all. The hook installed
cleanly, `rc.conf` enabled it, and its own `rcvar` reported `YES`; it
simply would never have run. The only base script using `nostart` is
`downinterfaces`, which runs at shutdown.

That was caught before a reboot only because `service -e
ansible_bootstrap` disagreed with `rc.conf`, which is worth knowing as a
check in its own right: `rcvar` reports what the script *thinks*, while
`service -e` reports whether `rc` will actually run it. They can differ,
and when they do, `service -e` is the one that matters.

So OpenBSD uses `rc.local` and the other two use `rc.d`, and the reason
is ordering rather than preference.

### pkgsrc does not always create its own PKG_SYSCONFDIR

A pkgsrc package is not obliged to create the directory its
configuration belongs in, and the two escalation packages differ on it.
The `doas` package installs the binary setuid root at
`/usr/pkg/bin/doas` and an example under `share`, but **not
`/usr/pkg/etc`**. The config path is compiled into the binary —

```sh
$ strings /usr/pkg/bin/doas | grep -i doas.conf
/usr/pkg/etc/doas.conf
```

— so it is that directory or nothing. Without it the first install
failed in a way that said nothing about the cause:

```text
ansible-bootstrap: change: Configuring passwordless doas
mktemp: mkstemp failed on /usr/pkg/etc/doas.conf.9yAGLCIP: No such file or directory
ansible-bootstrap: ERROR: Cannot create temporary doas configuration
```

The engine reported only that it could not create a temporary file,
because from its point of view that is all that happened. Neither
predecessor could surface it: OpenBSD's `doas.conf` lives in `/etc`,
which always exists, and FreeBSD's package creates `/usr/local/etc`
itself.

The `sudo` package, now the default here, *does* create
`/usr/pkg/etc/sudoers.d` — measured, not assumed. The engine creates the
drop-in's parent directory anyway when it is missing, so this platform's
lesson outlived the package that taught it: the cost is one `stat`, and
the failure it prevents is a diagnostic that points at the wrong thing.

### Account creation takes no `-p`

All three platforms lock the account's password, and all three do it
differently:

```sh
OpenBSD   useradd -m -d DIR -s SHELL -p '*' ACCOUNT
FreeBSD   pw useradd -n ACCOUNT -d DIR -s SHELL -m -w no
NetBSD    useradd -m -d DIR -s SHELL ACCOUNT
```

NetBSD rejects `*` as an encrypted password and rewrites it:

```text
useradd: Password `*' is invalid: setting it to `*************'
```

Its default with no `-p` is that same locked field — measured rather
than assumed, by creating a throwaway account without `-p` and reading
`/etc/master.passwd`, which gave a byte-identical
`probeuser:*************`. So `-p '*'` bought nothing here but a line of
noise in the log, and is omitted.

### Privilege escalation has no native tool here

NetBSD ships neither `doas` nor `sudo`: `man.netbsd.org` has no
`doas.1` or `sudo.8`, base offers only `su(1)`, and both tools come from
pkgsrc. So unlike OpenBSD — where `doas` is in base and is the
documented mechanism — there is no platform-native answer to match.

With no native tool to match, the default is `sudo`, which has the
stronger claim here on two counts: pkgsrc prominence and history, and
being the one `ansible-core` supports without the `community.general`
collection. Defaulting to `doas` would mean imposing a controller-side
dependency in order to use the *less* conventional tool. See
[the repository README](../README.md#which-escalation-tool-and-why-it-differs-per-platform)
for the full reasoning.

This platform was first implemented with `doas`, for reuse of the
engine's existing `doas.conf` writer; the engine now holds a writer for
each style and the adapter supplies only paths. The `sudo` one is the
simpler shape — a drop-in is a file this service owns outright — at the
cost of having no marker to recognise its own work by, so drift is
detected by comparing content, ownership and mode instead. On NetBSD
that distinction was worth confirming directly, because `sudo` silently
ignores a drop-in it does not trust:

```text
sudo: /usr/pkg/etc/sudoers.d/ansible-bootstrap is owned by uid 1001, should be 0
```

### Package access has to be derived

A stock installation has **no `PKG_PATH`** and nothing under
`/usr/pkg`. Both predecessors arrived with working package access; this
one does not, and because the escalation tool is also a package,
privilege escalation depends on fixing that. FreeBSD's inversion was "escalation needs the
package manager"; NetBSD's is "escalation needs the package manager,
which needs configuring first".

The adapter derives the repository URL and exports it **for its own
calls only** — never written to the host, because choosing a mirror is
general host configuration and belongs to Ansible. An administrator's
own `PKG_PATH` wins.

```text
https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/$(sysctl -n hw.machine_arch)/$(uname -r)/All/
```

Two traps in that URL. The architecture must come from
`hw.machine_arch`, which reports `aarch64`; `uname -m` reports the port
name `evbarm`, for which no repository exists. And the release path
redirects — `11.0` to `11.0_2026Q2` — which both `ftp` and `pkg_add`
follow.

### Listing available interpreters

pkgsrc's tools have no remote-listing query. `pkg_info -r` reports
`can't find package` for something the repository plainly has, and there
is no pkgin on a stock install, so the repository index is fetched and
parsed directly.

Names carry the version twice — `python314-3.14.6.tgz` — so the stem is
what `pkg_add` is given and the dotted version is what the engine's
range is applied to. The guest offered 3.10 through 3.14, with no
pre-release and no free-threaded variants, so `PYTHON_MAX=3.14` selects
`python314`.

## Validation

The plan in the repository README applies unchanged. Done on an 11.0
aarch64 guest: a pristine install reaching all five invariants,
`adapter_escalation_prepare` installing `doas` from pkgsrc,
`lib/controller-test.sh -a` at 10/10, the `rc.conf` marked block, the
`rc.d` hook at boot, and every adapter function including
`adapter_service_start`.

Two remain. Both need the console, because both can leave the host
unreachable if the repair they exercise does not work.

### Drift repaired unattended at boot

Disable `sshd` by changing the administrator's own assignment rather
than appending one. That matters: the engine writes its `sshd=YES` into
a marked block at the end of `rc.conf`, and `rc.conf` is last-wins, so
an assignment appended *after* that block would outrank the repair and
the engine would correctly report a conflict instead of fixing it.
Editing the existing line is also what an administrator would actually
do.

```sh
sed 's/^sshd=YES$/sshd=NO/' /etc/rc.conf > /tmp/rc.new
cp /tmp/rc.new /etc/rc.conf && rm /tmp/rc.new
service -e sshd && echo STILL-ENABLED || echo disabled
reboot
```

`sed -i` is avoided deliberately — its argument handling differs across
the BSDs, and this is a file that breaks boot if mangled.

Expect **two** changes in the log, `Enabling sshd` then `Starting
sshd`, the console showing both announce lines, and the host reachable
from the controller afterwards. `rc` skips the disabled `sshd` but
`rcorder` still places the hook after it, so the hook runs and repairs
both facts.

If SSH is dead afterwards, the hook did not run when a service it
`REQUIRE`s was skipped — which would be a genuine ordering bug and
worth knowing. Recover with `service ansible_bootstrap onestart`.

### A boot with the package repository unreachable

The only path that exercises `run_bounded`'s timeout for real. A
misconfigured repository fails fast and does not test the bound, so
`ftp` has to be made to hang — the adapter fetches the package index
with it, and the engine's `PATH` starts with `/sbin`:

```sh
sed 's/^PKG_TIMEOUT=300$/PKG_TIMEOUT=15/' /usr/local/libexec/ansible-bootstrap > /tmp/e
cp /tmp/e /usr/local/libexec/ansible-bootstrap && rm /tmp/e
pkg_delete python314                      # so apply must reach the repository
printf '#!/bin/sh\nsleep 600\n' > /sbin/ftp
chmod +x /sbin/ftp
reboot
```

Expect the console to show `FAILED`, the log to carry `Exceeded 15s;
terminating: ftp -o - …` followed by `Could not query the package
repository within 15s`, **boot to complete normally**, and SSH to still
work — only Python is broken. That last part is the whole purpose of
bounding the operation.

Clean up promptly; `/sbin/ftp` shadows `ftp` for everything:

```sh
rm -f /sbin/ftp
cd /path/to/checkout/NetBSD && ./install.sh --enable-boot-hook
```

The reinstall restores `PKG_TIMEOUT=300` along with the engine, and its
`apply` reinstalls `python314`.

Worth knowing before running it: with `PKG_TIMEOUT=300` and two bounded
calls — `ftp` for the index, `pkg_add` for the install — a dead
repository costs around ten minutes of boot delay. The bound holds, but
the default is worth reconsidering now that it means something.
