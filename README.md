# ygglet-action

A GitHub Action that runs a job's steps in Ygglet Linux, a Linux distribution in which every
binary, down to glibc, libgcc and libstdc++, is compiled with the rr software ticks plugin,
and whose GCC instruments what it compiles too. rr's software ticks (from the
[ChronitonAI rr fork](https://github.com/ChronitonAI/rr/tree/software-ticks)) let a program
built this way be recorded and replayed without hardware performance counters, which
GitHub's hosted runners don't have.

```yaml
jobs:
  test:
    runs-on: ubuntu-24.04
    defaults:
      run:
        shell: ygglet {0}        # every `run:` step after the action runs in the container
    steps:
      - uses: actions/checkout@v4
      - uses: ChronitonAI/ygglet-action@main
      - run: make && make check  # with the image's gcc, make, ...
      - run: python3 tests.py
```

The action starts a container from the image, and puts `ygglet` on `PATH`, a shell that runs a
step's script in that container. Use it as the job's default shell, as above, or for some steps:
`shell: ygglet {0}`. Steps with `uses:` still run on the runner itself, and see the same
workspace. On GitHub's runners the action takes about 30 seconds (it downloads and imports a
620 MiB image).

- **Shells.** `ygglet {0}` runs the script with bash, as GitHub's `bash` shell does (`bash
  --noprofile --norc -eo pipefail`). Another interpreter: `ygglet python3 {0}`. As root:
  `ygglet --root {0}`.
- **User.** Steps run as the runner's user (the action gives it an account in the container),
  so files they write in the workspace belong to it, as with any other step. `--root` for
  root.
- **Files.** The runner's work directory (the workspace, `RUNNER_TEMP`, and the files behind
  `GITHUB_ENV`, `GITHUB_OUTPUT`, `GITHUB_PATH` and `GITHUB_STEP_SUMMARY`) is mounted at the
  same path, so all of these work from inside. The rest of the container's file system is its
  own and persists from step to step for the rest of the job: a `--root` step can install
  into `/usr/local/bin`, say.
- **Environment.** A step keeps its environment (`env:` at any level, `GITHUB_ENV`, `GITHUB_*`
  and `RUNNER_*`), except for the runner machine's own variables (from `/etc/environment`,
  such as `JAVA_HOME_*`) and `HOME`, `PATH` and the like. `PATH` is the image's
  (`/usr/local/bin:/usr/bin`), after any directories steps have added with `GITHUB_PATH`
  since the action ran. Steps keep their `working-directory`, which must be in the work
  directory.
- **Container.** The container (Docker, `--network host`) may use ptrace and has no seccomp
  filter, as rr needs. `docker exec ygglet ...` reaches it from a step on the runner.

## Inputs

| Input | Default | |
|---|---|---|
| `image-url` | `image.env` | The image: a root filesystem tarball from `ygglet build` (`.tar.zst`, `.tar.gz`, `.tar`), as a URL or a path. |
| `image-sha256` | | Its sha256, required with `image-url` (`none` skips the check). |
| `name` | `ygglet` | The container's name. More than one: a step picks one with `env: YGGLET_CONTAINER: <name>`. |
| `docker-options` | | More `docker run` options, separated by whitespace, e.g. `--memory 8g`. |

Outputs: `container` (its name) and `image` (the Docker image).

## The image

The default image is a release of this repository, `image-<hash>`, which `image.env` names, so
a version of the action always gets the same image. It holds the packages of
[`image/Project.toml`](image/Project.toml), at the versions of
[`image/Manifest.toml`](image/Manifest.toml) (the release notes list them): GCC 14 (C, C++),
binutils, GDB, make, CMake, Ninja, pkgconf, Python 3.12, bash, coreutils, findutils, grep,
sed, gawk, diffutils, patch, tar, gzip, xz, zstd, bzip2, jq, less, procps, util-linux, file,
OpenSSL, SQLite, and their libraries, on glibc 2.41 and Linux 6.9 headers. There is no package
manager: an image is fixed when it is built. For other software, build it in a step (it is
instrumented then), or build an image of your own with `ygglet build` and pass it as
`image-url`.

To publish a new default image, update `image/` (with `ygglet resolve`), then run
`scripts/publish-image.sh <ygglet checkout>` (ChronitonAI/ygglet) and commit `image.env`.

## Limitations

- Linux runners with Docker only, x86_64 (GitHub's `ubuntu-*` runners, or self-hosted).
- When a step is cancelled or times out, the process in the container is not stopped; the
  container goes away with the job's runner (or with the next run of the action on a
  self-hosted runner).
