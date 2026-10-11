# Termux / Android PIE builds

Caveman's release binaries will not run on Termux. This directory contains the
pieces that fix it, plus the reason why.

## The problem

Three independent blockers, all Android-level:

1. **The release binaries are non-PIE.** Caveman's assets are Go binaries built
   with the default `-buildmode`. On linux/arm64 that produces an ELF with
   `e_type: EXEC`. Android 10+ refuses non-PIE executables:

   ```
   error: "/data/data/com.termux/files/home/caveman-engine" has unexpected e_type: 2
   ```

   The same applies to Go's own official `go1.25.4.linux-arm64.tar.gz` from
   go.dev, so you cannot bootstrap a local toolchain to rebuild them on-device
   either — the compiler itself is non-PIE and won't exec.

2. **`caveman setup --install` rejects android.** `setupPlatform()` in
   `packages/cli/src/index.ts` has no `android` entry, so the installer never
   even tries:

   ```
   no prebuilt binary for android/arm64 — supported: darwin/arm64, ...
   ```

   This one is a table check, not a real limitation, but it means the documented
   install path is closed on this platform.

3. **TLS alignment.** A Go binary built for linux/musl emits `PT_TLS.p_align` of
   8. Android Bionic requires at least 64 on ARM64, because ARM uses TLS variant
   1 (thread pointer + 2-word TCB, then the executable's segment) and Bionic
   parks its TCB in the alignment padding. A binary that gets this wrong is
   refused outright:

   ```
   executable's TLS segment is underaligned: alignment is 8,
   needs to be at least 64 for ARM64 Bionic
   ```

   Getting past blockers 1 and 2 is not enough — a PIE binary with the wrong TLS
   layout either aborts with that message or segfaults at startup.

## The fix

Build the six binaries on a GitHub Actions runner as PIE, linked against
**Bionic** rather than musl, and drop the result into `~/.caveman/bin` on the
device.

Two things carry the load:

- **The Android NDK** supplies a C compiler that targets Bionic. This matters
  because `caveman-proxy` and `caveman-engine` embed the tree-sitter code
  compressor, which is C. Built without cgo they parse Go only, so a Read of a
  TypeScript, Python or Rust file passes through uncompressed (issues #1020,
  #1120).
- **`GOOS=android`** makes Go lay out TLS for Bionic. With `GOOS=linux` the TLS
  segment lands at `p_align` 8, which Android rejects.

That install location is the other half of the fix: `cavemanBin()` in
`packages/cli/src/index.ts` resolves a binary as **env var → PATH →
`~/.caveman/bin`**, and that runtime lookup performs no manifest or checksum
validation. Only `setup --install` verifies `.bin-manifest.json`, and it is not
consulted when the CLI actually spawns a binary. So a PIE binary in
`~/.caveman/bin` is picked up directly.

Verified on-device: all six binaries run, `caveman compress` reports real
compression ratios, and `caveman retrieve` restores the original bytes exactly.

## Files

| File | Purpose |
| --- | --- |
| `.github/workflows/build-termux-pie.yml` | Builds all six binaries for arm64 Android and uploads them. |
| `scripts/install-termux-pie.sh` | Copies the artifact into `~/.caveman/bin` on Termux, refusing any non-PIE input. |
| `scripts/tlsalign.c` | Sets `PT_TLS.p_align` to 64 in a built ELF. A fallback for builds that cannot use the NDK. |

## Use

1. Fork the repo and push these files.
2. Run the workflow: **Actions → Build Android/Termux PIE binaries → Run
   workflow**. Takes a few minutes.
3. Download the `caveman-pie-arm64` artifact.
4. On Termux, from the unpacked artifact:

   ```sh
   ./scripts/install-termux-pie.sh
   ```

5. Verify:

   ```sh
   caveman setup
   echo 'const x = 1;' | caveman compress
   ```

## Build notes

- **The build cross-compiles from x86_64**, not on an arm64 runner. The Android
  NDK only ships x86_64-hosted toolchains — `android-ndk-r28b` has no
  aarch64-hosted download — so an arm64 runner cannot execute its clang
  (`Exec format error`). `GOOS`/`GOARCH` and the NDK's target flags produce
  arm64 code regardless of the host.

- **What does not work**, in case you go down this path:

  - *zig cc for musl.* The upstream build cross-compiles the cgo binaries through
    `zig cc -target aarch64-linux-musl`. That links statically and leaves
    `PT_TLS.p_align` at 8. Patching the field to 64 afterwards makes the loader
    accept the binary, but it still segfaults at startup — a static PIE with a
    TLS segment does not run on Android 10+.
  - *zig targeting Android.* zig's `aarch64-linux-android` target parses only
    with a dotted API level (`aarch64-linux-android.24`), and even then zig
    ships no Android libc headers (its `lib/libc` has glibc, musl, and the BSDs
    — no `android/`), so cgo cannot find `android/log.h`, `stdlib.h`, or
    `pthread.h`.
  - *`GOOS=android` with a non-NDK compiler.* Go's runtime/cgo pulls in
    `android/log.h` when `GOOS=android`, which only the NDK provides.
  - *The runner's own `cc`.* It targets glibc, so the binary ends up wanting
    `/lib/ld-linux-aarch64.so.1` and `libc.so.6`, neither of which exists on
    Android.

- **`-buildmode=pie` is required.** Passing `-pie` through `-extldflags` alone
  fails with `relocation R_AARCH64_ABS64 cannot be used ... recompile with
  -fPIC`: only `-buildmode=pie` compiles Go code as PIC. It is documented as
  unsupported alongside `-linkmode external`, so the workflow keeps a ladder of
  recipes and records which one succeeded in `dist/recipes/<name>`.

- The engine writes the compressed payload to **stdout** and a JSON report to
  **stderr** (see `emitCompressResult` in `engine/cmd/caveman-engine/main.go`).
  There is no `--json` flag — that's the CLI's, not the engine's.

## Limitations

- `caveman setup` reports the binaries as present, but a release-mismatch warning
  can still appear because the manifest's sha256s are computed over the PIE
  binaries, not the signed release assets. It does not affect `cavemanBin()`'s
  lookup, which is how every command actually resolves these.
- The `install-termux-pie.sh` PIE check rejects ET_EXEC on purpose. If you point
  it at a stock release asset it will tell you so rather than install something
  Android will refuse to run.
- Building on the device itself is not possible: the Go toolchain you would need
  is itself non-PIE, and Termux's package repo may be unreachable, leaving the
  GitHub Actions route as the practical option.
