#!/bin/bash
# The action (action.yml): load the image into Docker, start the container with the runner's
# work directory mounted at the same path, give the runner's user an account in it, and put
# the `ygglet` shell (bin/ygglet) on PATH for the job's later steps.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
url=${YGGLET_IMAGE_URL}
sha=${YGGLET_IMAGE_SHA256}
name=${YGGLET_NAME}
if [[ -z ${url} ]]; then
    source "${here}/image.env"
    url=${IMAGE_URL}
    sha=${IMAGE_SHA256}
elif [[ -z ${sha} ]]; then
    echo "::error::image-sha256 is required with image-url ('none' skips the check)"
    exit 1
fi
state=${RUNNER_TEMP}/ygglet/${name}
mkdir -p "${state}"

# The Docker image is named by the tarball's hash, so a runner that keeps its Docker images
# (self-hosted) loads each image once.
if [[ ${sha} == none ]]; then
    image=ygglet:url-$(printf %s "${url}" | sha256sum | cut -c1-16)
    docker image rm -f "${image}" > /dev/null 2>&1 || true
else
    image=ygglet:${sha:0:16}
fi
if ! docker image inspect "${image}" > /dev/null 2>&1; then
    if [[ -f ${url} ]]; then
        tarball=${url}
    else
        tarball=${state}/image
        echo "::group::Download ${url}"
        curl -fsSL --retry 5 --retry-all-errors -o "${tarball}" "${url}"
        echo "::endgroup::"
    fi
    [[ ${sha} == none ]] || echo "${sha}  ${tarball}" | sha256sum -c --quiet -
    case ${url} in
        *.zst) decompress=(zstd -dc) ;;
        *.gz)  decompress=(gzip -dc) ;;
        *)     decompress=(cat) ;;
    esac
    "${decompress[@]}" "${tarball}" |
        docker import --change 'ENV PATH=/usr/local/bin:/usr/bin' - "${image}" > /dev/null
    [[ ${tarball} == "${url}" ]] || rm -f "${tarball}"
fi

# rr needs ptrace and system calls that Docker's seccomp profile refuses. The workspace,
# RUNNER_TEMP (where the runner writes each step's script and the files behind GITHUB_ENV,
# GITHUB_OUTPUT, ...) and the actions are all under the work directory, normally.
work=$(dirname "${RUNNER_WORKSPACE}")
mounts=(-v "${work}:${work}")
for d in "${GITHUB_WORKSPACE}" "${RUNNER_TEMP}"; do
    [[ ${d} == "${work}"/* ]] || mounts+=(-v "${d}:${d}")
done
read -ra options <<< "${YGGLET_DOCKER_OPTIONS}"
docker rm -f "${name}" > /dev/null 2>&1 || true
docker run -d --name "${name}" --init --network host \
    --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
    "${mounts[@]}" "${options[@]}" "${image}" sleep infinity > /dev/null

# Steps run as the runner's user, so that what they write to the workspace is the runner's.
uid=$(id -u)
if [[ ${uid} != 0 ]]; then
    docker exec -u 0 -e uid="${uid}" -e gid="$(id -g)" -e user="$(id -un)" -e group="$(id -gn)" \
        "${name}" /bin/bash -euc '
        grep -q "^[^:]*:[^:]*:${gid}:" /etc/group || echo "${group}:x:${gid}:" >> /etc/group
        if ! grep -q "^[^:]*:[^:]*:${uid}:" /etc/passwd; then
            echo "${user}:x:${uid}:${gid}:${user}:/home/${user}:/bin/bash" >> /etc/passwd
        fi
        home=$(awk -F: -v uid="${uid}" "\$3 == uid { print \$6; exit }" /etc/passwd)
        mkdir -p "${home}"
        chown "${uid}:${gid}" "${home}"'
fi

printf '%s\n' "${PATH}" > "${state}/path"
echo "${here}/bin" >> "${GITHUB_PATH}"
echo "YGGLET_CONTAINER=${name}" >> "${GITHUB_ENV}"
echo "image=${image}" >> "${GITHUB_OUTPUT}"
docker exec "${name}" cat /etc/os-release
