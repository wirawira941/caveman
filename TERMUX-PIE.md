# Termux / Android PIE builds

Caveman's release binaries will not run on Termux. This directory contains the
two pieces that fix it, plus the reason why.

## The problem

Two independent blockers, both Android-level:

1. **The binaries are non-PIE.** Caveman's release assets are Go binaries built
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

## The fix

Build the six binaries as **PIE** (`-buildmode=pie`) on a GitHub Actions arm64
runner, then drop them into `~/.caveman/bin` on the device.

That location is the key: `cavemanBin()` in `packages/cli/src/index.ts` resolves
a binary as **env var → PATH → `~/.caveman/bin`**, and that runtime lookup
performs no manifest or checksum validation. Only `setup --install` verifies
`.bin-manifest.json`, and it is not consulted when the CLI actually spawns a
binary. So a PIE binary in `~/.caveman/bin` is picked up directly.

Verified on-device: a `DYN` (PIE) ELF executes; an `EXEC` one does not.

## Files

| File | Purpose |
| --- | --- |
| `.github/workflows/build-termux-pie.yml` | Builds all six binaries as PIE on `ubuntu-24.04-arm`, verifies every output is `ET_DYN`, and uploads them. |
| `scripts/install-termux-pie.sh` | Copies the artifact into `~/.caveman/bin` on Termux, refusing any non-PIE input. |

## Use

1. Fork the repo and push these two files.
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

   Compression should report a real ratio instead of the 0% pass-through you get
   with no engine.

## Build notes

- **cgo binaries.** `caveman-proxy` and `caveman-engine` embed the tree-sitter
  code compressor, which is C. Built without cgo they parse Go only, so a Read
  of a TypeScript, Python or Rust file passes through uncompressed (issues
  #1020, #1120). They compile through `zig cc -target aarch64-linux-musl`, pinned
  to the same zig the release uses (0.16.0).

- **`-buildmode=pie` is documented as unsupported alongside `-linkmode external`**,
  so the workflow tries four recipes in order and keeps whichever first yields a
  PIE binary. The winning recipe is written to `dist/recipes/<name>` and included
  in the artifact. Recipes A–C are static; recipe D is a dynamic build and emits
  a warning, since Termux has no glibc and a dynamic binary needs verifying on
  the device.

- **Pure-Go binaries** (`caveman-mcp`, `cavemem`, `caveman-browse`,
  `caveman-shrink`) take `-buildmode=pie` directly.

- The engine writes the compressed payload to **stdout** and a JSON report to
  **stderr** (see `emitCompressResult` in `engine/cmd/caveman-engine/main.go`).
  There is no `--json` flag — that's the CLI's, not the engine's.

## Limitations

- `caveman setup` may still report a release mismatch, because the manifest's
  sha256s are computed over the PIE binaries, not the signed release assets. It
  does not affect `cavemanBin()`'s lookup, which is how every command actually
  resolves these.
- The `install-termux-pie.sh` PIE check rejects ET_EXEC on purpose. If you point
  it at a stock release asset it will tell you so rather than install something
  Android will refuse to run.
- Building on the device itself is not possible from the release artifacts: the
  Go toolchain you would need is itself non-PIE, and Termux's package repo may be
  unreachable (as it was when this was written), leaving the GitHub Actions
  route as the practical option.
