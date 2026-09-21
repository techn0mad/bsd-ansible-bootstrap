# OpenBSD adapter for the shared ansible-bootstrap engine.
#
# Sourced by the engine as root. Not executable on its own, and has no
# shebang for that reason. Everything OpenBSD-specific about account
# creation, package installation, privilege escalation, and service
# management lives here; see lib/adapter-contract.md for the contract
# this file implements.

# Login shell for the service account. OpenBSD ships ksh in base.
LOGIN_SHELL=/bin/ksh

# doas is in the OpenBSD base system, and its configuration lives in
# /etc.
DOAS_BIN=/usr/bin/doas
DOAS_CONF=/etc/doas.conf

adapter_create_account()
{
    # -p '*' leaves no usable password; SSH public-key authentication
    # is configured separately by the engine.
    useradd -m -d "$HOME_DIR" -s "$LOGIN_SHELL" -p '*' "$ACCOUNT"
}

# doas is always present on OpenBSD, so there is nothing to prepare.
# On platforms where it is a package this is where it gets installed.
adapter_escalation_prepare()
{
    :
}

# `rcctl get <svc> status` exits 0 when the service is enabled for boot
# and 1 when it is not. Do NOT substitute `rcctl ls on`: it enumerates
# every service in /etc/rc.d, measured at 22s on an OpenBSD 7.9 guest,
# and was single-handedly responsible for a 24-second check and a
# 68-second apply.
adapter_service_enabled()
{
    rcctl get "$1" status >/dev/null 2>&1
}

adapter_service_running()
{
    rcctl check "$1" >/dev/null 2>&1
}

# rcctl writes the daemon name to stdout with no trailing newline, the
# way /etc/rc builds its "starting daemons:" line. In a log that runs
# into whatever is printed next, so discard it; failures still arrive
# on stderr, and the engine records the change before calling.
adapter_service_enable()
{
    rcctl enable "$1" >/dev/null
}

adapter_service_start()
{
    rcctl start "$1" >/dev/null
}

# Emit "<package-name> <major> <minor>" for each installable Python
# interpreter the repository offers.
#
# pkg_info -Q matches substrings, so asking for "python" also returns
# unrelated packages (bpython, py3-GitPython), subpackages
# (python-tkinter-3.13.13), and debug packages (debug-python-3.13.13).
# Requiring the stem at the start of the line followed immediately by a
# digit selects only the interpreter itself.
adapter_python_packages()
{
    # Captured before filtering rather than piped: a pipeline's status
    # is the last command's, which would discard a timeout or a failed
    # query and report it to the engine as an empty repository.
    pkg_list=$(run_bounded "$PKG_TIMEOUT" pkg_info -Q python) || return 1

    printf '%s\n' "$pkg_list" |
        awk '
            /^python-[0-9]/ {
                v = substr($0, 8)
                sub(/p[0-9]+$/, "", v)
                n = split(v, part, ".")
                print $0, part[1] + 0, (n >= 2) ? part[2] + 0 : 0
            }
        '
}

# The engine passes a fully qualified name, which matters: an
# unqualified stem is ambiguous — `pkg_add python` prompts to choose
# between 2.7 and 3.x — and the exact name removes the prompt outright
# rather than relying on pkg_add's behaviour when its stdin is closed.
adapter_package_install()
{
    run_bounded "$PKG_TIMEOUT" pkg_add "$1"
}
