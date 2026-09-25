#!/bin/sh
# verify-source.sh TYPE ARCHIVE SIGNATURE SHA256 SIGNER_FINGERPRINT
set -eu

TYPE=${1:?type}
ARCHIVE=${2:?archive}
SIGNATURE=${3:?signature}
EXPECTED_SHA256=${4:?sha256}
EXPECTED_SIGNER=${5:?signer fingerprint}

actual_sha256=$(sha256sum "$ARCHIVE" | cut -d ' ' -f 1)
if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
    echo "$TYPE checksum mismatch: $actual_sha256" >&2
    exit 1
fi

GNUPGHOME=$(mktemp -d)
STATUS=$(mktemp)
trap 'rm -rf "$GNUPGHOME" "$STATUS"' EXIT
chmod 700 "$GNUPGHOME"

case "$TYPE" in
    kernel)
        gpg --batch --homedir "$GNUPGHOME" --auto-key-locate clear,wkd \
            --locate-keys gregkh@kernel.org >/dev/null 2>&1
        xz -cd "$ARCHIVE" | \
            gpg --batch --homedir "$GNUPGHOME" --status-fd 1 \
                --verify "$SIGNATURE" - >"$STATUS"
        ;;
    busybox)
        curl -fsSL https://busybox.net/~vda/vda_pubkey.gpg | \
            gpg --batch --homedir "$GNUPGHOME" --import >/dev/null 2>&1
        gpg --batch --homedir "$GNUPGHOME" --status-fd 1 \
            --verify "$SIGNATURE" "$ARCHIVE" >"$STATUS"
        ;;
    *)
        echo "unknown source type: $TYPE" >&2
        exit 2
        ;;
esac

if ! grep -q "^\[GNUPG:\] VALIDSIG $EXPECTED_SIGNER " "$STATUS"; then
    echo "$TYPE signature did not match pinned signer $EXPECTED_SIGNER" >&2
    exit 1
fi

echo "$TYPE source: SHA-256 and signature verified"
