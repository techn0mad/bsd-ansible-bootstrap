# FreeBSD boot-hook half of the shared installer.
#
# Sourced by lib/install.sh, never by the engine, and never deployed as
# the engine's adapter. It may use the installer's die() and $ENGINE.
#
# Provides: BOOT_HOOK_TARGET, boot_hook_show, boot_hook_install.
#
# Unlike OpenBSD, there is no rc.local to append to — /etc/rc on 15.1
# contains no reference to it — so the hook is a real rc.d script plus
# an rc.conf variable. That is the documented FreeBSD mechanism and it
# gives proper ordering control, which rc.local never did.

RC_SCRIPT_SRC=$OS_DIR/rc.d/ansible_bootstrap
RC_SCRIPT=/usr/local/etc/rc.d/ansible_bootstrap
RC_VAR=ansible_bootstrap_enable

BOOT_HOOK_TARGET="$RC_SCRIPT (enabled with $RC_VAR)"

boot_hook_show()
{
    cat <<EoF

Install the rc.d script and enable it:

    install -o root -g wheel -m 0555 \\
        $RC_SCRIPT_SRC $RC_SCRIPT
    sysrc $RC_VAR=YES

The script runs '$ENGINE apply' once at boot, after NETWORKING, logging
to $LOG_FILE. It is a short-lived task, not a daemon.
EoF
}

# Installing the script is idempotent by nature — it is a whole file
# this service owns, so it is simply overwritten, with no block to
# locate inside a file belonging to someone else. That makes this the
# easier half of the platform split, not the harder one.
boot_hook_install()
{
    [ -f "$RC_SCRIPT_SRC" ] ||
        die "Missing rc.d script source: $RC_SCRIPT_SRC"

    [ ! -L "$RC_SCRIPT" ] ||
        die "$RC_SCRIPT is a symbolic link; refusing to replace it"

    install -d -m 0755 "$(dirname -- "$RC_SCRIPT")"

    # 0555 root:wheel, matching how ports install their rc.d scripts:
    # readable and executable, writable by nobody.
    install -o root -g wheel -m 0555 "$RC_SCRIPT_SRC" "$RC_SCRIPT" ||
        die "Cannot install $RC_SCRIPT"

    echo "install: rc.d script installed at $RC_SCRIPT"

    # sysrc reports the assignment it makes; keep the installer's
    # output consistent by saying it ourselves instead.
    sysrc "$RC_VAR=YES" >/dev/null ||
        die "Cannot set $RC_VAR in rc.conf"

    echo "install: $RC_VAR=YES set in rc.conf"
}
