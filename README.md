# Ansible Bootstrap Service

A small, idempotent set of scripts for making a newly installed BSD
host **ready to be provisioned by Ansible**. The service runs at boot,
reconciles only the prerequisites for Ansible access and execution,
and exits. It is not a resident daemon or a replacement for Ansible.

> **Project status:** Design and early OpenBSD prototype. The current
> script is not production-hardened; verify platform-specific commands
> and test in a disposable VM before enabling it at boot. FreeBSD
> support is planned.

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
| Privilege escalation | The `ansible` account can execute commands as root noninteractively, using the OS-native supported mechanism (`doas` or `sudo`). |

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

Suggested exit-status contract: `0` = ready/success, `1` =
prerequisites missing or reconciliation failed, `2` = invalid
invocation or configuration. Refine error categories as the
implementation matures.

## Implementation strategy

### Common engine, small OS adapters

Keep the state checks, public-key validation, reconciliation flow,
reporting, and tests in a shared POSIX-shell engine. Isolate
differences in account management, package installation, privilege
escalation, service management, and interpreter discovery behind small
OS-specific functions. Avoid a large abstraction framework for two
operating systems.

A possible repository layout:

```text
bsd-ansible-bootstrap/
├── README.md
├── OpenBSD/
│   ├── README.md
│   ├── install.sh
│   └── ansible-bootstrap
└── FreeBSD/
    ├── README.md
    ├── install.sh
    ├── ansible-bootstrap
    └── rc.d/
        └── ansible_bootstrap
```

The initial OpenBSD prototype may remain a single script while its
behavior is validated; refactor only after the FreeBSD requirements
are concrete.

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
