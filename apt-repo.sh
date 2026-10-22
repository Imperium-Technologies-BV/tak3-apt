#!/bin/bash
#
# Adds packages to a signed apt repository kept as plain files, the way GitHub
# Pages (or any static host) serves it:
#
#   dists/<suite>/Release, InRelease, Release.gpg
#   dists/<suite>/main/binary-<arch>/Packages(.gz)
#   pool/<suite>/main/<package>_<version>_<arch>.deb
#   tak3-archive-keyring.gpg   the public key customers install
#   index.html                 how to add the repository
#
# Suites are channels, not distributions: one package installs the same way on
# Ubuntu 22.04, 24.04 and Debian 12. "stable" gets releases, "testing" gets
# pre-releases (a tag with a dash, v1.1.0-rc.1) so a build can be tried on a
# real box before customers see it.
#
# Usage: packaging/apt-repo.sh <repo-dir> <suite> <keep> <deb>...
#   <keep>       how many versions of each package the suite keeps
#   APT_KEY_ID   the signing key, already imported into gpg
#   APT_KEY_PASSPHRASE  its passphrase, when it has one (CI has no prompt)
#   APT_URL      the address the repository is served at, for index.html

set -euo pipefail

REPO=${1:?usage: apt-repo.sh <repo-dir> <suite> <keep> <deb>...}
SUITE=${2:?}
KEEP=${3:?}
shift 3
[ $# -gt 0 ] || { echo "no packages given" >&2; exit 1; }
: "${APT_KEY_ID:?APT_KEY_ID must name the signing key}"
APT_URL=${APT_URL:-https://example.invalid/tak3-apt}
case "$SUITE" in stable|testing) ;; *) echo "suite must be stable or testing" >&2; exit 1 ;; esac

POOL="pool/$SUITE/main"
mkdir -p "$REPO/$POOL"
for deb in "$@"; do
    cp -f "$deb" "$REPO/$POOL/"
done

# Keep the newest few of each package: enough to go back one release, few
# enough that a static host's size limit is never near.
cd "$REPO"
for name in $(for f in "$POOL"/*.deb; do dpkg-deb -f "$f" Package; done | sort -u); do
    for arch in $(for f in "$POOL"/"${name}"_*.deb; do dpkg-deb -f "$f" Architecture; done | sort -u); do
        # Newest first, in dpkg's own order, so 1.1.0~beta.1 sorts below 1.1.0.
        sorted=()
        for f in "$POOL"/"${name}"_*_"${arch}".deb; do
            v=$(dpkg-deb -f "$f" Version)
            placed=no
            for i in "${!sorted[@]}"; do
                if dpkg --compare-versions "$v" gt "$(dpkg-deb -f "${sorted[$i]}" Version)"; then
                    sorted=("${sorted[@]:0:$i}" "$f" "${sorted[@]:$i}")
                    placed=yes
                    break
                fi
            done
            [ "$placed" = yes ] || sorted+=("$f")
        done
        for old in "${sorted[@]:$KEEP}"; do
            echo "dropping $old"
            rm -f "$old"
        done
    done
done

ARCHES=$(for f in "$POOL"/*.deb; do dpkg-deb -f "$f" Architecture; done | sort -u | tr '\n' ' ')
for arch in $ARCHES; do
    dir="dists/$SUITE/main/binary-$arch"
    mkdir -p "$dir"
    dpkg-scanpackages --multiversion --arch "$arch" "$POOL" /dev/null > "$dir/Packages" 2>/dev/null
    gzip -9 -n -k -f "$dir/Packages"
done

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=tak3 \
    -o APT::FTPArchive::Release::Label=tak3 \
    -o APT::FTPArchive::Release::Suite="$SUITE" \
    -o APT::FTPArchive::Release::Codename="$SUITE" \
    -o APT::FTPArchive::Release::Architectures="${ARCHES% }" \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="tak3 console and node ($SUITE)" \
    release "dists/$SUITE" > "dists/$SUITE/Release.new"
mv "dists/$SUITE/Release.new" "dists/$SUITE/Release"
# The passphrase goes in on a file descriptor, never on the command line where
# any process on the machine could read it.
sign() {
    if [ -n "${APT_KEY_PASSPHRASE:-}" ]; then
        gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --local-user "$APT_KEY_ID" "$@" \
            3<<<"$APT_KEY_PASSPHRASE"
    else
        gpg --batch --yes --local-user "$APT_KEY_ID" "$@"
    fi
}
sign --clearsign -o "dists/$SUITE/InRelease" "dists/$SUITE/Release"
sign --armor --detach-sign -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"

gpg --batch --yes --export "$APT_KEY_ID" > tak3-archive-keyring.gpg
cat > index.html <<EOF
<!doctype html><meta charset="utf-8"><title>tak3 packages</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:720px;margin:40px auto;padding:0 16px}pre{background:#f3f4f6;padding:12px;overflow:auto}</style>
<h1>tak3 packages</h1>
<p>For Ubuntu 22.04, Ubuntu 24.04 and Debian 12. Add the repository once:</p>
<pre>curl -fsSL $APT_URL/tak3-archive-keyring.gpg | sudo tee /usr/share/keyrings/tak3-archive-keyring.gpg &gt;/dev/null
echo "deb [signed-by=/usr/share/keyrings/tak3-archive-keyring.gpg] $APT_URL stable main" | sudo tee /etc/apt/sources.list.d/tak3.list
sudo apt update</pre>
<p>On a streaming server:</p>
<pre>sudo apt install tak3-node
sudo tak3-node-setup</pre>
<p>On the console host:</p>
<pre>sudo apt install tak3-console
sudo tak3-console-setup</pre>
<p>Updates arrive with <code>sudo apt upgrade</code>. Pre-releases are in the <code>testing</code> suite instead of <code>stable</code>.</p>
EOF
touch .nojekyll
echo "suite $SUITE: $(find "$POOL" -name '*.deb' | wc -l | tr -d ' ') package file(s), signed with $APT_KEY_ID"
