# OpenBSD implementation — Ansible bootstrap service

This directory contains the OpenBSD implementation of the [Ansible Bootstrap Service](../README.md). Its sole job is to keep a freshly installed or subsequently damaged OpenBSD host **reachable and provisionable by Ansible**. It runs a short reconciliation pass at boot and exits; it is not a resident daemon and does not replace Ansible.

> **Status:** Implementation design and an early v0.2 prototype, initially targeted at an OpenBSD 7.9 guest. The prototype shown in the project discussion has **not** been validated end to end. Do not enable it at boot on a production host until the platform commands, failure paths, and tests below have been verified. This document describes the intended behavior and calls out gaps in that prototype rather than asserting they are already implemented.

## Readiness contract

| Prerequisite | OpenBSD implementation | Verification goal |
| --- | --- | --- |
| SSH service | Base-system `sshd`, managed with `rcctl` | `sshd -t` succeeds; service is enabled and running. |
| Service account | Dedicated `ansible` user, `/home/ansible`, login shell `/bin/ksh` | Account exists, has expected home and shell, is not administratively disabled, and can authenticate using the configured key. |
| SSH public-key access | Root-owned bootstrap key source; account-owned `~ansible/.ssh/authorized_keys` | Configured key is present exactly once as a usable key entry; ownership and permissions are safe. |
| Python | OpenBSD package repository via `pkg_add` | A Python interpreter compatible with the controller's `ansible-core` is executable; report its absolute path. |
| Privilege escalation | Base-system `doas` | As `ansible`, `doas -n /usr/bin/id -u` succeeds and returns `0`. |

The service must not manage the firewall, general SSH policy, other accounts, applications, or unrelated packages. If an existing account or SSH configuration conflicts with the readiness contract, report the conflict instead of silently overwriting an intentional administrative change.

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

The key file contains **one Ed25519 public key** in the initial implementation. It never contains the private key. The root-owned source file is the local desired state; `authorized_keys` is the reconciled destination. Key rotation and multiple controller keys require an explicit future interface.

The paths above are the current prototype's conventions, not an OpenBSD packaging standard. A later refactor may split the common engine from the OpenBSD-specific adapter.

## Initialization and trust

Generate the key pair on the Ansible controller, not the OpenBSD target:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/ansible_ed25519 -C ansible-controller
ssh-keygen -lf ~/.ssh/ansible_ed25519.pub -E sha256
cat ~/.ssh/ansible_ed25519.pub
```

Supply the **public** key to the OpenBSD console or another trusted installer channel. The proposed `init` interface accepts it through `ANSIBLE_PUBLIC_KEY` and optionally accepts an independently obtained `ANSIBLE_EXPECTED_FINGERPRINT`:

```sh
# On the OpenBSD console, as root; substitute the actual values.
ANSIBLE_PUBLIC_KEY='ssh-ed25519 AAAA... ansible-controller'
ANSIBLE_EXPECTED_FINGERPRINT='SHA256:...'
export ANSIBLE_PUBLIC_KEY ANSIBLE_EXPECTED_FINGERPRINT
/usr/local/libexec/ansible-bootstrap init
unset ANSIBLE_PUBLIC_KEY ANSIBLE_EXPECTED_FINGERPRINT
```

The initializer should validate the key format, calculate its fingerprint using `ssh-keygen -lf ... -E sha256`, **display and log the fingerprint**, compare it with the expected value if supplied, and atomically persist the public key. A mismatched fingerprint must fail *before* changing the trusted key. If a different key is already configured, initialization must refuse silent replacement.

A fingerprint is a digest, **not a digital signature**. A fingerprint supplied through the same compromised channel as a substituted key does not independently authenticate it. Compare the OpenBSD output against the fingerprint obtained on the Ansible controller host through a trusted channel. Public-key values are not secret, but environment variables can appear in process environments or diagnostics; avoid putting them in shell history or verbose logs. Never send the SSH private key to the target.

After initialization, the environment variables are unnecessary: `apply` and the boot hook read the persisted public key. A future installer or provider API can populate the same file without changing the reconciliation engine.

## Command interface

```text
ansible-bootstrap init    Validate and persist initial public key; then apply.
ansible-bootstrap check   Inspect readiness without making changes.
ansible-bootstrap apply   Reconcile against the saved key; verify and exit.
```

Run as root. Intended status codes are `0` for ready/success, `1` for missing prerequisites or failed reconciliation, and `2` for invalid invocation/configuration; the prototype's exact error codes still need normalization. A historical completion marker is not authoritative: every invocation checks actual state.

### Reconciliation order

1. Validate the locally configured public key before creating privileged access.
2. Create the `ansible` account if absent; verify an existing account rather than blindly changing it.
3. Ensure the `.ssh` directory and `authorized_keys` have safe ownership and permissions; add the configured key without deleting unrelated keys or adding duplicates.
4. Ensure an effective passwordless `doas` rule for the account; preserve unrelated `/etc/doas.conf` rules and validate the resulting policy before installing it.
5. Validate, enable, and start `sshd` as needed.
6. Discover a compatible Python interpreter; use `pkg_add` only if needed, then verify the executable and report its path.
7. Run the complete readiness check and report success only if all prerequisites pass.

Reconciliation should not reinstall packages, rewrite files, or append rules on a second successful `apply`. An interrupted run should be safe to repeat. Do not mistake an existing file or a successful configuration parse for proof of usable SSH or privilege escalation.

## OpenBSD-specific mechanisms

**Account:** Use native `useradd` for initial creation and the system account database for inspection. The login shell is `/bin/ksh`; the bootstrap program itself uses `#!/bin/sh`. An existing account with unexpected home/shell or a deliberate administrative lock is a conflict to report, not an invitation to override it automatically. Confirm actual account-database and group behavior on the target release before relying on a particular `getent`, `useradd`, or `chown` invocation.

**SSH:** Use `/usr/sbin/sshd -t` to check the configuration and `rcctl` to inspect, enable, and start the service. The presence of a key in `authorized_keys` does not alone establish that SSH login works: global `sshd_config`, `Match` rules, account state, file permissions, or network policy may prevent access. Verify a real controller-to-host login before enabling unattended boot execution. The service should report policy conflicts rather than broadly rewrite `sshd_config`.

**`doas`:** OpenBSD includes `doas` in the base system. The intended managed policy is `permit nopass ansible as root`, but the effective result depends on the full rule ordering. Check it by executing a harmless noninteractive command *as the Ansible account*; `doas -C` by itself is not a substitute for this test. Avoid appending the same rule on every failed check. Changes to `/etc/doas.conf` must preserve unrelated policy and be validated before atomic replacement.

**Python:** OpenBSD's Python packages and versioned executable names change between releases. The prototype pins `python%3.13` and `/usr/local/bin/python3.13`; these are **prototype assumptions**, not a universal OpenBSD policy. Confirm package availability on the target release and the managed-node Python requirements of the selected `ansible-core` version. Prefer an already installed compatible interpreter; otherwise install one with `pkg_add`. Report the absolute path for `ansible_python_interpreter`.

## Boot integration

OpenBSD's `/etc/rc.local` is the proposed ongoing boot hook. Unlike `/etc/rc.firsttime`, it runs on subsequent boots and therefore supports drift repair. Preserve any existing `rc.local` contents and append only one invocation:

```sh
# Maintain Ansible readiness; this is a short-lived boot task.
if [ -x /usr/local/libexec/ansible-bootstrap ]; then
    /usr/local/libexec/ansible-bootstrap apply \
        >> /var/log/ansible-bootstrap.log 2>&1
fi
```

Enable this **only after** manual `init`, `check`, `apply`, SSH login, and `doas` tests succeed. `rc.local` is a startup script, not a supervised service manager: an unavailable package mirror or stalled command can delay boot. Before production use, implement bounded network/package operations and ensure failures are logged and return control to the boot sequence. An unsuccessful run must not remove console access; a later boot or manual `apply` should be able to retry.

`/etc/rc.firsttime` remains useful for *installing* the bootstrap files during OS installation, but is not the ongoing reconciliation mechanism.

## Manual validation

Use a disposable VM or snapshot. Do not rely on the prototype until these tests pass:

1. Install the script and supply a known controller public key; confirm the logged `SHA256:...` fingerprint matches the controller.
2. Supply a malformed key and then a mismatched expected fingerprint; confirm neither replaces the trusted key.
3. Run `check` on a fresh installation: it reports missing prerequisites without changing state.
4. Run `apply`, then run it again: no duplicate authorized keys, duplicate `doas` rules, or unnecessary package operations.
5. From the Ansible controller, SSH as `ansible` using only the intended private key; run `doas -n id -u` and confirm output `0`.
6. Run the installed Python by absolute path and test an Ansible `ping` module with that path in inventory.
7. Remove only the managed authorized key, then separately stop/disable `sshd` and remove the managed Python package in disposable test cases; confirm each missing prerequisite is repaired without unrelated changes.
8. Simulate an interrupted run and an unavailable package repository; confirm failures are bounded, diagnosable, and recoverable.
9. Only then add the `rc.local` hook, reboot, inspect `/var/log/ansible-bootstrap.log`, and confirm normal login and boot behavior.

Example controller-side connection test:

```sh
ssh -i ~/.ssh/ansible_ed25519 -o IdentitiesOnly=yes \
    ansible@OPENBSD_VM_IP 'doas -n id -u; /usr/local/bin/python3.13 --version'
```

Adjust the interpreter path to the version actually installed. For Ansible inventory, use the verified path rather than assuming an unversioned `python3` symlink exists.

## Known prototype gaps / implementation checklist

The earlier v0.2 script is a starting point, **not a tested release**. Before calling this directory production-ready, review and correct at least the following:

- Confirm OpenBSD 7.9 availability and exact behavior of every account-management, package, and `doas` command used.
- Make key validation reject extra lines and malformed options; compare actual key type/material and enforce correct file ownership and permissions in `check`, not only in `apply`.
- Ensure `authorized_keys` matching handles comments, options, duplicates, and non-key lines without false positives; never append an unusable or duplicate entry.
- Make the `doas` rule update idempotent even when an existing later rule denies access; preserve and validate administrator policy.
- Ensure temporary-file cleanup and traps work correctly with OpenBSD `/bin/sh`, including the successful `init` path.
- Distinguish deliberate account disablement and SSH policy conflicts from repairable missing configuration.
- Avoid boot-time hangs when `pkg_add` cannot reach a mirror; add time bounds and actionable logging.
- Verify real remote SSH login and Ansible module execution, not merely local file/service checks.

The repository-wide [README](../README.md) defines the cross-platform contract. This document defines the OpenBSD-specific implementation and test expectations; changes to the contract should be reflected in both files.
