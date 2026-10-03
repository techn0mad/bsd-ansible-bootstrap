# Ansible Bootstrap Service

A small, idempotent set of scripts for making a newly installed BSD
host **ready to be provisioned by Ansible**. The service runs at boot,
reconciles only the prerequisites for Ansible access and execution,
and exits. It is not a resident daemon or a replacement for Ansible.

> **Project status:** All three platforms are validated on hardware —
> OpenBSD 7.9, FreeBSD 15.1 and NetBSD 11.0 — each installed from a
> pristine host to all five invariants, passing the controller-side
> suite 10/10, and running the boot hook unattended. On every platform a
> boot with **two** faults injected at once, privilege escalation broken
> and `sshd` disabled, repaired both in three changes, and a second boot
> with no drift made none.
>
> Each platform is still validated on a **single release** — 7.9, 15.1,
> 11.0 — so treat it as a tested prototype rather than a release.
> Two cases remain unexercised, both the same one: a boot with the
> package repository **unreachable** on OpenBSD and on FreeBSD. NetBSD
> has run it ([NetBSD/README.md](NetBSD/README.md)), where it found a
> real defect, so it is worth running on the other two. Each platform's
> README lists what remains unconfirmed there.

## Goals

- Establish and preserve the minimum capabilities needed for an
  Ansible controller to connect and provision the host.
- Work immediately after a minimal OS installation, without requiring
  Git, SFTP, cloud-init, Python, or Ansible on the target beforehand.
- Be **idempotent**: inspect actual state, repair only missing or
  incorrect prerequisites, and do nothing when the host is ready.
- Recover from interrupted bootstrap attempts and ordinary
  configuration drift on later boots.
- Keep the controller's SSH **private key on the controller**;
  distribute only public SSH keys to targets.
- Use native OS facilities and a small POSIX-shell implementation,
  with platform-specific adapters where necessary.
- Provide clear diagnostics, meaningful exit statuses, and an
  auditable record of the controller key fingerprint.

## Scope: the readiness contract

The service maintains these five invariants:

| Prerequisite | Desired state |
| --- | --- |
| SSH server | Valid configuration; enabled for boot; running. |
| Service account | Dedicated `ansible` account exists, has the expected home and usable login shell, and is permitted to authenticate by public key. |
| SSH authentication | The configured controller public key is present in the account's `authorized_keys`, with safe ownership and permissions. |
| Python | A Python 3 interpreter compatible with the selected `ansible-core` version is available; its path can be reported to the controller. |
| Privilege escalation | The `ansible` account can execute commands as root noninteractively, through the platform's default mechanism — `doas` on OpenBSD, `sudo` on FreeBSD and NetBSD. |

The service **does not** manage general host configuration,
application packages, firewall rules, other users, or the broader SSH
security policy. Those belong to Ansible. It should detect and report
conflicts with deliberate administrative changes rather than silently
overriding them.

## Operating model

1. **Initialize trust once.** Supply one or more controller *public*
   keys through a trusted installation channel (console, installer
   customization, provider provisioning API, or a separately
   authenticated download). The bootstrap initializer validates and
   stores the keys in root-controlled local configuration.
2. **Verify identity.** Display and log each key's SHA-256 SSH
   fingerprint. Optionally require an expected fingerprint supplied
   through an **independent trusted channel**; reject a mismatch. A
   digest delivered alongside a substituted key does not, by itself,
   authenticate that key.
3. **Reconcile.** At boot, and when invoked manually, check the five
   invariants and repair only those that need repair. Verify the
   resulting state before reporting success.
4. **Hand off.** Exit. Ansible manages everything outside the
   readiness contract.

A completion marker may be retained for diagnostics, but **must not
substitute for checking actual system state**: a host can lose Python
or its authorized key after an earlier successful bootstrap.

### Proposed command interface

```text
ansible-bootstrap init    # accept and persist trusted public-key configuration, then apply
ansible-bootstrap check   # read-only readiness assessment
ansible-bootstrap apply   # reconcile prerequisites, then verify
```

`init` may accept a public key through an environment variable for
convenient console or installer use. That variable is transient: the
validated key is persisted locally for subsequent boots. **Never pass
an SSH private key to the host or to this service.** Avoid logging the
full key unless needed for debugging; log its fingerprint instead. An
unattended initializer should support an independently supplied
expected fingerprint.

Exit-status contract: `0` = ready/success, `1` = prerequisites missing
or reconciliation failed, `2` = invalid invocation or configuration.
The dividing line between `1` and `2` is whether repeating the run
could help: `2` means the service's own inputs are wrong and a retry
fails identically until a human intervenes, while `1` means the
managed host state is wrong and a later boot may resolve it.

## Implementation strategy

### Common engine, small OS adapters

Keep the state checks, public-key validation, reconciliation flow,
reporting, and tests in a shared POSIX-shell engine. Isolate
differences in account management, package installation, privilege
escalation, service management, and interpreter discovery behind small
OS-specific functions. Avoid a large abstraction framework for two
operating systems.

The repository layout:

```text
bsd-ansible-bootstrap/
├── README.md
├── lib/
│   ├── ansible-bootstrap        # shared engine
│   ├── install.sh               # shared installer
│   ├── controller-test.sh       # shared controller-side tests
│   └── adapter-contract.md
├── OpenBSD/
│   ├── README.md
│   ├── adapter.sh               # engine adapter, deployed
│   ├── boot-hook.sh             # installer adapter, not deployed
│   └── install.sh               # wrapper
├── FreeBSD/
│   ├── README.md
│   ├── adapter.sh
│   ├── boot-hook.sh
│   ├── install.sh
│   └── rc.d/
│       └── ansible_bootstrap
└── NetBSD/
    ├── README.md
    ├── adapter.sh
    ├── boot-hook.sh
    ├── install.sh
    └── rc.d/
        └── ansible_bootstrap
```

Run the installer from the platform directory — `cd OpenBSD &&
./install.sh` — which is a nineteen-line wrapper that asserts the
platform and hands off to the shared installer.

The engine is platform-independent and each OS supplies an adapter of
roughly eighty lines covering account creation, package installation,
privilege escalation, and service management.
[`lib/adapter-contract.md`](lib/adapter-contract.md) defines what an
adapter must provide, and where the line between mechanism and policy
falls: *how* to list available packages is a platform mechanism, while
*which* Python versions are acceptable is Ansible policy and stays in
the engine.

The engine sources its adapter as root, so an adapter is code with full
privilege rather than configuration. It is verified to be a
root-owned, mode-0700 regular file before being read — the same rule
this document states about not sourcing untrusted configuration as
shell code.

The OpenBSD prototype was a single script until its behaviour had been
validated on hardware and the FreeBSD requirements were written down.
Both conditions being met is what made the split above safe to attempt:
the engine could be verified against a real host after the refactor
rather than merely re-read.

### Boot integration

Use a native, short-lived boot hook to invoke `ansible-bootstrap
apply` **on every boot**. It is a boot-time task, not a continuously
running daemon. The wrapper should run after the network is
initialized, preserve other local startup configuration, log failures,
and never prevent console access. Package repository failures must be
bounded and diagnosable rather than hanging boot indefinitely.

The exact hook is platform-specific (for example, OpenBSD `rc.local`
or a FreeBSD `rc.d` service). First-boot facilities can *install* the
service, but are not the ongoing readiness mechanism.

### Public-key lifecycle

- The Ansible controller generates and retains its own private key.
- The target accepts only public keys and stores them in a root-owned
  bootstrap configuration file.
- Validate public-key syntax and permitted algorithms; log the
  `SHA256:...` fingerprint during initialization and whenever a key is
  installed or repaired.
- Compare key type and encoded key material, not comments, when
  checking `authorized_keys`.
- Preserve unrelated authorized keys. Define explicit procedures for
  rotation, revocation, and multiple controllers; never silently
  replace a configured controller key.
- Check permissions and ownership of the account home, `.ssh`, and
  `authorized_keys`; reject unsafe symlink paths.

A fingerprint is an identifier, **not a signature**. Comparing a
fingerprint with a value independently obtained from the controller is
the useful authenticity check.

### Which escalation tool, and why it differs per platform

Each platform gets the tool its own documentation treats as standard:

| Platform | Default | Why |
| --- | --- | --- |
| OpenBSD | `doas` | In the base system, and the documented mechanism. |
| FreeBSD | `sudo` | Neither tool is in base. The Handbook: "The most used application is currently Sudo", describing `doas` as "an alternative to the widely used sudo(8) command." |
| NetBSD | `sudo` | Neither tool is in base — `man.netbsd.org` has no `doas.1`, base offers only `su(1)` — and both come from pkgsrc. |

On the two platforms where there is no native tool to defer to, `sudo`
wins on a second count: it is `ansible-core`'s own default become
method, while `doas` needs the `community.general` collection for its
become plugin. Defaulting to `doas` there would impose a controller-side
dependency to use a non-native tool.

`check` reports which method the controller should use, next to the
interpreter path, because neither is something the controller can
derive:

```text
ansible-bootstrap: escalation: OK (ansible_become_method=sudo)
ansible-bootstrap: python: OK (ansible_python_interpreter=/usr/local/bin/python3.13)
```

[`lib/controller-test.sh`](lib/controller-test.sh) detects the target's
OS over SSH and selects the matching become method, so one invocation
works against any supported host; `-m` overrides it.

#### What this costs, and the shape of the code

Supporting both means two policy writers rather than one, and the
`sudoers` one is writing a file that grants root — so the two were kept
as different shapes rather than one shape with substituted strings:

- **`doas`** edits a marked block inside `/etc/doas.conf`, a file
  belonging to the administrator. It preserves unrelated rules, refuses
  to append a second copy of its own, and refuses to outrank an existing
  rule naming the account.
- **`sudo`** writes `sudoers.d/ansible-bootstrap`, a file this service
  owns outright. There is no block to find and nothing to preserve — but
  also no marker saying "this is mine", so the drift check compares
  content, ownership and mode instead. A truncated or `chmod`ped drop-in
  is repaired; one that is already correct while `sudo -n` still fails
  is reported as a conflict rather than rewritten on every boot.

Both validate the candidate file with the tool's own parser before
installing it — `doas -C`, `visudo -c -f` — and both verify the
*effective* policy afterwards by running `-n /usr/bin/id -u` as the
account.

That effective test is also all `check` asks. It does not test whether
*this service* wrote the policy: the invariant is that the account can
reach root noninteractively, not that this program is the reason. An
administrator who granted it in `sudoers` directly has satisfied it, and
`apply` then writes nothing rather than adding a second grant.

Both live in the engine, dispatched on one adapter constant,
`ESCALATION_STYLE`. Adapters supply only paths. That keeps the
root-granting code reviewable in one place instead of copied three
times, and it is the same constant a future option would set — see
below.

#### A future option

The per-platform default is a default, not a judgement about any
host. An administrator may have standardized on one tool everywhere, and
on OpenBSD in particular `sudo` is a perfectly ordinary package to
install deliberately.

There is currently no way to ask for the other tool: changing it means
editing one line in the platform's `adapter.sh`. A future release may
expose the choice — as an installer flag and a value persisted under
`/etc/ansible-bootstrap`, so that reconciliation at boot keeps honouring
it. The seam is already in the right place; what is missing is the
plumbing to carry a stored preference into the engine, and the decision
about what should happen to the policy the *other* mechanism was granted
by an earlier run.

#### Changing the mechanism on a host already bootstrapped

Switching a host from one mechanism to the other **does not revoke the
first one**. The engine manages the mechanism in effect and does not go
looking for policy it wrote under another; a host bootstrapped with
`doas` and later reconciled with `sudo` keeps its passwordless `doas`
rule, so removing the `sudoers` drop-in would not actually revoke the
account's root access.

Remove the previous grant by hand. For a host that was bootstrapped with
`doas`, the managed block is delimited and nothing else in the file is
this service's:

```sh
# Inspect first; this is a file that grants root.
doas sed -n '/# BEGIN ansible-bootstrap/,/# END ansible-bootstrap/p' \
    /usr/local/etc/doas.conf
```

Then delete those lines, keeping the rest, and confirm with
`su ansible -c 'doas -n /usr/bin/id -u'` that it now fails. Uninstalling
the package the grant belonged to is the cleaner end state where nothing
else uses it.

### Privilege and configuration boundaries

General Ansible provisioning requires broad root access, so configure
passwordless privilege escalation for the dedicated Ansible account
rather than an impractical command allowlist. Verify the *effective*
policy by running a harmless noninteractive command **as the Ansible
account**, not merely by parsing a configuration file. Restrict SSH
key possession and controller access appropriately.

Configuration should be root-owned and declarative. Do not `source` an
untrusted configuration file as shell code. The service should not
overwrite unrelated administrator configuration; if a safe repair
cannot be made, fail with an actionable diagnostic.

### Python compatibility

Discover an existing compatible Python 3 interpreter before installing
anything. Compatibility must be defined against the chosen
`ansible-core` release, not merely “Python 3 exists.” When
installation is necessary, use the platform package manager, verify
the installed interpreter, and report its absolute path for inventory
configuration. Avoid unbounded upgrades or package churn on every
boot.

That constraint runs in both directions. A target OS packages only the
interpreters it packages, and if the newest of those is outside the
controller's `ansible-core` range, no configuration on the target can
reconcile them — the controller has to move. Check what the target
release actually offers before assuming a given `ansible-core` will do.

## Controller-side tests

`lib/controller-test.sh` runs the checks the engine cannot perform on
itself. It is executed **from the Ansible controller**, against a host
that has already been provisioned, and is shared between platforms —
nothing in it is OS-specific, and the become method and interpreter path
are options rather than constants.

```sh
lib/controller-test.sh 192.168.1.87
```

The sample below is from the FreeBSD guest, run with `-a`; the shape is
the same for any target. Only the `escalation` section differs between
platforms, and it is detected rather than configured.

```text
preflight
  ok    ansible runs (ansible [core 2.21.4])

ssh
  ok    key-only login as ansible
  ok    authorized_keys contains this key (SHA256:aWo3...)

escalation
        target FreeBSD; become method sudo (detected)
  ok    become plugin available: sudo
  ok    sudo -n id -u returns 0

ansible
  ok    ping module
  ok    fact gathering
        ansible_distribution = FreeBSD
        ansible_distribution_version = 15.1
        ansible_python_version = 3.14.7
        interpreter   = /usr/local/bin/python3.14
  ok    become via sudo reaches root

idempotency (modifies the host)
  ok    remote apply succeeded
  ok    second apply made no changes

10 passed, 0 failed
```

Against the OpenBSD guest the same invocation reports `target OpenBSD;
become method community.general.doas (detected)` and tests `doas`
instead. Without `-a` the last section is skipped and the count is 8.

Options: `-u` account, `-i` identity, `-p` to force an interpreter
path rather than letting Ansible discover one, `-m` become method —
overriding detection — `-t` connect timeout, and `-a` to additionally
run `apply` twice on the target, which modifies it. It exits non-zero if
any check fails.

Why these checks and not others — each one asserts something the
engine's own `check` cannot:

- The engine can confirm a key is in `authorized_keys`; only a real
  login proves `sshd` will accept it. `IdentitiesOnly=yes` is set so a
  loaded agent cannot quietly offer a different key and make a broken
  `authorized_keys` look fine, and `BatchMode=yes` so an unknown host
  key fails instead of prompting.
- Comparing the fingerprint in `authorized_keys` against the
  controller's own key proves the target trusts *this* key and not
  merely some key — which catches a rotated or replaced controller key
  that would otherwise surface much later as a mystifying auth failure.
- The engine tests escalation through `su`; Ansible reaches it over SSH
  through a become plugin. Those are different paths and both can fail
  independently. The method is derived from the target's `uname -s`, so
  one invocation works against any supported host and a host running the
  wrong platform's adapter shows up as a mismatch rather than passing
  quietly.
- Fact gathering exercises the interpreter far harder than `ping`, and
  reports the path Ansible actually chose — the value that belongs in
  inventory.

`-a` additionally runs `apply` on the target twice and asserts the
second run reports no changes, which is the idempotency property the
whole design rests on. It is not the default because, unlike everything
else here, it modifies the host. It requires an engine recent enough to
report change counts.

## Validation plan

Test on disposable VMs for each supported OS:

1. Fresh minimal installation: all five invariants become true.
2. Second `apply`: no duplicate keys, repeated privilege rules, or
   unnecessary package changes.
3. `check`: detects missing prerequisites without modifying the host.
4. Remove a managed key, stop/disable SSH, or remove Python: `apply`
   repairs the affected prerequisite only.
5. Simulate interrupted execution and unavailable package
   repositories: subsequent runs recover; boot remains usable.
6. Supply a malformed key or mismatched expected fingerprint:
   initialization fails without installing the key.
7. Verify SSH login from the controller and noninteractive root
   escalation; verify the reported Python path with Ansible.
8. Reboot and confirm the boot hook exits successfully and logs
   meaningful status.

## Non-goals and future work

Not included initially: controller private-key distribution, remote
execution of arbitrary downloaded scripts, a resident agent, full host
hardening, general configuration management, automatic key rotation,
or a cross-platform package abstraction beyond what readiness
requires. Potential later additions include multiple controller keys,
explicit key revocation, machine-readable status, a bounded network
retry policy, and installer/provider integrations.
