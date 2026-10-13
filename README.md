# rift-action

A GitHub Action for recording programs with rift, an rr-compatible record and replay
debugger, on GitHub's hosted runners, which have no hardware performance counters. It runs a
job's steps in Ygglet Linux, a Linux distribution in which every binary, down to glibc, libgcc
and libstdc++, is compiled with the rr software ticks plugin, and whose GCC instruments what
it compiles too. rr's software ticks (from the
[ChronitonAI rr fork](https://github.com/ChronitonAI/rr/tree/software-ticks)) count progress
in the program's own code, so a program built this way can be recorded without the CPU's
branch counter. The image has a record-only build of rift: it records and packs traces, which
the full rift replays.

```yaml
jobs:
  test:
    runs-on: ubuntu-24.04
    defaults:
      run:
        shell: ygglet {0}        # every `run:` step after the action runs in the container
    env:
      _RR_TRACE_DIR: ${{ github.workspace }}/traces
    steps:
      - uses: actions/checkout@v4
      - uses: ChronitonAI/rift-action@main
      - run: make               # with the image's gcc, so the program is instrumented
      - run: rift record ./my-test && rift pack
      - if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: traces
          path: traces
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
  filter, as rr needs. `docker exec ygglet ...` reaches it from a step on the runner. The action
  also lowers `kernel.perf_event_paranoid` to 1 (with `sudo`, where the runner allows it), since
  rr's syscall buffer needs a perf event (a software one, not a hardware counter).

## Recording

`rift record <program>` records into `$_RR_TRACE_DIR` (default `~/.local/share/rr`), and `rift
pack` makes a trace self-contained, for uploading as an artifact. `rift ls`, `rm`, `mv`, `ps`
and `help` work as in rr; `replay` and the other commands that need a replay are not in this
build. Replay a trace elsewhere with the full rift (`rift replay <trace>`).

What runs under rift must be instrumented: the image's programs and libraries are, and so is
what the image's `gcc`/`g++` compile in a step. Code from elsewhere (a prebuilt binary, a JIT)
is not, and rift cannot record it without hardware counters.

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
OpenSSL, SQLite, and their libraries, on glibc 2.41 and Linux 6.9 headers, plus the
record-only rift (`RiftRecord_jll`, not instrumented, since it is the recorder). There is no package
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
