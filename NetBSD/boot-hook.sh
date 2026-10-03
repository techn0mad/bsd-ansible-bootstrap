# NetBSD boot-hook half of the shared installer.
#
# Sourced by lib/install.sh, never by the engine, and never deployed as
# the engine's adapter. It may use the installer's die() and $ENGINE.
#
# Provides: BOOT_HOOK_TARGET, boot_hook_show, boot_hook_install.
#
# NetBSD has rc.local, but rcorder places rc.d/local at 95 -- before
# LOGIN at 110 and sshd at 112 -- so a hook there would run before the
# service whose state it inspects, and before the console is usable.
# This is therefore an rc.d script plus an rc.conf assignment, as on
# FreeBSD, rather than an rc.local block as on OpenBSD.

RC_SCRIPT_SRC=$OS_DIR/rc.d/ansible_bootstrap
RC_SCRIPT=/etc/rc.d/ansible_bootstrap
RC_CONF=/etc/rc.conf
RC_VAR=ansible_bootstrap

# The adapter carries its own copy of this marked-block handling for
# service enablement at boot. Duplicated deliberately: this runs once,
# interactively, at install time, while the adapter's runs unattended on
# every boot and must refuse to append a second time. Sharing them would
# mean deploying installer code to the target, or sourcing engine code
# into the installer.
RC_BEGIN='# BEGIN ansible-bootstrap'
RC_END='# END ansible-bootstrap'

BOOT_HOOK_TARGET="$RC_SCRIPT (enabled with $RC_VAR in $RC_CONF)"

boot_hook_show()
{
    cat <<EoF

Install the rc.d script and enable it:

    install -o root -g wheel -m 0555 \\
        $RC_SCRIPT_SRC $RC_SCRIPT
    echo '$RC_VAR=YES' >> $RC_CONF

The script runs '$ENGINE apply' once at boot, after NETWORKING, LOGIN
and sshd, logging to $LOG_FILE. It is a short-lived task, not a daemon.

NetBSD has no rcctl or sysrc, so enabling means an assignment in
$RC_CONF, which is the administrator's file. The installer writes it
inside a marked block so a later run can recognise its own work.
EoF
}

boot_hook_install()
{
    [ -f "$RC_SCRIPT_SRC" ] ||
        die "Missing rc.d script source: $RC_SCRIPT_SRC"

    [ ! -L "$RC_SCRIPT" ] ||
        die "$RC_SCRIPT is a symbolic link; refusing to replace it"

    # NetBSD's rc.d lives in /etc, not /usr/local/etc: base rc.subr
    # scans rc_directories, which is /etc/rc.d on a stock install.
    install -o root -g wheel -m 0555 "$RC_SCRIPT_SRC" "$RC_SCRIPT" ||
        die "Cannot install $RC_SCRIPT"

    echo "install: rc.d script installed at $RC_SCRIPT"

    if grep -Fqx "$RC_VAR=YES" "$RC_CONF" 2>/dev/null; then
        echo "install: $RC_VAR=YES already set in $RC_CONF"
        return 0
    fi

    [ ! -L "$RC_CONF" ] ||
        die "$RC_CONF is a symbolic link; refusing to modify it"

    rc_tmp=$(mktemp "$RC_CONF.XXXXXXXX") ||
        die "Cannot create temporary rc.conf"

    cat "$RC_CONF" > "$rc_tmp" 2>/dev/null || :

    if grep -Fqx "$RC_BEGIN" "$rc_tmp" 2>/dev/null; then
        awk -v end="$RC_END" -v line="$RC_VAR=YES" '
            $0 == end { print line; print; next }
            { print }
        ' "$RC_CONF" > "$rc_tmp" || {
            rm -f "$rc_tmp"
            die "Cannot rewrite $RC_CONF"
        }
    else
        printf '\n%s\n%s=YES\n%s\n' "$RC_BEGIN" "$RC_VAR" "$RC_END" >> "$rc_tmp"
    fi

    # rc.conf is sourced by /etc/rc: a syntax error here breaks boot.
    /bin/sh -n "$rc_tmp" 2>/dev/null || {
        rm -f "$rc_tmp"
        die "Generated $RC_CONF is not valid shell; refusing to install it"
    }

    # Copied in place, so the administrator's ownership and mode on a
    # file this service does not own survive.
    cat "$rc_tmp" > "$RC_CONF" || {
        rm -f "$rc_tmp"
        die "Cannot write $RC_CONF"
    }

    rm -f "$rc_tmp"
    echo "install: $RC_VAR=YES set in $RC_CONF"
}
