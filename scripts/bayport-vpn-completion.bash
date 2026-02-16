#!/bin/bash
# Bash completion for .bayport-vpn.sh script

_bayport_vpn_completion() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # All available options
    opts="-v --verbose -d --debug -n --dry-run -h --help --check-deps --test-config --check-connection --show-config --netbird-status --session-status --clear-session --session-timeout --no-reconnect --max-reconnects --init-routes --verify-routes"

    # Handle arguments that expect a number
    if [[ ${prev} == "--session-timeout" ]]; then
        local timeouts="1800 3600 7200 14400 28800"
        COMPREPLY=( $(compgen -W "${timeouts}" -- ${cur}) )
        return 0
    fi
    if [[ ${prev} == "--max-reconnects" ]]; then
        local counts="1 3 5 10"
        COMPREPLY=( $(compgen -W "${counts}" -- ${cur}) )
        return 0
    fi

    # Default: complete with available options
    if [[ ${cur} == -* ]]; then
        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
        return 0
    fi
}

# Register completion for different possible script names
complete -F _bayport_vpn_completion .bayport-vpn.sh
complete -F _bayport_vpn_completion bayport-vpn.sh
complete -F _bayport_vpn_completion bayport-vpn

# If the script is aliased, you can add that too
# Example: complete -F _bayport_vpn_completion vpn
