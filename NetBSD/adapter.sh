# NetBSD adapter for the shared ansible-bootstrap engine.
#
# Sourced by the engine as root. Not executable on its own, and has no
# shebang for that reason. See lib/adapter-contract.md for the contract
# this file implements.
#
# Written against NetBSD 11.0 (aarch64).

# ksh is in the NetBSD base system, as on OpenBSD and unlike FreeBSD.
LOGIN_SHELL=/bin/ksh

# doas is not in the base system here; it comes from pkgsrc, which
# installs under /usr/pkg rather than /usr/local.
DOAS_BIN=/usr/pkg/bin/doas
DOAS_CONF=/usr/pkg/etc/doas.conf
DOAS_PACKAGE=doas

# pkgsrc installs interpreters here. This is the one constant the
# contract anticipates an adapter reassigning.
PYTHON_DIR=/usr/pkg/bin

# Binary package repository for pkg_add and pkg_info.
#
# A stock NetBSD installation has no PKG_PATH and no package tooling
# configured, so without this nothing can be installed -- which on this
# platform also means privilege escalation cannot be configured, since
# doas is a package. Deriving it is what makes the contract reachable on
# an unmodified host.
#
# Exported for this adapter's own calls only, never written to the host:
# choosing a mirror is general host configuration and belongs to
# Ansible. An administrator's own PKG_PATH wins.
#
# The architecture comes from hw.machine_arch, which reports aarch64.
# uname -m reports the port name, evbarm, for which no repository
# exists. The release path redirects -- 11.0 to 11.0_2026Q2 -- and both
# ftp and pkg_add follow it.
PKG_PATH=${PKG_PATH:-https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/$(sysctl -n hw.machine_arch)/$(uname -r)/All/}
export PKG_PATH

# Enabling a service means an assignment in /etc/rc.conf: NetBSD has
# neither OpenBSD's rcctl nor FreeBSD's sysrc. That file belongs to the
# administrator and is sourced as shell, so the last assignment wins and
# ours goes in a marked block at the end -- the same discipline the
# engine applies to doas.conf, for the same reason.
RC_CONF=/etc/rc.conf
RC_BEGIN='# BEGIN ansible-bootstrap'
RC_END='# END ansible-bootstrap'

adapter_create_account()
{
    # -p '*' leaves no usable password; SSH public-key authentication is
    # configured separately by the engine. NetBSD's useradd shares its
    # lineage with OpenBSD's and takes the same flags.
    useradd -m -d "$HOME_DIR" -s "$LOGIN_SHELL" -p '*' "$ACCOUNT"
}

# doas comes from pkgsrc here, so escalation depends on a working
# package manager and a reachable repository -- the same inversion as
# FreeBSD, one step deeper because the repository also has to be
# derived before anything can be fetched.
adapter_escalation_prepare()
{
    [ -x "$DOAS_BIN" ] && return 0

    changed "Installing $DOAS_PACKAGE"

    if ! adapter_package_install "$DOAS_PACKAGE"; then
        log "Installing $DOAS_PACKAGE failed or timed out."
    fi

    # The install status is advisory; the binary appearing is the gate.
    [ -x "$DOAS_BIN" ] ||
        die "$DOAS_BIN is still missing after installing $DOAS_PACKAGE"
}

# `service -e NAME` prints the script path and exits 0 when the service
# is enabled for boot, and prints nothing and exits 1 when it is not.
#
# Do NOT substitute `rcvar`: it exits 0 either way and differs only in
# what it prints, so using its status would report every service as
# enabled -- including one that will not survive a reboot.
adapter_service_enabled()
{
    service -e "$1" >/dev/null 2>&1
}

# onestatus rather than status: status consults rcvar first and refuses
# for a disabled service, which would conflate "not running" with "not
# enabled". The engine asks those as separate questions and needs them
# answered separately.
adapter_service_running()
{
    service "$1" onestatus >/dev/null 2>&1
}

# True when the managed block already carries this assignment.
rc_conf_block_has()
{
    [ -f "$RC_CONF" ] || return 1

    awk -v begin="$RC_BEGIN" -v end="$RC_END" -v want="$1=YES" '
        $0 == begin { inblock = 1; next }
        $0 == end   { inblock = 0; next }
        inblock && $0 == want { found = 1 }
        END { exit !found }
    ' "$RC_CONF"
}

adapter_service_enable()
{
    # Already written and still not in effect: appending another copy
    # would not change the outcome and would grow the administrator's
    # file on every boot.
    if rc_conf_block_has "$1"; then
        log "$RC_CONF already sets $1=YES in the managed block, but"
        log "$1 is still not enabled. A later assignment may override"
        log "it, or the rc.d script may be missing."
        die "Refusing to append a duplicate rc.conf assignment"
    fi

    [ ! -L "$RC_CONF" ] ||
        die "$RC_CONF is a symbolic link; refusing to modify it"

    rc_tmp=$(mktemp "$RC_CONF.XXXXXXXX") ||
        die "Cannot create temporary rc.conf"

    if grep -Fqx "$RC_BEGIN" "$RC_CONF" 2>/dev/null; then
        # Extend the existing block, keeping any assignment already in
        # it, so enabling a second service does not discard the first.
        awk -v end="$RC_END" -v line="$1=YES" '
            $0 == end { print line; print; next }
            { print }
        ' "$RC_CONF" > "$rc_tmp" || {
            rm -f "$rc_tmp"
            die "Cannot rewrite $RC_CONF"
        }
    else
        cat "$RC_CONF" > "$rc_tmp" 2>/dev/null || :
        printf '\n%s\n%s=YES\n%s\n' "$RC_BEGIN" "$1" "$RC_END" >> "$rc_tmp"
    fi

    # rc.conf is sourced by /etc/rc, so a syntax error here would break
    # boot. Validate before installing, the way the engine validates a
    # generated doas.conf with doas -C.
    /bin/sh -n "$rc_tmp" 2>/dev/null || {
        rm -f "$rc_tmp"
        die "Generated $RC_CONF is not valid shell; refusing to install it"
    }

    # Copied in place rather than renamed, so the administrator's
    # ownership and mode on a file this service does not own survive.
    cat "$rc_tmp" > "$RC_CONF" || {
        rm -f "$rc_tmp"
        die "Cannot write $RC_CONF"
    }

    rm -f "$rc_tmp"
}

# onestart rather than start, for the same reason as onestatus: start
# consults rcvar and would refuse if the rc.conf edit above has not
# taken effect, turning one fault into two.
adapter_service_start()
{
    service "$1" onestart >/dev/null
}

# Emit "<package-name> <major> <minor>" for each installable Python
# interpreter the repository offers.
#
# pkgsrc's tools have no remote-listing query: pkg_info -r reports
# "can't find package" for something the repository plainly has, and
# there is no pkgin on a stock install. So the repository index is
# fetched and parsed directly.
#
# Names carry the version twice -- python314-3.14.6.tgz -- so the stem
# is what pkg_add is given and the dotted version is what the engine's
# range is applied to.
adapter_python_packages()
{
    idx=$(mktemp /var/run/ansible-bootstrap-idx.XXXXXXXX) || return 1

    # Redirected to a file rather than piped, so run_bounded's status
    # survives; a pipeline's status would be awk's.
    run_bounded "$PKG_TIMEOUT" ftp -o - "$PKG_PATH" > "$idx" || {
        rm -f "$idx"
        return 1
    }

    [ -s "$idx" ] || {
        rm -f "$idx"
        return 1
    }

    tr '"' '\012' < "$idx" |
        awk '
            /^python3[0-9]+-[0-9]/ {
                stem = $0
                sub(/-[0-9].*$/, "", stem)

                v = $0
                sub(/^python3[0-9]+-/, "", v)
                sub(/\.tgz$/, "", v)

                n = split(v, part, ".")
                print stem, part[1] + 0, (n >= 2) ? part[2] + 0 : 0
            }
        '

    rm -f "$idx"
}

adapter_package_install()
{
    # pkg_add reads PKG_PATH from the environment, exported above.
    run_bounded "$PKG_TIMEOUT" pkg_add "$1"
}
