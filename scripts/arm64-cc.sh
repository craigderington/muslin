#!/bin/sh
# Zig needs dependency-file flags at the driver level, rather than in -Wp.
for argument in "$@"; do
    shift
    case "$argument" in
        -Wp,-MD,*) set -- "$@" -MD -MF "${argument#-Wp,-MD,}" ;;
        # shortcut: omit GNU link maps/diagnostics; use LLVM directly if needed.
        -Wl,--warn-common|-Wl,-Map,*|-Wl,--verbose) ;;
        *) set -- "$@" "$argument" ;;
    esac
done
exec zig cc -target aarch64-linux-musl "$@"
