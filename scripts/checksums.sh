#!/usr/bin/env bash
# Adds sha256 and size to every asset of an <emulator>.yaml file.
#
# Each asset ends up as  key: {url, sha256, size}. The update-* workflows write
# assets as plain URLs; this script upgrades those. A hash is only computed
# (by downloading the file) when it is not already known: the copy of the file
# at HEAD is used as a cache, keyed by version + asset key + url, so an asset
# that has not changed is never downloaded again. If a download fails, the
# asset keeps just its url and is retried on the next run.
#
# Usage: bash scripts/checksums.sh <emulator>.yaml   (run from the repo root)
set -euo pipefail

file=$1
cur=$(yq -o=json '.' "$file")

prev='{}'
if old=$(git show "HEAD:$file" 2>/dev/null); then
  prev=$(yq -o=json '.' <<<"$old")
fi

# One item per asset, with its metadata when it is already known
items=$(jq -c --argjson prev "$prev" '
  def asset_url: if type == "object" then .url else . end;
  [ ("stable", "preview", "nightly") as $ch
    | (.[$ch] // []) | to_entries[] | .key as $i | .value as $e
    | $e.assets | to_entries[] | . as $a
    | ($a.value | asset_url) as $u
    | ([$prev[$ch][]? | select(.version == $e.version)] | first | .assets[$a.key]?) as $old
    | { ch: $ch, i: $i, key: $a.key, url: $u,
        meta: (if ($old | type) == "object" and $old.url == $u and $old.sha256 != null
               then {sha256: $old.sha256, size: $old.size}
               elif ($a.value | type) == "object" and $a.value.sha256 != null and $a.value.url == $u
               then {sha256: $a.value.sha256, size: $a.value.size}
               else null end) } ]' <<<"$cur")

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

results=$(
  while read -r item; do
    if [ "$(jq '.meta == null' <<<"$item")" = true ]; then
      url=$(jq -r .url <<<"$item")
      if curl -fsSL --retry 3 --retry-delay 5 --max-time 3600 -o "$tmp" "$url"; then
        sha=$(sha256sum "$tmp" | cut -d' ' -f1)
        size=$(stat -c %s "$tmp")
        item=$(jq -c --arg sha "$sha" --argjson size "$size" '.meta = {sha256: $sha, size: $size}' <<<"$item")
      else
        echo "::warning::could not download $url" >&2
      fi
      rm -f "$tmp"
    fi
    echo "$item"
  done < <(jq -c '.[]' <<<"$items") | jq -s '.'
)

jq --argjson r "$results" '
  reduce $r[] as $x (.; .[$x.ch][$x.i].assets[$x.key] = ({url: $x.url} + ($x.meta // {})))' <<<"$cur" \
  | yq -P -p=json '.' > "$file.new"
mv "$file.new" "$file"
