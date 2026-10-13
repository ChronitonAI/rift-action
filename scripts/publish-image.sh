#!/bin/bash
# Build the image (image/: Project.toml, Manifest.toml, ygglet.toml) with ygglet and publish it
# as this repository's release `image-<hash>`, then point image.env at it; commit image.env
# for the action to use the new image.
#
#   scripts/publish-image.sh <ygglet checkout> [<out dir>]
#
# ygglet is ChronitonAI/ygglet (see its README for its setup); `gh` creates the release.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
ygglet=$(cd "$1" && pwd)
out=$(realpath -m "${2:-${repo}/out}")
gh_repo=ChronitonAI/ygglet-action
mkdir -p "${out}"

"${ygglet}/bin/ygglet" build "${repo}/image" -o "${out}/image.tar.zst"
sha=$(sha256sum "${out}/image.tar.zst" | cut -d' ' -f1)
tag=image-${sha:0:16}
file=ygglet-${sha:0:16}.tar.zst
mv "${out}/image.tar.zst" "${out}/${file}"

# The release notes list the image's packages: the JLLs it installed (usr/share/ygglet/files),
# with their versions from the manifest.
{
    echo "Platform: \`$(sed -n 's/^platform = "\(.*\)"/\1/p' "${repo}/image/ygglet.toml")\`, sha256 \`${sha}\`."
    echo
    echo "| Package | JLL version |"
    echo "|---|---|"
    zstd -dc "${out}/${file}" | tar -t |
        sed -n 's|^\(\./\)\{0,1\}usr/share/ygglet/files/\(.*\)\.list$|\2|p' | sort |
        while read -r jll; do
            version=$(awk -v entry="[[deps.${jll}]]" '$0 == entry { found = 1 }
                found && /^version = / { gsub(/"/, "", $3); print $3; exit }' "${repo}/image/Manifest.toml")
            echo "| ${jll} | ${version} |"
        done
} > "${out}/${file}.md"
if ! gh release view "${tag}" -R "${gh_repo}" > /dev/null 2>&1; then
    gh release create "${tag}" -R "${gh_repo}" --title "${tag}" --latest=false \
        --notes-file "${out}/${file}.md" "${out}/${file}"
fi

cat > "${repo}/image.env" <<EOF
# The action's default image (scripts/publish-image.sh).
IMAGE_URL=https://github.com/${gh_repo}/releases/download/${tag}/${file}
IMAGE_SHA256=${sha}
EOF
echo "${tag}: ${out}/${file}"
