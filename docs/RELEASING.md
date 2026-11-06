# Releases

Current preview: **0.8.9**, protocol **7** (2026-11-04). Version constants live in
`mod/PacificTogether/Scripts/common.lua`; the native runtime version is `NATIVE_VERSION` in `dllmain.cpp`.
The UE4SS-facing `ModVersion` label still says 0.0.5; reconcile that metadata before packaging a public build. Changes go in
[../CHANGELOG.md](../CHANGELOG.md).

## Visibility and versioning

- Before 1.0, builds are developer/friend previews. GitHub releases stay **draft**, visible only to collaborators;
  1.0 is the first public release. Nexus publishing is a later owner decision.
- Tags use `vX.Y.Z` on `main`; prerelease tags may use `vX.Y.Z-beta.N`.
- Use semantic versions going forward: patches for compatible fixes, minor versions for features or protocol changes,
  major versions for breaking changes after 1.0. Existing 0.0.x previews predate that discipline; milestone IDs do not
  prescribe version numbers.
- Increment `PROTOCOL_VERSION` for wire changes. Both players need matching mod, protocol and game builds. DLC
  compatibility is still a validation gap; the current handshake does not establish mixed-DLC support.

## Release gate

Record the evidence for the candidate commit; implementation alone does not satisfy a gate.

1. Run the full configured regression suite on the merged candidate. Include the summary and explain any missing
   coverage; the suite is the list in `tools/run-suite.ps1`, not every scenario in the repository.
2. New gameplay checks have failing mutations. Core scenarios pass at 150 ms lag and 2% loss through the tunnel.
3. Complete the human full-run playtest and two-account Steam join check. Historical passes do not validate a new build.
4. Update the changelog; verify the game build/hash in [../CLAUDE.md](../CLAUDE.md) and the pinned UE4SS archive hash.
5. Before 1.0, finish the two-hour soak, the firewalled crash-upload proof, and removal of test-only native registrations.

See [TESTING.md](TESTING.md) for commands and [TASKS.md](TASKS.md) for outstanding work.

## Build the preview

Build the native mod first, then run:

```powershell
tools\package\package.ps1
```

The script requires a clean `mod/` tree and the pinned UE4SS zip (override with `-UE4SSZip`). It produces
`dist/PacificTogether-<version>-dev-<commit>.exe` and `dist/SHA256SUMS.txt`: one file, the launcher with the package below
embedded as `payload.zip` and unpacked on first start to `%LOCALAPPDATA%\PacificTogether\app\<version>`
(`dist/PacificTogether-<version>-dev-<commit>/` is the same package unpacked).
It copies the existing native DLL; it does not prove that DLL was rebuilt from the current commit.

```text
install.cmd / install.ps1           command-line installer
README.txt / GUIDE.md / CHANGELOG.md player documentation
game/                               payload installed into PenDriverPro/Binaries/Win64/
  ue4ss/                            pinned UE4SS, settings and license
    Mods/PacificTogether/           Lua scripts and version.txt
    Mods/PacificTogetherNative/      dlls/main.dll
```

The package bundles UE4SS without debug symbols/docs and disables its console windows. No game files or test bots ship.
Test-only native functions are currently gated at runtime by `PT_SCENARIO`; exclude them from public builds before 1.0.

The installer verifies the game exe hash, backs up saves on the first install of each build and writes the chosen join
address. Uninstall removes the entire `ue4ss` folder, including other UE4SS mods. Player instructions live in
[../tools/package/GUIDE.md](../tools/package/GUIDE.md).

## Release notes

Include: mod/protocol version, supported game build and exe hash, UE4SS pin/hash, changes, known issues, test summary,
human-playtest results and artifact checksum. Do not label a preview as a public release or turn unrun checks into passes.

Protocol 6 is set by the repository author (PLAN D26). Keep PT1/PT1A and protocol-6 payload compatibility; new capabilities must negotiate support. Ship the matching Lua plus native DLL and include `mod/PacificTogether/MULTIVOID-LICENSE.txt`. Integration evidence is in [PT10](spikes/PT10-cloud-local-integration.md); selected validation does not replace the full release suite.
