#!/bin/sh
#
# FreeBSD Ansible bootstrap installer.
#
# The work is in ../lib/install.sh, which is shared between platforms.
# This wrapper exists so that the documented invocation — cd into the
# platform directory and run ./install.sh — keeps working, and so that
# running the wrong platform's installer fails loudly instead of
# quietly doing the right thing for whatever OS it finds itself on.
#

set -eu

[ "$(uname -s)" = FreeBSD ] || {
    echo "install: ERROR: this is the FreeBSD installer; this host is $(uname -s)" >&2
    exit 2
}

# Pass the name the user actually typed, so the shared installer can
# tell them how to re-run it rather than naming lib/install.sh.
INSTALLER_NAME=$0
export INSTALLER_NAME

exec "$(cd -- "$(dirname -- "$0")/../lib" && pwd)/install.sh" "$@"
