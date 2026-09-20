# OpenBSD implementation — Ansible bootstrap service

This directory contains the OpenBSD implementation of the [Ansible
Bootstrap Service](../README.md). Its sole job is to keep a freshly
installed or subsequently damaged OpenBSD host **reachable and
provisionable by Ansible**. It runs a short reconciliation pass at
boot and exits; it is not a resident daemon and does not replace
Ansible.

> **Status:** Validated once on an OpenBSD 7.9 guest, against a
> controller running `ansible-core` 2.21. A fresh host reached all five
> invariants, and from the controller: key-only SSH login as `ansible`,
> `doas -n id -u` returning `0`, `ansible -m ping` succeeding, `become`
> via `community.general.doas` reaching root, and fact gathering
> reporting the interpreter this service installed.
>
> Not yet exercised: **a reboot**, so the `rc.local` hook has never
> actually run at boot; drift repair on a host that has diverged; and
> any release other than 7.9. Treat it as a working prototype rather
> than a tested release, and see the checklist at the end for the
> assumptions that remain unconfirmed.

## Readiness contract

| Prerequisite | OpenBSD implementation | Verification goal |
| --- | --- | --- |
| SSH service | Base-system `sshd`, managed with `rcctl` | `sshd -t` succeeds; service is enabled and running. |
| Service account | Dedicated `ansible` user, `/home/ansible`, login shell `/bin/ksh` | Account exists, has expected home and shell, is not administratively disabled, and can authenticate using the configured key. |
| SSH public-key access | Root-owned bootstrap key source; account-owned `~ansible/.ssh/authorized_keys` | Configured key is present as an ordinary, unrestricted entry; ownership and permissions are safe. |
| Python | OpenBSD package repository via `pkg_add` | A Python interpreter compatible with the controller's `ansible-core` is executable; report its absolute path. |
| Privilege escalation | Base-system `doas` | As `ansible`, `doas -n /usr/bin/id -u` succeeds and returns `0`. |

The service must not manage the firewall, general SSH policy, other
accounts, applications, or unrelated packages. If an existing account
or SSH configuration conflicts with the readiness contract, report the
conflict instead of silently overwriting an intentional administrative
change.

## Files and ownership

The initial single-script layout is:

```text
/usr/local/libexec/ansible-bootstrap    # root-owned executable, mode 0700
/etc/ansible-bootstrap/                 # root-owned directory, mode 0700
/etc/ansible-bootstrap/controller.pub   # root-owned public key, mode 0600
/home/ansible/.ssh/                     # ansible-owned directory, mode 0700
/home/ansible/.ssh/authorized_keys      # ansible-owned file, mode 0600
/etc/doas.conf                          # existing system policy; preserve unrelated rules
/etc/rc.local                           # existing local boot script; preserve contents
/var/log/ansible-bootstrap.log          # boot-time output
```

These modes are **verified, not merely set**. `check` asserts the
exact ownership and permissions listed above for the configuration
directory, the stored key, `.ssh`, and `authorized_keys`, so a
successful `check` means `apply` would change nothing — a `check` that
only inspected file contents could report readiness on a host whose
`authorized_keys` was world-writable.

`apply` repairs the paths it owns and re-verifies them, but only those
that are actually wrong, and it logs each repair. Correcting them is
right: this service creates these files and the contract names their
modes. Doing it unconditionally and silently was not, because it hid
the fact that something had changed them and left a no-op `apply`
writing to files it had no need to touch.

The account's home directory is not on that list: its mode belongs to
the administrator. It is checked only against what sshd's
`StrictModes` requires — owned by the account and writable by nobody
else — and a violation is reported rather than corrected, since
public-key authentication cannot work until it is resolved.

Ownership is taken from the account's `passwd` entry, so checking and
setting use one source of truth and neither depends on a group that
happens to share the account name.

The key file contains **one Ed25519 public key** in the initial
implementation. It never contains the private key. The root-owned
source file is the local desired state; `authorized_keys` is the
reconciled destination. Key rotation and multiple controller keys
require an explicit future interface.

The paths above are the current prototype's conventions, not an
OpenBSD packaging standard. A later refactor may split the common
engine from the OpenBSD-specific adapter.

## Initialization and trust

Generate the key pair on the Ansible controller, not the OpenBSD target:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/ansible_ed25519 -C ansible-controller
ssh-keygen -lf ~/.ssh/ansible_ed25519.pub -E sha256
cat ~/.ssh/ansible_ed25519.pub
```

Supply the **public** key to the OpenBSD console or another trusted
installer channel. The engine's `init` accepts it through
`ANSIBLE_PUBLIC_KEY` and optionally accepts an independently obtained
`ANSIBLE_EXPECTED_FINGERPRINT`. Invoking the engine directly, as
below, is the low-level route; `install.sh` prompts for both and is
what [Installation](#installation) uses:

```sh
# On the OpenBSD console, as root; substitute the actual values.
ANSIBLE_PUBLIC_KEY='ssh-ed25519 AAAA... ansible-controller'
ANSIBLE_EXPECTED_FINGERPRINT='SHA256:...'
export ANSIBLE_PUBLIC_KEY ANSIBLE_EXPECTED_FINGERPRINT
/usr/local/libexec/ansible-bootstrap init
unset ANSIBLE_PUBLIC_KEY ANSIBLE_EXPECTED_FINGERPRINT
```

The initializer should validate the key format, calculate its
fingerprint using `ssh-keygen -lf ... -E sha256`, **display and log
the fingerprint**, compare it with the expected value if supplied, and
atomically persist the public key. A mismatched fingerprint must fail
*before* changing the trusted key. If a different key is already
configured, initialization must refuse silent replacement.

A fingerprint is a digest, **not a digital signature**. A fingerprint
supplied through the same compromised channel as a substituted key
does not independently authenticate it. Compare the OpenBSD output
against the fingerprint obtained on the Ansible controller host
through a trusted channel. Public-key values are not secret, but
environment variables can appear in process environments or
diagnostics; avoid putting them in shell history or verbose
logs. Never send the SSH private key to the target.

After initialization, the environment variables are unnecessary:
`apply` and the boot hook read the persisted public key. A future
installer or provider API can populate the same file without changing
the reconciliation engine.

## Installation

### Getting the files onto the host

A freshly installed OpenBSD host has no Git, so fetch an archive with
base-system `ftp(1)`, which speaks HTTPS and follows redirects.
OpenBSD ships `/etc/ssl/cert.pem`, so certificate verification works on
a minimal install with nothing added.

```sh
# As root on the target. Substitute the commit you intend to deploy.
rev=1565d49
ftp -o - "https://codeload.github.com/techn0mad/bsd-ansible-bootstrap/tar.gz/$rev" |
    tar xzf -
cd "bsd-ansible-bootstrap-$rev/OpenBSD"
```

Notes on that command:

- Use `codeload.github.com` rather than the `github.com/.../archive/...`
  URL the web UI offers; the latter is a redirect to the former, so
  only the direct form works with a client that does not follow
  redirects.
- The archive's top-level directory is named `<repository>-<ref>`, so
  it is predictable and there is no need to strip it — just `cd` into
  it. A `refs/heads/NAME` ref appears as just `NAME`.
- **Pass no patterns and no options after `f -`.** OpenBSD's `tar` is
  the `pax` binary and treats trailing arguments as member-name
  patterns, not options, so something like `tar xzf - -s '...'`
  silently extracts *nothing* and warns that the patterns were not
  matched. FreeBSD's `tar` is libarchive and does accept
  `--strip-components=1` there, but the form above needs no such
  option and works on both.
- Executable bits survive the round trip; `install.sh` and
  `ansible-bootstrap` arrive mode 0755.

**Pin a commit or a tag, not a branch.** `refs/heads/main` works
(`.../tar.gz/refs/heads/main`) but resolves to whatever is on that
branch at the moment you run it, which is the wrong property for
something that provisions hosts. Do not pin the *archive's* checksum
either — GitHub has changed archive generation before, churning
checksums for unchanged commits. Pin the ref and verify file contents.

This is the "separately authenticated download" channel described in
[Initialization and trust](#initialization-and-trust) above. Note that
the repository README lists remote execution of arbitrary downloaded
scripts as a non-goal: extract the archive and read what you got, then
run `install.sh` from it. Do not pipe a download into a shell.

### Running the installer

`install.sh` copies the engine into place, runs `init` with the
controller public key, and verifies readiness. It does **not** enable
the boot hook by default. Run it on the console as root, from this
directory, and answer the two prompts:

```text
# ./install.sh

Paste the Ansible controller's PUBLIC key -- the contents of its .pub
file. Never paste a private key: this host must never hold one.

Controller public key: ssh-ed25519 AAAA... ansible-controller

Optionally supply that key's SHA256 fingerprint, obtained from the
controller through a channel independent of the key itself -- one that
travelled with the key proves nothing. Press Enter to skip.

Expected fingerprint: SHA256:...
```

Prompting is the preferred route, and not only for convenience: a key
passed in the environment reaches the shell's history and is visible in
process listings and diagnostics. Nothing typed at these prompts does.
A pasted private key is refused outright, as is an empty response to
the first prompt.

For an unattended install — a provider provisioning hook, or
`/etc/rc.firsttime` — set the values in the environment instead and
they are used without prompting:

```sh
ANSIBLE_PUBLIC_KEY='ssh-ed25519 AAAA... ansible-controller'
ANSIBLE_EXPECTED_FINGERPRINT='SHA256:...'
export ANSIBLE_PUBLIC_KEY ANSIBLE_EXPECTED_FINGERPRINT
./install.sh
unset ANSIBLE_PUBLIC_KEY ANSIBLE_EXPECTED_FINGERPRINT
```

With no terminal to prompt on, a missing `ANSIBLE_PUBLIC_KEY` is an
error rather than a question nobody can answer, so an unattended run
fails immediately instead of hanging. Setting
`ANSIBLE_EXPECTED_FINGERPRINT` to an empty value is honoured as
"deliberately none" and is not prompted for either.

On success the installer prints the `rc.local` snippet it *would*
have added and stops. Work through "Manual validation" below —
especially the controller-side SSH, `doas`, and Ansible tests, which
no local check can substitute for — and only then enable unattended
reconciliation:

```sh
./install.sh --enable-boot-hook
```

Re-running the installer is safe: the engine is reinstalled, `init`
accepts a matching controller key without replacing it, and the boot
hook is appended at most once. The installer refuses to modify
`/etc/rc.local` if it is a symbolic link, and preserves any existing
contents.

## Command interface

```text
ansible-bootstrap init    Validate and persist initial public key; then apply.
ansible-bootstrap check   Inspect readiness without making changes.
ansible-bootstrap apply   Reconcile against the saved key; verify and exit.
```

Run as root. A historical completion marker is not authoritative:
every invocation checks actual state.

### Exit statuses

| Status | Meaning |
| --- | --- |
| `0` | Ready, or reconciliation succeeded. |
| `1` | A prerequisite is missing, or reconciliation failed. |
| `2` | Invalid invocation, or this service's own configuration is absent, malformed, or unsafe. |

The dividing line between `1` and `2` is whether repeating the run
could help. Status `2` means the *inputs* are wrong — no subcommand, a
malformed or absent controller key, a fingerprint mismatch, a
symlinked configuration directory, not running as root — and a retry
will fail identically until a human intervenes. Status `1` means the
*managed host state* is wrong, which a later boot or a manual `apply`
may resolve: a package mirror was unreachable, `sshd` would not start,
a `doas` policy conflict needs resolving.

One consequence worth knowing: `apply` on a host where `init` has
never run exits `2`, because the service is unconfigured rather than
merely unready, while `check` on the same host exits `1`, because it is
reporting readiness. A boot hook can therefore distinguish "never
initialized" from "initialized but drifted".

### Reconciliation order

1. Validate the locally configured public key before creating
   privileged access, and repair its ownership and permissions if they
   have drifted.
2. Create the `ansible` account if absent; verify an existing account
   rather than blindly changing it.
3. Ensure the `.ssh` directory and `authorized_keys` have safe
   ownership and permissions; add the configured key without deleting
   unrelated keys or adding duplicates. Key presence and file
   permissions are separate questions — treating a permission fault as
   a missing key would append a duplicate.
4. Ensure an effective passwordless `doas` rule for the account;
   preserve unrelated `/etc/doas.conf` rules, validate the resulting
   policy before installing it, and report — rather than override — an
   existing rule that names the account.
5. Validate, enable, and start `sshd` as needed.
6. Discover a compatible Python interpreter, preferring the newest one
   already installed; use `pkg_add` only if none qualifies, then
   verify the executable and report its absolute path.
7. Run the complete readiness check and report success only if all
   prerequisites pass.

Reconciliation should not reinstall packages, rewrite files, or append
rules on a second successful `apply`. An interrupted run should be
safe to repeat. Do not mistake an existing file or a successful
configuration parse for proof of usable SSH or privilege escalation.

## OpenBSD-specific mechanisms

**Account:** Use native `useradd` for initial creation and the system
account database for inspection. The login shell is `/bin/ksh`; the
bootstrap program itself uses `#!/bin/sh`. An existing account with
unexpected home/shell or a deliberate administrative lock is a
conflict to report, not an invitation to override it
automatically. Confirm actual account-database and group behavior on
the target release before relying on a particular `getent`, `useradd`,
or `chown` invocation.

**SSH:** Use `/usr/sbin/sshd -t` to check the configuration and
`rcctl` to inspect, enable, and start the service. The presence of a
key in `authorized_keys` does not alone establish that SSH login
works: global `sshd_config`, `Match` rules, account state, file
permissions, or network policy may prevent access. Verify a real
controller-to-host login before enabling unattended boot
execution. The service should report policy conflicts rather than
broadly rewrite `sshd_config`.

Matching an entry in `authorized_keys` compares key type and base64
material only, never the comment. Two questions are asked separately:

- Is the key present as an **ordinary, unrestricted entry**? That is
  what the readiness contract requires, and it is what `check`
  reports on.
- Does the key material appear **at all**, including behind options
  such as `from=` or `command=`?

The second question exists so that a key already present but
restricted is reported as a conflict instead of being joined by an
unrestricted second copy — appending one would both duplicate the key
and quietly override a deliberate administrative narrowing. Because
options may be quoted and contain spaces, the key is located by
scanning for the type immediately followed by its material rather than
by assuming it starts the line. Commented-out entries count as absent
in both cases, so a disabled historical entry neither satisfies the
contract nor blocks installing a live one.

Pre-existing duplicate entries are not treated as a conflict: they are
harmless to authentication, and failing on them would leave `check`
reporting a fault that `apply` has no safe way to repair. The
guarantee is narrower and more useful — this service never creates a
duplicate.

**`doas`:** OpenBSD includes `doas` in the base system. The intended
managed policy is `permit nopass ansible as root`, but the effective
result depends on the full rule ordering. Check it by executing a
harmless noninteractive command *as the Ansible account*; `doas -C` by
itself is not a substitute for this test. Changes to `/etc/doas.conf`
must preserve unrelated policy and be validated before atomic
replacement.

That test uses a **non-login** shell (`su ansible -c ...`, not `su -`).
A login shell would source `/etc/profile` and `~/.profile`, and their
output would be captured along with the command's, so the check would
fail permanently on a host where `doas` works. A non-login shell is
also the more faithful test: Ansible runs `ssh host command`, which is
not a login shell either. The command's whole output must be exactly
`0` — matching loosely to tolerate stray output would risk reading a
bare `0` printed by something else as proof of success, and failing on
unexpected output is the safer direction.

The managed rule is written as a marked block appended to the end of
the file, where the last matching rule wins:

```text
# BEGIN ansible-bootstrap
permit nopass ansible as root
# END ansible-bootstrap
```

The markers exist so a later run can recognize its own work. If the
block is already present and `doas -n` still fails, the cause is
something this service must not paper over — a later overriding rule,
or an unusable account — so it reports the conflict and exits nonzero
instead of appending a second copy. A boot-time reconciler that
appended on every failed check would otherwise grow `/etc/doas.conf`
without bound. For the same reason, an existing rule that names the
account but does not grant passwordless root is treated as deliberate
administrator policy: it is reported, not outranked. The v0.2 marker
(`# Managed by ansible-bootstrap`) is still recognized, so upgrading
an existing host does not append a duplicate.

**Python:** OpenBSD's Python packages and versioned executable names
change between releases, so no single interpreter path is assumed.
Compatibility is a version range declared at the top of the script:

```sh
PYTHON_MIN=3.9          # managed-node range of the controller's ansible-core
PYTHON_MAX=3.14         # empty would mean no upper bound
PYTHON_PACKAGE_STEM=python     # exact version comes from the repository
PYTHON_DIR=/usr/local/bin      # where packages put interpreters
```

The range is set for **`ansible-core` 2.21**, which supports managed
nodes on Python 3.9 through 3.14. It is not universal OpenBSD or
Ansible policy: re-derive it from the [support
matrix](https://docs.ansible.com/ansible-core/devel/reference_appendices/release_and_maintenance.html)
whenever the controller's `ansible-core` changes. "Python 3 exists" is
not the test, and leaving `PYTHON_MAX` empty is wrong for every
released `ansible-core`, since each has a ceiling. No package
*version* is hardcoded, so an OpenBSD release bump does not by itself
break installation.

> **The target release constrains the controller.** OpenBSD 7.9
> packages only Python 2.7 and 3.13 — there is no 3.12 — so a stock
> 7.9 host can only be managed by `ansible-core` **2.18 or newer**.
> 2.17 and earlier cap managed nodes at 3.12, and no amount of
> configuration here can work around a version the release does not
> ship. Check the target's `pkg_info -Q python` against the matrix
> before assuming an older controller will do.

Discovery runs before installation. The script globs `python3.N` and
`python3.NN` in `PYTHON_DIR`, tries the newest first, and asks each
candidate to evaluate the range itself, so nothing depends on parsing
a file name. Only versioned names are considered: an unversioned
`python3` symlink may be absent, and its target can change underneath
the inventory. Nothing is installed when a candidate qualifies, which
is what keeps repeated boots from causing package churn.

When none qualifies, the *available* package is discovered the same
way rather than assumed. `pkg_info -Q python` is matched against the
configured range and the newest result is installed by its fully
qualified name. Two traps make that less obvious than it sounds:

- `pkg_info -Q` matches substrings, so its output also contains
  unrelated packages (`bpython`, `py3-GitPython`), subpackages
  (`python-tkinter-3.13.13`), and debug packages
  (`debug-python-3.13.13`). Only lines where the stem is followed
  immediately by a digit are the interpreter itself.
- An unqualified stem is ambiguous. `pkg_add python` prompts to choose
  between 2.7 and 3.x, which at boot would mean waiting on input that
  never arrives. Installing the fully qualified name removes the
  prompt outright, rather than depending on what `pkg_add` does when
  its stdin is closed.

`pkg_add`'s exit status is **not** treated as proof of success. On
OpenBSD 7.9 it reports a package it cannot find as a warning and still
exits `0`. A non-zero status is logged, but the gate is re-running
interpreter discovery afterwards and confirming a usable interpreter
now exists.

For the same reason the query is judged by its output rather than only
its status: an empty result is read as a failed query, since any
reachable repository returns many packages matching `python` as a
substring. `run_bounded` itself is sound — OpenBSD `/bin/sh` does
preserve a background job's exit status under `set -m` — so a status
that does arrive can be believed; it is the package tools that report
failure inconsistently.

Both package operations — the query and the install — are bounded by
`PKG_TIMEOUT` (300 seconds). Each runs in its own process group with
stdin closed, so an unreachable mirror is terminated together with the
fetch process it spawned, and a tool that decides to ask a question
fails instead of waiting at boot for an answer that will never
come. Being unable to *reach* the repository and the repository having
nothing *suitable* are reported differently, because they need
different fixes. The failure is logged with the network
and `PKG_PATH` causes to check, `apply` exits `1`, and boot continues;
a later boot or a manual `apply` retries. The shell may add its own
job-control notice (`Terminated: 15`) to the log when it reaps the
killed process.

`check` reports the chosen absolute path in inventory form:

```text
ansible-bootstrap: python: OK (ansible_python_interpreter=/usr/local/bin/python3.13)
```

Use that path rather than an assumed one. A machine-readable status
output remains future work; for now the boot log is the record.

## Boot integration

OpenBSD's `/etc/rc.local` is the proposed ongoing boot hook. Unlike
`/etc/rc.firsttime`, it runs on subsequent boots and therefore
supports drift repair. Preserve any existing `rc.local` contents and
append only one invocation:

```sh
# BEGIN ansible-bootstrap
# Maintain Ansible readiness; this is a short-lived boot task.
if [ -x /usr/local/libexec/ansible-bootstrap ]; then
    /usr/local/libexec/ansible-bootstrap apply >> /var/log/ansible-bootstrap.log 2>&1
fi
# END ansible-bootstrap
```

`install.sh --enable-boot-hook` writes exactly this block, and the
marker comments let a later run recognize it instead of appending a
second copy. Adding it by hand is equally supported; keep the markers
so the installer stays idempotent.

Enable this **only after** manual `init`, `check`, `apply`, SSH login,
and `doas` tests succeed — which is why the installer withholds the
hook unless you ask for it. `rc.local` is a startup script, not a
supervised service manager: an unavailable package mirror or stalled
command can delay boot. Package operations are therefore bounded (see
**Python** above) so failures are logged and return control to the
boot sequence. An unsuccessful run must not remove console access; a
later boot or manual `apply` retries.

`/etc/rc.firsttime` remains useful for *installing* the bootstrap
files during OS installation, but is not the ongoing reconciliation
mechanism.

## Manual validation

Use a disposable VM or snapshot. Do not rely on the prototype until
these tests pass:

1. Install the script and supply a known controller public key;
   confirm the logged `SHA256:...` fingerprint matches the controller.
2. Supply a malformed key and then a mismatched expected fingerprint;
   confirm neither replaces the trusted key.
3. Run `check` on a fresh installation: it reports missing
   prerequisites without changing state.
4. Run `apply`, then run it again: no duplicate authorized keys,
   duplicate `doas` rules, or unnecessary package operations.
5. From the Ansible controller, SSH as `ansible` using only the
   intended private key; run `doas -n id -u` and confirm output `0`.
6. Take the path `check` reports as
   `ansible_python_interpreter=...`, run it by absolute path, and test
   an Ansible `ping` module with that path in inventory. Separately,
   install a second compatible interpreter and confirm `apply` uses
   the existing one instead of running `pkg_add`.
7. Remove only the managed authorized key, then separately
   stop/disable `sshd` and remove every compatible Python interpreter
   in disposable test cases; confirm each missing prerequisite is
   repaired without unrelated changes.
8. Simulate an interrupted run and an unavailable package repository;
   confirm failures are bounded, diagnosable, and recoverable.
9. Only then add the `rc.local` hook — `./install.sh
   --enable-boot-hook` — reboot, inspect
   `/var/log/ansible-bootstrap.log`, and confirm normal login and boot
   behavior.

Example controller-side connection test:

```sh
ssh -i ~/.ssh/ansible_ed25519 -o IdentitiesOnly=yes \
    ansible@OPENBSD_VM_IP 'doas -n id -u; PYTHON --version'
```

Substitute the interpreter path that `check` reported for `PYTHON`.
For Ansible inventory, use that verified path rather than assuming an
unversioned `python3` symlink exists.

## Known prototype gaps / implementation checklist

A full install and a controller-side Ansible run have now succeeded on
OpenBSD 7.9 (see **Status** above). What follows is what that single
run did *not* establish. Before calling this directory
production-ready, work through at least the following:

- Reboot a host with the hook enabled and confirm `apply` runs from
  `rc.local`, logs meaningful status, and does not delay or block
  boot. **Nothing has ever exercised the boot path.**
- Exercise drift repair against a host that has diverged, not only a
  fresh one: remove the managed authorized key, stop and disable
  `sshd`, and remove the interpreter, each independently.

- Confirm OpenBSD 7.9 availability and exact behavior of every
  account-management, package, and `doas` command used.
- Re-derive `PYTHON_MIN` and `PYTHON_MAX` whenever the controller's
  `ansible-core` changes. The committed values suit 2.21; an older
  controller has a lower ceiling, and one older than 2.18 cannot
  manage a stock OpenBSD 7.9 host at all.
- Ensure temporary-file cleanup and traps work correctly with OpenBSD
  `/bin/sh`, including the successful `init` path.
- Distinguish deliberate account disablement and SSH policy conflicts
  from repairable missing configuration.
- Confirm `set -m` job control and process-group signalling behave as
  expected in OpenBSD `/bin/sh`; `run_bounded` relies on them to
  terminate `pkg_add` together with its fetch process.
- Treat any package tool's exit status as advisory. `pkg_add` reports a
  package it cannot find as a warning and still exits `0` (confirmed on
  7.9), so success must be established by re-checking actual state, and
  a query that returns nothing must be read as a failed query rather
  than an empty repository.
- The `ftp` and `tar` invocation under "Getting the files onto the
  host" has been run on OpenBSD. Note that OpenBSD `tar` is the `pax`
  binary: arguments after `f -` are member-name patterns, not options,
  and unmatched patterns mean nothing is extracted. Do not reintroduce
  a `-s` or `--strip-components` form there.

The repository-wide [README](../README.md) defines the cross-platform
contract. This document defines the OpenBSD-specific implementation
and test expectations; changes to the contract should be reflected in
both files.
