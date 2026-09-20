#!/bin/sh
#
# OpenBSD Ansible bootstrap installer
#
# usage: install.sh [--enable-boot-hook]
#
# Installs the reconciliation engine, initializes the controller
# public key, and verifies readiness. The boot hook is NOT installed
# unless --enable-boot-hook is given: enable it only after the manual
# validation steps in README.md have succeeded.
#

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH

ENGINE=/usr/local/libexec/ansible-bootstrap
BOOT_FILE=/etc/rc.local
LOG_FILE=/var/log/ansible-bootstrap.log
MARKER='# BEGIN ansible-bootstrap'

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

usage()
{
    cat <<EoF
Usage: $0 [--enable-boot-hook]

  --enable-boot-hook  Append the reconciliation invocation to
                      $BOOT_FILE so it runs on every boot. Do this
                      only after the manual validation steps in
                      README.md succeed.
EoF
}

# The invocation appended to rc.local, also shown when the hook is
# not installed so it can be added by hand later.
boot_hook()
{
    cat <<EoF

$MARKER
# Maintain Ansible readiness; this is a short-lived boot task.
if [ -x $ENGINE ]; then
    $ENGINE apply >> $LOG_FILE 2>&1
fi
# END ansible-bootstrap
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

[ "$(uname -s)" = OpenBSD ] ||
    die_config "This installer requires OpenBSD"

[ -f ./ansible-bootstrap ] ||
    die_config "Run this installer from the OpenBSD directory of the repo/archive"

[ -n "${ANSIBLE_PUBLIC_KEY:-}" ] ||
    die_config "ANSIBLE_PUBLIC_KEY is required"

# Install the engine.
install -d -m 0755 /usr/local/libexec

install -o root -g wheel -m 0700 \
    ./ansible-bootstrap "$ENGINE"

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
key, that 'doas -n id -u' returns 0, and that an Ansible ping succeeds
using the absolute path of the installed Python interpreter.

Then enable reconciliation on every boot with:

    $0 --enable-boot-hook

or append the following to $BOOT_FILE by hand:
EoF
    boot_hook
    exit 0
fi

[ ! -L "$BOOT_FILE" ] ||
    die "$BOOT_FILE is a symbolic link; refusing to modify it"

# Install the boot hook exactly once, preserving existing contents.
if [ -f "$BOOT_FILE" ] && grep -Fq "$MARKER" "$BOOT_FILE"; then
    echo "install: boot hook already present in $BOOT_FILE"
else
    boot_hook >> "$BOOT_FILE"
    echo "install: boot hook added to $BOOT_FILE"
fi

echo "Ansible bootstrap installation complete."
