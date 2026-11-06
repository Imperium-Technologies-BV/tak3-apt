#!/bin/bash
#
# Keeps the apt repository in an S3 bucket, which CloudFront serves. The bucket
# holds the same files apt-repo.sh writes, and is the copy that counts, so a
# publish fetches it, adds to it and sends back what changed.
#
# Usage:
#   s3.sh pull   <site-dir> <before-file>   fetch the bucket, note what it held
#   s3.sh verify <site-dir>                 refuse what the key did not sign
#   s3.sh push   <site-dir> <before-file>   send what changed since then
#
#   APT_S3_BUCKET  the bucket's name; pull and push
#   APT_CDN_URL    CloudFront's own address for it; push
#   APT_KEY_ID     the signing key, already imported into gpg; verify
# AWS credentials come from the environment: the workflow's short-lived role.

set -euo pipefail

COMMAND=${1:?usage: s3.sh pull|verify|push <site-dir> [before-file]}
SITE=${2:?usage: s3.sh pull|verify|push <site-dir> [before-file]}
BEFORE=${3:-}

export AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=5

bucket() {
    : "${APT_S3_BUCKET:?APT_S3_BUCKET must name the bucket}"
    BUCKET="s3://$APT_S3_BUCKET"
}

# What the site holds, as sha256sum lines sorted by path. Git's files and the
# two that only mean something to Pages are not the repository.
snapshot() {
    (cd "$SITE" && find . -type f ! -path './.git/*' ! -name CNAME ! -name .nojekyll -printf '%P\0' \
        | LC_ALL=C sort -z | xargs -0 -r sha256sum --)
}

pull() {
    bucket
    mkdir -p "$SITE"
    aws s3 sync --only-show-errors --no-progress "$BUCKET" "$SITE"
    snapshot > "$BEFORE"
}

# The publish that follows signs everything in the pool, so a file changed in
# the bucket must stop here and not come back out with a good signature. Trust
# runs from the key: the signed Release lists the indexes, the indexes list the
# packages. A package no index lists (an earlier run stopped before its index)
# is dropped; if it is the release being published, that run brings it again.
#
# A run that stopped between its indexes leaves them newer than InRelease. The
# Release file goes up first (see push), so an index may match either: apt reads
# InRelease and only falls back to Release when InRelease is missing.
verify() {
    : "${APT_KEY_ID:?APT_KEY_ID must name the signing key}"
    local keyring vouched
    keyring=$(mktemp)
    vouched=$(mktemp)
    gpg --batch --export "$APT_KEY_ID" > "$keyring"
    cd "$SITE"
    for dir in dists/*/; do
        [ -d "$dir" ] || continue
        local signed
        signed=$(mktemp)
        gpgv --quiet --keyring "$keyring" --output "$signed" "${dir}InRelease" 2>/dev/null \
            || { echo "::error::${dir}InRelease is not signed by $APT_KEY_ID: the bucket was changed outside a publish" >&2; exit 1; }
        if gpgv --quiet --keyring "$keyring" "${dir}Release.gpg" "${dir}Release" 2>/dev/null; then
            cat "${dir}Release" >> "$signed"
        fi
        while IFS= read -r index; do
            local hash
            hash=$(sha256sum < "$index" | cut -d' ' -f1)
            grep -qE "^ $hash +[0-9]+ ${index#"$dir"}\$" "$signed" \
                || { echo "::error::$index is not what the signed Release lists: the bucket was changed outside a publish" >&2; exit 1; }
            case "$index" in
                */Packages)
                    awk '/^Filename: /{f=$2} /^SHA256: /{h=$2} /^$/{if(f)print h"  "f; f=h=""} END{if(f)print h"  "f}' \
                        "$index" >> "$vouched"
                    ;;
            esac
        done < <(find "$dir" -type f \( -name Packages -o -name Packages.gz \))
    done
    [ ! -s "$vouched" ] || sha256sum --check --quiet --strict "$vouched" \
        || { echo "::error::a package in the bucket is not what the signed index lists" >&2; exit 1; }
    while IFS= read -r deb; do
        grep -qF "  ${deb#./}" "$vouched" || { echo "dropping ${deb#./}: no signed index lists it"; rm -f "$deb"; }
    done < <(find . -path './pool/*' -name '*.deb')
    echo "the bucket matches the signatures"
}

upload() {
    echo "uploading $1"
    # S3 refuses a file that does not match its checksum, so success means whole.
    aws s3 cp --only-show-errors --no-progress --checksum-algorithm SHA256 "$SITE/$1" "$BUCKET/$1"
}

# The order is the point: apt must never read an index that names a file the
# pool does not hold. Packages first, and each one proved reachable the way apt
# will ask for it, with its ~ as %7E. Then the indexes, InRelease last because
# it is what makes them current. Only then do old packages go.
push() {
    : "${APT_CDN_URL:?APT_CDN_URL must be the CloudFront address}"
    bucket
    local after
    after=$(mktemp)
    snapshot > "$after"
    local changed gone
    changed=$(LC_ALL=C comm -13 <(LC_ALL=C sort "$BEFORE") <(LC_ALL=C sort "$after") | cut -c67-)
    gone=$(LC_ALL=C comm -23 <(cut -c67- "$BEFORE" | LC_ALL=C sort) <(cut -c67- "$after" | LC_ALL=C sort))

    local packages other release indexes signed
    packages=$(grep -E '^pool/' <<<"$changed" || true)
    other=$(grep -vE '^(pool|dists)/' <<<"$changed" || true)
    release=$(grep -E '^dists/[^/]+/Release$' <<<"$changed" || true)
    release+=$'\n'$(grep -E '^dists/[^/]+/Release\.gpg$' <<<"$changed" || true)
    indexes=$(grep -E '^dists/[^/]+/main/' <<<"$changed" || true)
    signed=$(grep -E '^dists/[^/]+/InRelease$' <<<"$changed" || true)

    local path
    while IFS= read -r path; do
        [ -z "$path" ] || upload "$path"
    done <<<"$packages"
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        curl -fsS --retry 5 --retry-all-errors --retry-delay 5 -o /dev/null -I "$APT_CDN_URL/${path//\~/%7E}" \
            || { echo "::error::CloudFront does not serve $path; the indexes were left as they are" >&2; exit 1; }
    done <<<"$packages"
    while IFS= read -r path; do
        [ -z "$path" ] || upload "$path"
    done <<<"$other"$'\n'"$release"$'\n'"$indexes"$'\n'"$signed"
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        echo "removing $path"
        aws s3 rm --only-show-errors "$BUCKET/$path"
    done <<<"$gone"
    rm -f "$after"
}

case "$COMMAND" in
    pull) [ -n "$BEFORE" ] || { echo "pull needs a before-file" >&2; exit 1; }; pull ;;
    verify) verify ;;
    push) [ -f "$BEFORE" ] || { echo "push needs the before-file pull wrote" >&2; exit 1; }; push ;;
    *) echo "usage: s3.sh pull|verify|push <site-dir> [before-file]" >&2; exit 1 ;;
esac
