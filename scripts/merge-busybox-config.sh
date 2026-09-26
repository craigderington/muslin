#!/bin/sh
# Apply a small CONFIG_X=value fragment to a complete BusyBox .config.
set -eu

CONFIG=${1:?config}
FRAGMENT=${2:?fragment}

while IFS='=' read -r key value; do
    case "$key" in
        CONFIG_*)
            sed -i \
                -e "s/^# $key is not set\$/$key=$value/" \
                -e "s/^$key=.*/$key=$value/" \
                "$CONFIG"
            ;;
    esac
done <"$FRAGMENT"
