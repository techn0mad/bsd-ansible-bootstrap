#!/bin/sh
#
# Shared Ansible bootstrap installer
#
# Invoked through the per-OS wrapper — OpenBSD/install.sh,
# FreeBSD/install.sh — which asserts the platform. Everything here is
# platform-independent except the boot hook, which comes from
# $OS/boot-hook.sh: that supplies BOOT_HOOK_TARGET, boot_hook_show and
# boot_hook_install, because OpenBSD manages a block in rc.local while
# FreeBSD installs an rc.d script.
#
# usage: install.sh [--enable-boot-hook]
#
# Installs the reconciliation engine, initializes the controller
# public key, and verifies readiness. The boot hook is NOT installed
# unless --enable-boot-hook is given: enable it only after the manual
# validation steps in README.md have succeeded.
#
# ANSIBLE_PUBLIC_KEY and ANSIBLE_EXPECTED_FINGERPRINT are read from the
# environment if set, and prompted for otherwise when run on a
# terminal. Never supply an SSH private key by either route.
#

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH

ENGINE=/usr/local/libexec/ansible-bootstrap
ADAPTER=/usr/local/libexec/ansible-bootstrap-adapter

LOG_FILE=/var/log/ansible-bootstrap.log

# Sources are located from this script rather than the caller's working
# directory, and the platform directory from uname, so there is one
# source of truth for which adapter belongs to which OS.
LIB_DIR=$(cd -- "$(dirname -- "$0")" && pwd) ||
    { echo "install: ERROR: cannot locate installer directory" >&2; exit 2; }
REPO_DIR=$(dirname -- "$LIB_DIR")
OS_DIR=$REPO_DIR/$(uname -s)

ENGINE_SRC=$LIB_DIR/ansible-bootstrap
ADAPTER_SRC=$OS_DIR/adapter.sh
BOOT_HOOK_SRC=$OS_DIR/boot-hook.sh

# The name the wrapper was invoked as, for messages that tell the
# user how to re-run it; falls back to $0 when run directly.
SELF=${INSTALLER_NAME:-$0}

enable_boot_hook=no

# Same exit-status contract as the engine: 1 means the host is not
# ready, 2 means the invocation or the supplied configuration is wrong.
EX_NOTREADY=1
EX_CONFIG=2

die()
{
    echo "install: ERROR: $*" >&2
    exit "$EX_NOTREADY"
}

die_config()
{
    echo "install: ERROR: $*" >&2
    exit "$EX_CONFIG"
}

# The boot-hook half of the platform split. Sourced after die() so it
# can report failures, and before usage() which names its target.
[ -f "$BOOT_HOOK_SRC" ] ||
    die_config "No boot-hook definition for $(uname -s): $BOOT_HOOK_SRC"

. "$BOOT_HOOK_SRC"

usage()
{
    cat <<EoF
Usage: ${SELF##*/} [--enable-boot-hook]

  --enable-boot-hook  Install the reconciliation invocation into
                      $BOOT_HOOK_TARGET so it runs on every boot. Do
                      this only after the manual validation steps in
                      README.md succeed.

ANSIBLE_PUBLIC_KEY and ANSIBLE_EXPECTED_FINGERPRINT are taken from the
environment when set, and prompted for otherwise if run on a terminal.
EoF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --enable-boot-hook)
            enable_boot_hook=yes
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "install: unknown option: $1" >&2
            usage >&2
            exit "$EX_CONFIG"
            ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] ||
    die_config "Must run as root"

[ -f "$ENGINE_SRC" ] ||
    die_config "Missing engine: $ENGINE_SRC"

[ -f "$ADAPTER_SRC" ] ||
    die_config "No adapter for $(uname -s): $ADAPTER_SRC"

# Ask for anything not already in the environment, so the interactive
# case needs no setup. An unattended run has no terminal, and there a
# missing value is an error rather than a question nobody can answer.
#
# Prompting is also the better channel: a key passed in the environment
# reaches the shell's history and is visible in process listings and
# diagnostics, which the README warns against. Nothing typed here
# reaches either.
if [ -z "${ANSIBLE_PUBLIC_KEY:-}" ]; then
    [ -t 0 ] ||
        die_config "ANSIBLE_PUBLIC_KEY is required; no terminal to prompt on"

    cat <<'EoF'

Paste the Ansible controller's PUBLIC key -- the contents of its .pub
file. Never paste a private key: this host must never hold one.

EoF
    printf 'Controller public key: '
    IFS= read -r ANSIBLE_PUBLIC_KEY ||
        die_config "No input read; this host has not been changed"

    case "$ANSIBLE_PUBLIC_KEY" in
        '')
            die_config "No public key supplied"
            ;;
        *PRIVATE*KEY*)
            die_config "That is a PRIVATE key; supply the public key instead"
            ;;
    esac
fi

# Tested with +set rather than :- so that an explicitly empty value
# from an unattended caller is respected as "deliberately none".
if [ -z "${ANSIBLE_EXPECTED_FINGERPRINT+set}" ] && [ -t 0 ]; then
    cat <<'EoF'

Optionally supply that key's SHA256 fingerprint, obtained from the
controller through a channel independent of the key itself -- one that
travelled with the key proves nothing. Press Enter to skip.

EoF
    printf 'Expected fingerprint: '
    IFS= read -r ANSIBLE_EXPECTED_FINGERPRINT ||
        ANSIBLE_EXPECTED_FINGERPRINT=
    echo
fi

: "${ANSIBLE_EXPECTED_FINGERPRINT:=}"

export ANSIBLE_PUBLIC_KEY ANSIBLE_EXPECTED_FINGERPRINT

# Install the engine and its adapter. The adapter is sourced by the
# engine as root, so it is code with full privilege and gets exactly
# the same ownership and mode; the engine refuses to load one that does
# not.
install -d -m 0755 /usr/local/libexec

install -o root -g wheel -m 0700 "$ENGINE_SRC" "$ENGINE"
install -o root -g wheel -m 0700 "$ADAPTER_SRC" "$ADAPTER"

# Initialize the key and provision the host.
"$ENGINE" init

# Gate everything below on an independent readiness assessment.
"$ENGINE" check ||
    die "Bootstrap readiness verification failed"

if [ "$enable_boot_hook" = no ]; then
    cat <<EoF

install: engine installed at $ENGINE; host reports ready.
install: the boot hook was NOT installed.

Validate this host before enabling unattended reconciliation; see the
"Manual validation" section of README.md. At minimum, confirm from the
Ansible controller that SSH login as 'ansible' works with the intended
key, that privilege escalation is effective for that account, and that
an Ansible ping succeeds using the absolute path of the installed Python
interpreter. The 'check' output above names both the become method and
the interpreter path to use; lib/controller-test.sh runs all of it.

Then enable reconciliation on every boot with:

    $SELF --enable-boot-hook

or install the following into $BOOT_HOOK_TARGET by hand:
EoF
    boot_hook_show
    exit 0
fi

boot_hook_install

echo "Ansible bootstrap installation complete."
