#!/bin/sh
#
# OpenBSD Ansible bootstrap installer
#

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH

ENGINE=/usr/local/libexec/ansible-bootstrap
BOOT_FILE=/etc/rc.local

die()
{
    echo "install: ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] ||
    die "Must run as root"

[ "$(uname -s)" = OpenBSD ] ||
    die "This installer requires OpenBSD"

[ -f ./ansible-bootstrap ] ||
    die "Run this installer from the OpenBSD directory of the repo/archive"

[ -n "${ANSIBLE_PUBLIC_KEY:-}" ] ||
    die "ANSIBLE_PUBLIC_KEY is required"

# Install the engine.
install -d -m 0755 /usr/local/libexec

install -o root -g wheel -m 0700 \
    ./ansible-bootstrap "$ENGINE"

# Initialize the key and provision the host.
"$ENGINE" init

# Verify before enabling the boot hook.
"$ENGINE" check ||
    die "Bootstrap readiness verification failed"

# Install the boot hook exactly once.
if [ ! -f "$BOOT_FILE" ] ||
   ! grep -Fq '# BEGIN ansible-bootstrap' "$BOOT_FILE"
then
    cat >> "$BOOT_FILE" <<'EoF'

# BEGIN ansible-bootstrap
if [ -x /usr/local/libexec/ansible-bootstrap ]; then
    /usr/local/libexec/ansible-bootstrap apply \
        >> /var/log/ansible-bootstrap.log 2>&1
fi
# END ansible-bootstrap
EoF
fi

echo "Ansible bootstrap installation complete."
