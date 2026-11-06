#!/bin/bash
#
# Tries a repository the way a customer's machine would, from a throwaway
# container: checks the key is the tak3 key, adds the source, apt update, and
# downloads every package this machine's architecture can install, on each suite.
#
# Usage: test-client.sh <url> [<cdn-host>]
#   test-client.sh https://apt.tak3.io                  whatever the name serves now
#   test-client.sh https://dxxxxxxxxxxxxx.cloudfront.net   the new host, by its own name
#   test-client.sh https://apt.tak3.io dxxxxxxxxxxxxx.cloudfront.net
#       the customer's own address, sent to the new host before the name moves:
#       this is the one that also proves the certificate
#
# Needs docker and nothing else, and changes nothing on the machine.
#   TEST_IMAGES  the systems to try
#   TEST_KEY     a key other than tak3's, when trying a test repository

set -euo pipefail

URL=${1:?usage: test-client.sh <url> [<cdn-host>]}
CDN=${2:-}
IMAGES=${TEST_IMAGES:-ubuntu:22.04 ubuntu:24.04 debian:12}
KEY=${TEST_KEY:-95CEC7E930098F1CD49CF155703673E312474624}
# Extra docker options, for a test repository on a docker network.
read -r -a EXTRA <<<"${TEST_DOCKER_ARGS:-}"
ARGS=()
if [ -n "$CDN" ]; then
    # apt has no way to say "connect there instead", so the container's own
    # hosts file does. The address is whichever one this machine resolves.
    NAME=${URL#*://}
    NAME=${NAME%%/*}
    NAME=${NAME%%:*}
    IP=$(docker run --rm ${EXTRA[@]+"${EXTRA[@]}"} "${IMAGES%% *}" getent ahostsv4 "$CDN" | awk 'NR==1 {print $1}')
    [ -n "$IP" ] || { echo "$CDN does not resolve" >&2; exit 1; }
    ARGS+=(--add-host "$NAME:$IP")
fi
client() {
    cat <<'INSIDE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg >/dev/null

curl -fsSL "$URL/tak3-archive-keyring.gpg" -o /usr/share/keyrings/tak3-archive-keyring.gpg
got=$(gpg --show-keys --with-colons /usr/share/keyrings/tak3-archive-keyring.gpg | awk -F: '/^fpr/ {print $10; exit}')
[ "$got" = "$KEY" ] || { echo "FAIL the key served is $got, not $KEY"; exit 1; }
echo "ok   key $got"

arch=$(dpkg --print-architecture)
for suite in stable testing; do
    echo "deb [signed-by=/usr/share/keyrings/tak3-archive-keyring.gpg] $URL $suite main" > /etc/apt/sources.list.d/tak3.list
    rm -rf /var/lib/apt/lists/*
    apt-get update -qq -o APT::Update::Error-Mode=any
    echo "ok   $suite: apt update, signature checked"

    # The address the console's update check and the in-testing job read, with
    # no compression and no redirect.
    curl -fsS --max-redirs 0 "$URL/dists/$suite/main/binary-$arch/Packages" | grep -q '^Version: ' \
        || { echo "FAIL $suite: the Packages index lists nothing"; exit 1; }
    echo "ok   $suite: Packages index readable without apt"

    mkdir -p "/tmp/$suite"
    chmod 777 "/tmp/$suite"
    cd "/tmp/$suite"
    for package in tak3-console tak3-node; do
        for version in $(apt-cache madison "$package" | awk '{print $3}'); do
            apt-get download -qq "$package=$version"
            echo "ok   $suite: downloaded $package $version, hash checked"
        done
    done
    # The other architecture's files are worth a look but not a download.
    for other in amd64 arm64; do
        [ "$other" = "$arch" ] && continue
        curl -fsS "$URL/dists/$suite/main/binary-$other/Packages" | awk '/^Filename: /{print $2}' | while read -r file; do
            curl -fsSI -o /dev/null "$URL/${file//\~/%7E}" || { echo "FAIL $suite: $file is missing"; exit 1; }
            echo "ok   $suite: $file is there"
        done
    done
done
INSIDE
}

for image in $IMAGES; do
    echo "== $image, $URL${CDN:+ through $CDN}"
    client | docker run --rm -i ${ARGS[@]+"${ARGS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"} \
        -e URL="$URL" -e KEY="$KEY" "$image" bash
done
echo "all good"
