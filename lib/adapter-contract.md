# OS adapter contract

`lib/ansible-bootstrap` is platform-independent. Each supported
operating system supplies an adapter — `OpenBSD/adapter.sh`,
`FreeBSD/adapter.sh` — which the engine sources as root after checking
that it is a regular file owned by `root:wheel`, mode `0700`, and not a
symbolic link.

An adapter is **code executed with full privilege**, not configuration.
It is verified before it is read for the same reason the repository
README forbids sourcing an untrusted configuration file as shell.

Adapters have no shebang and are not executable: they are only ever
sourced. They may call any engine function — `log`, `changed`, `die`,
`run_bounded` — because shell functions resolve at call time, so the
engine's definitions are available even though they appear after the
`.` that loads the adapter.

## What belongs where

The dividing line is **mechanism versus policy**. How to create an
account is a platform mechanism; that the account is called `ansible`
and needs a home it owns is contract, and stays in the engine.
Likewise, how to list available packages is a mechanism; which Python
versions are acceptable is Ansible policy, and stays in the engine.

Resist widening this. Two operating systems do not justify a framework,
and every function moved here is one the engine can no longer reason
about.

## Constants an adapter must set

| Constant | Meaning |
| --- | --- |
| `LOGIN_SHELL` | Login shell for the service account. `/bin/ksh` on OpenBSD; FreeBSD has no ksh in base. |
| `DOAS_BIN` | Absolute path to `doas`. `/usr/bin/doas` in the OpenBSD base system; under `/usr/local/bin` when it comes from a package. |
| `DOAS_CONF` | Absolute path to `doas.conf`. `/etc/doas.conf` on OpenBSD; `/usr/local/etc/doas.conf` for a packaged doas. |

An adapter may also reassign `PYTHON_DIR` if its packages install
interpreters somewhere other than `/usr/local/bin`.

## Functions an adapter must define

### `adapter_create_account`

Create the account named by `$ACCOUNT`, with home `$HOME_DIR` and shell
`$LOGIN_SHELL`, and **no usable password** — public-key authentication
is configured separately by the engine. Called only when the account
does not already exist; the engine verifies the result itself and
reports a conflict rather than correcting an account an administrator
made differently.

### `adapter_escalation_prepare`

Ensure the `doas` binary exists, before the engine writes any policy.
A no-op on OpenBSD, where doas is in the base system.

This exists because the dependency inverts on FreeBSD: doas is a
package there, so privilege escalation cannot be configured until the
package manager has worked and the repository was reachable. On
OpenBSD escalation is always configurable; on FreeBSD it is not.

### `adapter_service_enabled NAME`, `adapter_service_running NAME`

True when the named service is enabled for boot, and when it is
currently running. Two separate questions: a service can be running but
not survive a reboot, which would satisfy a naive check and then fail
the contract at the next boot.

Keep these cheap. On OpenBSD, `rcctl get <svc> status` answers the first
in well under a second while `rcctl ls on` takes 22 — the latter was
once responsible for a 24-second `check`.

### `adapter_service_enable NAME`, `adapter_service_start NAME`

Enable the service for boot, and start it. The engine records the
change before calling, so these need not log. Discard stdout if the
platform's tool writes progress there: `rcctl` emits a bare daemon name
with no trailing newline, which corrupts the following line in the log.

### `adapter_python_packages`

Print one line per installable Python interpreter the repository
offers, as:

```text
<package-name> <major> <minor>
```

for example `python-3.13.13 3 13` on OpenBSD. The engine applies
`PYTHON_MIN` and `PYTHON_MAX` and picks the newest match, so an adapter
must not filter by version itself — only parse names into versions.

Return non-zero if the repository could not be queried. Do not confuse
that with an empty result: the engine treats no output as a failed
query too, because a reachable repository always offers interpreters,
and at least one package tool reports a failure this way while still
exiting zero.

Bound the query with `run_bounded "$PKG_TIMEOUT"`, and capture its
output before filtering — piping it into `awk` would replace its exit
status with `awk`'s and hide a timeout.

### `adapter_package_install NAME`

Install exactly the named package. The engine passes a fully qualified
name, which matters where an unqualified one is ambiguous: `pkg_add
python` prompts to choose between 2.7 and 3.x, and at boot a prompt is
a hang.

Bound it with `run_bounded "$PKG_TIMEOUT"`. Its exit status is
advisory — the engine re-runs interpreter discovery afterwards and
treats that as the gate, because OpenBSD's `pkg_add` reports a package
it cannot find as a warning and still exits zero.
