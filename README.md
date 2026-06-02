# strace cross-testing

Continuous cross-architecture testing of [strace](https://strace.io/) on
rarely-tested CPU architectures.

GitHub Actions build a cross toolchain and a minimal root filesystem with
[Buildroot](https://buildroot.org/), cross-compile strace and its test suite
against that toolchain, then boot the target architecture under QEMU system
emulation and run `make check` inside the guest. The point is to exercise
strace's per-architecture support — syscall decoders, register/ABI handling,
struct layouts — on platforms that rarely get tested elsewhere.

## Architectures

| Arch      | QEMU machine | Notes                                            |
|-----------|--------------|--------------------------------------------------|
| `m68k`    | `virt`       | no dedicated TP register, 2-byte `int` alignment |
| `s390x`   | (default)    | z15 target                                       |
| `sparc64` | `sun4u`      | 64-bit, VA hole in the address space             |

Per-architecture QEMU and guest settings (machine, emulator binary, memory,
kernel image, virtio transport, console) live in [`ci/lib.sh`](ci/lib.sh).
Each architecture has a Buildroot defconfig under
[`ci/buildroot-config-<arch>`](ci/).

## Status

The strace test suite passes on all three architectures. `s390x` is clean
out of the box; `m68k` and `sparc64` need the local patches below to pass.

| Arch      | strace patches | toolchain patches |
|-----------|:--------------:|:-----------------:|
| `m68k`    | 4              | 1 (GCC codegen)   |
| `s390x`   | —              | —                 |
| `sparc64` | 1              | —                 |

These are bugs found by the cross-testing itself — in the strace tests on
these architectures, and one m68k compiler miscompile — and are reported
upstream.

## How it works

The workflow ([`.github/workflows/cross.yml`](.github/workflows/cross.yml)) has
two jobs, run as a matrix over the architectures:

1. **build**
   - [`ci/build-buildroot <arch>`](ci/build-buildroot) — runs Buildroot with the
     per-arch config to produce the cross toolchain, kernel, and an initramfs
     (busybox + the host QEMU build).
   - [`ci/build-strace <arch>`](ci/build-strace) — checks out upstream strace,
     applies the patches in [`ci/patches/`](ci/patches), and cross-compiles
     strace plus every `tests*/` directory with the toolchain.
   - The Buildroot output and the strace build tree are cached (and uploaded as
     artifacts) keyed on the Buildroot version, arch config, strace commit, and
     patch set, so the test job reuses them without rebuilding.

2. **test** (sharded across many parallel jobs per architecture)
   - [`ci/run-qemu <arch>`](ci/run-qemu) packs the freshly built strace tree
     into an ext2 image, boots the guest kernel under QEMU, and shares the
     source tree and toolchain over virtio-9p.
   - On boot the guest runs
     [`ci/rootfs-overlay/etc/init.d/S99strace-check`](ci/rootfs-overlay/etc/init.d/S99strace-check),
     which runs `make check` for this shard's tests, records the exit status,
     and powers off.
   - [`ci/shard-tests`](ci/shard-tests) splits each test directory's `$(TESTS)`
     list into shards so the suite runs in parallel across many jobs per arch.

## Patches

Failures uncovered on these architectures are tracked as patches and reported
upstream.

**strace** ([`ci/patches/`](ci/patches), applied by `ci/build-strace`):

- m68k — `restart_syscall-p`, `prctl-seccomp-filter-v`, `seccomp-filter-v`: on
  m68k libc reads the thread pointer via `get_thread_area`, which pollutes
  attach traces and trips the seccomp filters.
- m68k — `net-sockaddr`: `struct sockaddr_ax25` is 14 bytes on m68k (2-byte
  `int` alignment) vs 16 elsewhere.
- sparc64 — `mmap`: the test's fixed hint address falls inside the sparc64 VA
  hole.

**GCC** ([`ci/gcc-patches/`](ci/gcc-patches)):

- m68k — `fold-mem-offsets`: the pass folds a constant offset into a base
  register still used by a memory-to-memory move, miscompiling code at `-O2`.

## Running locally

The `ci/` scripts are plain POSIX shell and can be run outside CI, given a host
with Buildroot's dependencies and the right paths. For example:

```sh
export STRACE_SRC=$PWD/strace BUILDROOT_SRC=$PWD/buildroot OUTPUT_BASE=$PWD/output
./ci/build-buildroot s390x      # toolchain, kernel, rootfs (slow, first time)
./ci/build-strace    s390x      # cross-compile strace + tests
./ci/run-qemu        s390x      # boot under QEMU and run make check
```

Honored environment variables are documented at the top of each script
(`STRACE_TESTS`, `STRACE_SHARD`/`STRACE_SHARDS`, `QEMU_TIMEOUT`, `QEMU_SMP`, …).

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).
