#!/bin/sh
#
# controller-test.sh — controller-side validation of a bootstrapped host
#
# usage: controller-test.sh [-u user] [-i identity] [-p interpreter]
#                           [-m become-method] [-t seconds] [-a] host
#
# Runs from the Ansible controller against a host that ansible-bootstrap
# has already provisioned. Everything here is deliberately outside what
# the engine can check about itself: the engine can confirm a key is in
# authorized_keys, but only a real login proves sshd will accept it, and
# only a real module run proves the interpreter it reported can execute
# Ansible.
#
# Read-only by default. -a additionally runs `apply` on the target twice
# to confirm reconciliation is idempotent, which does modify the host.
#

set -eu

USER_NAME=ansible
IDENTITY=$HOME/.ssh/id_ed25519
BECOME_METHOD=community.general.doas
INTERPRETER=
TIMEOUT=10
RUN_APPLY=no

PASSED=0
FAILED=0

usage()
{
    cat <<EoF
Usage: ${0##*/} [options] host

  -u user         account to connect as (default: $USER_NAME)
  -i identity     SSH private key (default: $IDENTITY)
  -p interpreter  absolute path to force as ansible_python_interpreter;
                  omit to let Ansible discover it and report what it found
  -m method       become method (default: $BECOME_METHOD)
  -t seconds      SSH connect timeout (default: $TIMEOUT)
  -a              also run 'apply' on the target twice to check
                  idempotency; this MODIFIES the host
EoF
}

info()
{
    printf '%s\n' "$*" >&2
}

pass()
{
    PASSED=$((PASSED + 1))
    printf '  ok    %s\n' "$*" >&2
}

fail()
{
    FAILED=$((FAILED + 1))
    printf '  FAIL  %s\n' "$*" >&2
}

skip()
{
    printf '  skip  %s\n' "$*" >&2
}

die()
{
    printf '%s: ERROR: %s\n' "${0##*/}" "$*" >&2
    exit 2
}

# BatchMode so a missing host key or a refused key fails immediately
# rather than prompting; IdentitiesOnly so the agent cannot quietly
# offer a different key and make a broken authorized_keys look fine.
remote()
{
    ssh -i "$IDENTITY" \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        -o ConnectTimeout="$TIMEOUT" \
        "$USER_NAME@$HOST" "$@"
}

play()
{
    if [ -n "$INTERPRETER" ]; then
        ansible -i "$HOST," -u "$USER_NAME" --private-key "$IDENTITY" \
            -e "ansible_python_interpreter=$INTERPRETER" "$@" all
    else
        ansible -i "$HOST," -u "$USER_NAME" --private-key "$IDENTITY" \
            "$@" all
    fi
}

while getopts 'u:i:p:m:t:ah' opt; do
    case "$opt" in
        u) USER_NAME=$OPTARG ;;
        i) IDENTITY=$OPTARG ;;
        p) INTERPRETER=$OPTARG ;;
        m) BECOME_METHOD=$OPTARG ;;
        t) TIMEOUT=$OPTARG ;;
        a) RUN_APPLY=yes ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

[ $# -eq 1 ] || { usage >&2; exit 2; }
HOST=$1

[ -f "$IDENTITY" ] ||
    die "No such identity file: $IDENTITY"

command -v ansible >/dev/null ||
    die "ansible is not on PATH"

info "controller-test: $USER_NAME@$HOST"
info ""

info "preflight"

if ansible --version >/dev/null 2>&1; then
    pass "ansible runs ($(ansible --version 2>/dev/null | head -1))"
else
    # A pipx venv built against a since-removed interpreter fails
    # exactly here, and every test below would fail confusingly.
    fail "ansible is installed but will not run; check its interpreter"
fi

if ansible-doc -t become "$BECOME_METHOD" >/dev/null 2>&1; then
    pass "become plugin available: $BECOME_METHOD"
else
    fail "become plugin missing: $BECOME_METHOD (install community.general)"
fi

info ""
info "ssh"

if login_as=$(remote 'id -un' 2>/dev/null); then
    if [ "$login_as" = "$USER_NAME" ]; then
        pass "key-only login as $USER_NAME"
    else
        fail "logged in, but as '$login_as' rather than '$USER_NAME'"
    fi
else
    fail "cannot log in as $USER_NAME with $IDENTITY"
    info ""
    info "Nothing below can run without a working login. Check that the"
    info "host key is known, that sshd is running, and that the key in"
    info "authorized_keys matches this identity."
    info ""
    info "$PASSED passed, $((FAILED + 1)) failed"
    exit 1
fi

# Proves the target trusts *this* key, not merely some key. Catches a
# rotated or replaced controller key, which otherwise surfaces much
# later as a mysterious auth failure.
local_fp=$(ssh-keygen -lf "$IDENTITY.pub" -E sha256 2>/dev/null |
    awk '{ print $2 }') || local_fp=

if [ -z "$local_fp" ]; then
    skip "fingerprint comparison ($IDENTITY.pub not readable)"
elif remote 'ssh-keygen -lf ~/.ssh/authorized_keys -E sha256' 2>/dev/null |
        awk '{ print $2 }' | grep -qxF "$local_fp"; then
    pass "authorized_keys contains this key ($local_fp)"
else
    fail "authorized_keys does not contain $local_fp"
fi

if escalation=$(remote 'doas -n id -u' 2>/dev/null); then
    if [ "$escalation" = 0 ]; then
        pass "doas -n id -u returns 0"
    else
        fail "doas -n id -u returned '$escalation', expected 0"
    fi
else
    fail "doas -n failed; passwordless escalation is not effective"
fi

info ""
info "ansible"

if play -m ping 2>&1 | grep -q SUCCESS; then
    pass "ping module"
else
    fail "ping module"
fi

# Fact gathering exercises the interpreter far harder than ping, and
# reports which one Ansible actually used -- the value that belongs in
# inventory.
facts=$(play -m setup -a 'filter=ansible_distribution*,ansible_python*' 2>&1) ||
    facts=

if printf '%s\n' "$facts" | grep -q SUCCESS; then
    pass "fact gathering"

    for fact in ansible_distribution ansible_distribution_version \
                ansible_python_version; do
        value=$(printf '%s\n' "$facts" |
            awk -v k="\"$fact\":" '$1 == k { gsub(/[",]/, "", $2); print $2; exit }')
        [ -n "$value" ] && info "        $fact = $value"
    done

    used=$(printf '%s\n' "$facts" |
        awk '/"executable":/ { gsub(/[",]/, "", $2); print $2; exit }')
    [ -n "$used" ] && info "        interpreter   = $used"
else
    fail "fact gathering"
fi

if play -b --become-method="$BECOME_METHOD" -m command -a 'id -un' 2>&1 |
        grep -qx root; then
    pass "become via $BECOME_METHOD reaches root"
else
    fail "become via $BECOME_METHOD"
fi

if [ "$RUN_APPLY" = yes ]; then
    info ""
    info "idempotency (modifies the host)"

    engine=/usr/local/libexec/ansible-bootstrap

    # The shell module, not command: the engine writes everything to
    # stderr, and only a shell can redirect that into stdout where the
    # output is readable.
    if play -b --become-method="$BECOME_METHOD" \
            -m shell -a "$engine apply 2>&1" >/dev/null 2>&1; then
        pass "remote apply succeeded"
    else
        fail "remote apply failed"
    fi

    # The engine counts its own changes, so a second run against an
    # unchanged host must report that it made none. Anything else means
    # a repair is being re-applied on every invocation -- which at boot
    # would mean rewriting the same files forever.
    second=$(play -b --become-method="$BECOME_METHOD" \
        -m shell -a "$engine apply 2>&1" 2>&1) || second=

    if printf '%s\n' "$second" | grep -q 'no changes were needed'; then
        pass "second apply made no changes"
    elif printf '%s\n' "$second" | grep -q 'System is Ansible-ready'; then
        # Reached readiness but said nothing about changes, so the
        # target is running an engine from before change counting.
        fail "target engine predates change reporting; update it to test this"
    else
        fail "second apply reported changes; reconciliation is not idempotent"
    fi
else
    info ""
    skip "idempotency check (pass -a to run it; it modifies the host)"
fi

info ""
info "$PASSED passed, $FAILED failed"

[ "$FAILED" -eq 0 ]
