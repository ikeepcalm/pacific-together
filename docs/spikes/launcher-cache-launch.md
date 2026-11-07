# Installer cache and launch target, 2026-11-07

Observed: the owner's extracted fb1df2f cache contained game/ and its version stamp but no install.ps1 or root documentation. The embedded executable still contained install.ps1. Unpack checked only the version stamp and accepted the incomplete cache.

The launcher now verifies all embedded files for presence and expected length, repairs an incomplete cache through its staging directory and validates extraction before promoting it. Install also repairs missing/truncated mod files even when the installed version stamp matches. It retains the supported-executable hash check and save backup behavior.

Direct launch starts the selected Win64 executable with its binary folder as the working directory, regardless of Steam installation. The persisted Launch through Steam checkbox explicitly selects Steam.exe -applaunch 1458140 instead. Direct launch is the default; existing three-line launcher settings remain readable.

Validation: tools/test-launcher-package.ps1 against local/launcher-candidate.exe passed 13 checks in local/launcher-package-c4d8bf48e6814397b98e6ae67b82e777. It reproduces a stamp-only cache, deleted installer and truncated native DLL; checks complete-cache reuse and every embedded file; runs a small executable at the selected path and checks its actual working directory; verifies the Steam command without starting it; installs the real payload against the supported executable in a fresh isolated folder, removes worldclock.lua and verifies same-version repair and direct-IP configuration. LOCALAPPDATA and APPDATA are isolated in the test process; real installs/saves are not changed. The previous fb1df2f executable fails the first cache-repair assertion, reproducing the owner's report.

No Steam-library game launch, Steam-absent gameplay, alternate game build or two-account networking is certified by these installer tests.
