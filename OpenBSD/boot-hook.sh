# OpenBSD boot-hook half of the shared installer.
#
# Sourced by lib/install.sh, never by the engine, and never deployed to
# the target — which is why it is separate from adapter.sh rather than
# more functions in it. It may use the installer's die() and $ENGINE.
#
# Provides: BOOT_HOOK_TARGET, boot_hook_show, boot_hook_install.

BOOT_FILE=/etc/rc.local
BOOT_HOOK_TARGET=$BOOT_FILE

MARKER='# BEGIN ansible-bootstrap'
END_MARKER='# END ansible-bootstrap'

# The block installed into rc.local, also shown when the hook is
# withheld so it can be added by hand later.
boot_hook_show()
{
    cat <<EoF

$MARKER
# Maintain Ansible readiness; this is a short-lived boot task.
#
# /etc/rc runs this file with sh(1) and its output reaches the console,
# so announce the work and report the outcome there. Without this the
# console shows an unexplained pause, and a failed boot-time apply is
# visible only to someone who thinks to read the log.
if [ -x $ENGINE ]; then
    echo 'ansible-bootstrap: reconciling Ansible readiness'
    if $ENGINE apply >> $LOG_FILE 2>&1; then
        echo 'ansible-bootstrap: ready'
    else
        echo 'ansible-bootstrap: FAILED, see $LOG_FILE'
    fi
fi
$END_MARKER
EoF
}

# Install the block exactly once, preserving unrelated contents. An
# existing managed block is replaced rather than left alone, so a
# changed hook reaches hosts that already have an older one; skipping
# would strand them on whatever was current when they were first set up.
boot_hook_install()
{
    [ ! -L "$BOOT_FILE" ] ||
        die "$BOOT_FILE is a symbolic link; refusing to modify it"

    if [ -f "$BOOT_FILE" ] && grep -Fqx "$MARKER" "$BOOT_FILE"; then
        hook_tmp=$(mktemp "$BOOT_FILE.XXXXXXXX") ||
            die "Cannot create temporary boot-hook file"

        # Drop the managed block and any trailing blank lines, so
        # repeated updates do not accumulate separators.
        awk -v begin="$MARKER" -v end="$END_MARKER" '
            $0 == begin { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip       { lines[++n] = $0 }
            END {
                while (n > 0 && lines[n] == "")
                    n--
                for (i = 1; i <= n; i++)
                    print lines[i]
            }
        ' "$BOOT_FILE" > "$hook_tmp" || {
            rm -f "$hook_tmp"
            die "Cannot rewrite $BOOT_FILE"
        }

        boot_hook_show >> "$hook_tmp"

        # Copied in place rather than renamed, so the administrator's
        # ownership and mode on a file this service does not own
        # survive.
        cat "$hook_tmp" > "$BOOT_FILE" || {
            rm -f "$hook_tmp"
            die "Cannot write $BOOT_FILE"
        }

        rm -f "$hook_tmp"
        echo "install: boot hook updated in $BOOT_FILE"
    else
        boot_hook_show >> "$BOOT_FILE"
        echo "install: boot hook added to $BOOT_FILE"
    fi
}
