# NetBSD implementation — Ansible bootstrap service

> **Status:** A pristine 11.0 aarch64 guest reached all five invariants
> in nine changes: key stored, account created, controller key
> installed, `.ssh` and `authorized_keys` ownership set, `doas`
> installed from pkgsrc, `/usr/pkg/etc` created, passwordless `doas`
> configured, and `python314` installed at `/usr/pkg/bin/python3.14`.
> One more change than FreeBSD, the extra being the `PKG_SYSCONFDIR`
> that pkgsrc does not create.
>
> `lib/controller-test.sh -a` then passed 10/10 against that host,
> unmodified — the same script the other two platforms use. The
> `rc.conf` marked block, this platform's most distinctive mechanism,
> was exercised by appending a last-wins `sshd=NO`: `check` reported
> `sshd: NOT READY`, `apply` wrote the block, and the result was still
> valid shell.
>
> Seven of the eight adapter functions have run on hardware. Only
> `adapter_service_start` has not, since that needs `sshd` stopped and
> so console access. Not yet exercised either: the `rc.d` boot hook,
> which the first install deliberately withheld.
>
> The shared engine, installer and controller-side tests are byte-identical
> to what [OpenBSD](../OpenBSD/README.md) and
> [FreeBSD](../FreeBSD/README.md) run; the repository-wide
> [README](../README.md) defines the contract all three satisfy.

## What this contains

```text
NetBSD/
├── README.md
├── adapter.sh       # engine adapter: accounts, packages, services, doas paths
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
| `doas` | **not present at all**, and no `doas.conf` anywhere — must come from pkgsrc |
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

### pkgsrc does not create its own PKG_SYSCONFDIR

The `doas` package installs the binary setuid root at
`/usr/pkg/bin/doas` and an example under `share`, but **not
`/usr/pkg/etc`**. The config path is compiled into the binary —

```sh
$ strings /usr/pkg/bin/doas | grep -i doas.conf
/usr/pkg/etc/doas.conf
```

— so it is that directory or nothing, and the adapter creates it after
installing the package.

Without it the first install fails in a way that says nothing about the
cause:

```text
ansible-bootstrap: change: Configuring passwordless doas
mktemp: mkstemp failed on /usr/pkg/etc/doas.conf.9yAGLCIP: No such file or directory
ansible-bootstrap: ERROR: Cannot create temporary doas configuration
```

The engine reports only that it could not create a temporary file,
because from its point of view that is all that happened. Neither
predecessor could surface this: OpenBSD's `doas.conf` lives in `/etc`,
which always exists, and FreeBSD's package creates
`/usr/local/etc` itself.

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

### Package access has to be derived

A stock installation has **no `PKG_PATH`** and nothing under
`/usr/pkg`. Both predecessors arrived with working package access; this
one does not, and because `doas` is also a package, privilege escalation
depends on fixing that. FreeBSD's inversion was "escalation needs the
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

The plan in the repository README applies unchanged. Nothing below has
been done yet:

- A fresh install reaching all five invariants.
- `lib/controller-test.sh -a` from the controller.
- `adapter_escalation_prepare` installing `doas` on a host that does not
  have it, which is the step this platform depends on most.
- Drift repair, by hand and then unattended at boot.
- `rcorder` placement of the installed hook, confirmed before a reboot
  rather than after.
