# Jiang LLVM SDK

This directory owns the reproducible build recipe for Jiang's build-time LLVM toolchain. The SDK contains Clang,
LLD, LLVM headers, and static libraries for the X86, AArch64, and WebAssembly targets. Jiang release binaries link
LLVM statically and do not require this SDK at runtime.

Build a local candidate from a clean `jiang/22.1.8` source tree:

```bash
bash ./jiang/build_sdk.sh --package-revision 1
```

The script verifies the upstream LLVM revision, records the SDK recipe in a manifest, checks the installed tools,
and writes a `.tar.zst` archive with SHA-256 metadata under `build/jiang-sdk`.

The `Jiang LLVM SDK` workflow builds Linux x86_64 and macOS arm64 candidates for SDK feature branches. Every run
verifies and consolidates both platform assets. Pushing a `jiang-sdk-llvm-22.1.8-N` tag resumes or creates a draft,
checks every uploaded asset digest, and publishes the prerelease only after the remote assets match.

If publishing fails after asset verification, push `jiang/sdk-publish-RUN_ID-N` from the maintenance branch while
the consolidated artifact is retained. The recovery run revalidates and publishes those assets without rebuilding.
