# FreeBSD adapter for the shared ansible-bootstrap engine.
#
# Sourced by the engine as root. Not executable on its own, and has no
# shebang for that reason. See lib/adapter-contract.md for the contract
# this file implements.
#
# Written against FreeBSD 15.1-RELEASE.

# FreeBSD has no ksh in the base system — /bin/sh, /bin/csh and
# /bin/tcsh only — so the OpenBSD adapter's /bin/ksh cannot carry over.
LOGIN_SHELL=/bin/sh

# doas is a package here rather than part of the base system, so both
# the binary and its configuration live under /usr/local. Neither
# exists until adapter_escalation_prepare has run.
DOAS_BIN=/usr/local/bin/doas
DOAS_CONF=/usr/local/etc/doas.conf
DOAS_PACKAGE=doas

adapter_create_account()
{
    # -w no leaves the password disabled; public-key authentication is
    # configured separately by the engine.
    pw useradd -n "$ACCOUNT" -d "$HOME_DIR" -s "$LOGIN_SHELL" -m -w no
}

# The structural difference from OpenBSD. There, doas is always present
# and escalation can always be configured. Here it is a package, so
# escalation depends on a working package manager and a reachable
# repository — and on a minimal installation pkg itself is only a stub
# until it has bootstrapped.
#
# Both operations are bounded: this runs at boot, and an unreachable
# repository must fail rather than stall.
adapter_escalation_prepare()
{
    [ -x "$DOAS_BIN" ] && return 0

    if ! pkg -N >/dev/null 2>&1; then
        changed "Bootstrapping pkg"

        if ! run_bounded "$PKG_TIMEOUT" \
                env ASSUME_ALWAYS_YES=yes pkg bootstrap; then
            log "pkg is not bootstrapped and bootstrapping failed. Until it"
            log "succeeds, doas cannot be installed and privilege escalation"
            log "cannot be configured. Check network reachability."
            die "Cannot bootstrap pkg"
        fi
    fi

    changed "Installing $DOAS_PACKAGE"

    if ! adapter_package_install "$DOAS_PACKAGE"; then
        log "Installing $DOAS_PACKAGE failed or timed out."
    fi

    # The install status is advisory; the binary appearing is the gate.
    [ -x "$DOAS_BIN" ] ||
        die "$DOAS_BIN is still missing after installing $DOAS_PACKAGE"
}

adapter_service_enabled()
{
    service "$1" enabled >/dev/null 2>&1
}

adapter_service_running()
{
    service "$1" status >/dev/null 2>&1
}

# sysrc reports the assignment it made on stdout; the engine has
# already recorded the change, so discard it.
adapter_service_enable()
{
    sysrc "$1_enable=YES" >/dev/null
}

adapter_service_start()
{
    service "$1" start >/dev/null
}

# Emit "<package-name> <major> <minor>" for each installable Python
# interpreter the repository offers.
#
# FreeBSD encodes the version in the package *name* — python313, where
# OpenBSD has python-3.13.13 — but %v carries a properly dotted
# version, so the version is read from there rather than picked out of
# the name.
#
# Three kinds of entry are excluded, for three different reasons:
#
#   python3       a meta package whose version is "3_4", which is not
#                 an interpreter version at all
#   python313t    free-threaded builds; a different runtime, and not
#                 what ansible-core is tested against
#   python315     pre-releases such as 3.15.0.b2 parse to 3.15 and are
#                 then excluded by PYTHON_MAX, so no special case is
#                 needed here — but only while a maximum is configured
#
# Requiring at least one digit after "python3" drops the meta package
# and requiring the name to end there drops the "t" variants.
adapter_python_packages()
{
    # rquery reads the local copy of the remote catalog and does not
    # fetch it. A host that has never run pkg update, or whose catalog
    # has expired, would otherwise look like a repository offering no
    # interpreters. This only runs when an install is actually needed,
    # so it is not per-boot churn.
    run_bounded "$PKG_TIMEOUT" pkg update >/dev/null 2>&1 || :

    # Captured before filtering rather than piped: a pipeline's status
    # is the last command's, which would discard a timeout and report
    # it to the engine as an empty repository.
    pkg_list=$(run_bounded "$PKG_TIMEOUT" \
        pkg rquery -g '%n %v' 'python3*') || return 1

    printf '%s\n' "$pkg_list" |
        awk '
            $1 ~ /^python3[0-9]+$/ {
                n = split($2, part, ".")
                print $1, part[1] + 0, (n >= 2) ? part[2] + 0 : 0
            }
        '
}

adapter_package_install()
{
    run_bounded "$PKG_TIMEOUT" pkg install -y "$1"
}
