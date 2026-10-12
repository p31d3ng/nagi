# Rebuild and install Nagi

From the repository, after stopping/finalizing any recording and choosing
**Nagi → Quit**, run as your normal user:

```sh
./scripts/rebuild-install.sh
```

This invokes the existing scripts/build.sh pipeline, checks the completed bundle
identity/version/helpers and code signature, checks that it covers model assets in any existing install, copies the entire bundle with ditto
into a hidden staging directory beside /Applications/Nagi.app, verifies that copy,
and only then moves it into place. Bundled models, helpers, resource forks and
extended attributes are preserved. The same local.nagi.journal bundle ID/signing
approach is used; no signing bypass, certificate, TCC reset or security change occurs.

The script checks every running executable named Nagi before building and again
before installing. Any running copy blocks installation. Closing its window is not
quitting; use Nagi → Quit yourself. The script never stops/kills an app or launches
it afterward. Do not reopen Nagi while the script is running. A concurrently
launched app may block completion; no process check can lock out other launches.

A previous install is renamed to **Nagi.previous-<timestamp>-<unique-id>.app** in
the destination and retained. Copy/validation failures leave the previous install
in place; a final move failure rolls it back. Each individual bundle move is an
atomic same-filesystem rename; replacing two directories is not one atomic
transaction. A forced kill/power failure between moves can leave the recoverable
backup instead of Nagi.app. Quit Nagi and restore that backup in Finder if needed.
Backups are not removed automatically and consume disk space, including old models.
The journal, profile and settings in ~/Library/Application Support/Nagi and existing
Keychain entries are not read/copied/changed by this installer.

Open the installed app yourself:

```sh
open /Applications/Nagi.app
```

## Requirements and options

Requirements match the build: Apple Silicon, macOS 15+, Xcode/Swift 6.2+, CMake,
Python 3, and the pinned source dependencies prepared by scripts/bootstrap.sh in
../Dependencies. The wrapper uses Bash and the helper uses Python's standard
library plus macOS ps, ditto and codesign. It handles spaces/apostrophes in paths.
Run it from any directory by using the script's full path.

If the old installed app has model assets absent from the new bundle, replacement is refused before copying/moving the old app. Restore missing assets from the installed Contents/Resources/Runtime/Models into the repository Models folder, or run the model installer and rebuild. The script does not inject old models into a signed new bundle or silently drop them.

This does not download models or bootstrap dependencies. It copies whichever
models the existing build pipeline bundles from local Models. If needed, run
scripts/install-models.sh separately after reviewing model terms. Model weights
remain excluded from Git; an install without models will show missing-model status.

If /Applications is not writable, the script stops with instructions. Do not sudo
the build or this script; it refuses root execution and does not change permissions.
Use a directory you own instead:

```sh
mkdir -p "$HOME/Applications"
./scripts/rebuild-install.sh --destination "$HOME/Applications"
```

Or ask an administrator to install the completed build/Nagi.app. There is no silent
sudo escalation. The destination directory must already exist; unrelated bundles
and symlink targets are refused. A per-destination .nagi-install.lock prevents two
copies of this installer from replacing the app together. If an installer crashed,
confirm none is running before removing that empty lock with rmdir.

Read-only check (requires an existing successful build and Nagi quit):

```sh
./scripts/rebuild-install.sh --dry-run
```

Dry run validates the current build/destination/process state but performs no
build, copy, replacement or launch. For an isolated check, pass --destination to
an empty writable test directory.

## Verification on the Studio

Bash syntax and ShellCheck passed. Fourteen isolated Python tests passed, using a
small ad-hoc-signed synthetic executable bundle in temporary directories. Real
ditto copies, signature checks, model fixture preservation and rename/rollback
were exercised. Tests cover spaces/apostrophes, fresh install, retained backup,
build/copy/swap failures, running-app and late-launch refusal, process-check failure,
unrelated/symlink targets, destination-only model preservation/refusal, missing helper/bad signature, dry run, permissions/root
refusal, missing destination and stale installer lock. Only the build call and
process-state fixtures are mocked where needed; no running user app is killed.

A read-only dry run validated the actual Nagi 0.4.3/build 10 bundle against an empty
workspace destination and left it empty. With an isolated Nagi instance running,
the real CLI returned exit 1 and that process survived. /Applications was not
modified, and the script did not install the real app during this task.

Reproduce fixture tests:

```sh
python3 scripts/test-rebuild-install.py
bash -n scripts/rebuild-install.sh
shellcheck scripts/rebuild-install.sh  # optional development lint tool
```
