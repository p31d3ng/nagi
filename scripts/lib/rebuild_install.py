#!/usr/bin/env python3
"""Rebuild, validate, and transactionally install Nagi without touching user data."""
import argparse
import datetime
import os
from pathlib import Path
import plistlib
import shutil
import shlex
import subprocess
import sys
import tempfile
import uuid

IDENTITY = "local.nagi.journal"


class InstallError(RuntimeError):
    pass


def run(command):
    try:
        subprocess.run([str(part) for part in command], check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise InstallError(f"Command failed: {command[0]} ({error})") from error


def assert_not_running():
    try:
        result = subprocess.run(
            ["/bin/ps", "-axo", "pid=,comm="], check=True,
            capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise InstallError("Cannot check running apps; installation stopped safely.") from error
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and Path(fields[1]).name == "Nagi":
            raise InstallError(
                "Nagi is running. Stop/finalize recording, then choose Nagi → Quit "
                "(closing the window is not enough). Run this script again. "
                "It will not quit or kill the app for you."
            )


def bundle_info(app):
    if app.is_symlink() or not app.is_dir():
        raise InstallError(f"Expected a real app directory, not a symlink: {app}")
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise InstallError(f"Cannot read app metadata: {app}") from error
    if not isinstance(info, dict):
        raise InstallError(f"Invalid app metadata: {app}")
    if info.get("CFBundleIdentifier") != IDENTITY or info.get("CFBundleExecutable") != "Nagi":
        raise InstallError(f"Refusing unrelated or invalid Nagi.app: {app}")
    return info


def validate_bundle(app):
    info = bundle_info(app)
    if not all(isinstance(info.get(key), str) and info[key].strip()
               for key in ("CFBundleShortVersionString", "CFBundleVersion")):
        raise InstallError("Built app has no version/build metadata.")
    runtime = app / "Contents/Resources/Runtime"
    for executable in (app / "Contents/MacOS/Nagi", runtime / "bin/ASRWorker",
                       runtime / "bin/LiveASRWorker", runtime / ".build/debug/SpeakerWorker"):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise InstallError(f"Built app is missing an executable: {executable}")
    if not (runtime / "bin/libNagiVAD.dylib").is_file():
        raise InstallError("Built app is missing its speech detector library.")
    run(["/usr/bin/codesign", "--verify", "--strict", app])
    return info


def check_destination(destination, source):
    if not destination.is_dir():
        raise InstallError(
            f"Destination directory does not exist: {destination}\n"
            "Create a directory you own, e.g. mkdir -p ~/Applications, "
            "then use --destination ~/Applications."
        )
    if not os.access(destination, os.W_OK | os.X_OK):
        raise InstallError(
            f"Destination is not writable: {destination}\n"
            "Use --destination ~/Applications after creating that directory, "
            "or ask an administrator to install the completed build/Nagi.app. "
            "Do not sudo this script or the build; it never changes permissions."
        )
    target = destination / "Nagi.app"
    if target.resolve() == source.resolve() or source.resolve() in target.resolve().parents:
        raise InstallError("Destination must be separate from the build bundle.")
    if target.exists() or target.is_symlink():
        bundle_info(target)  # Refuse unrelated bundles and symlinks before a build.
    return target


def require_model_coverage(source, target):
    if not target.exists():
        return
    relative = Path("Contents/Resources/Runtime/Models")
    old_models = target / relative
    new_models = source / relative
    if old_models.is_symlink():
        raise InstallError("Cannot verify a symlinked installed Models directory. Restore its model assets into the repository Models directory and rebuild first.")
    if not old_models.exists():
        return
    for path in old_models.rglob("*"):
        if path.name == ".DS_Store":
            continue
        if (path.is_file() or path.is_symlink()) and not (new_models / path.relative_to(old_models)).exists():
            raise InstallError(
                "The existing install contains model assets missing from the rebuilt bundle. "
                "Nothing was replaced. Restore missing assets from its "
                "Contents/Resources/Runtime/Models into the repository Models directory "
                "(or run scripts/install-models.sh), rebuild, and retry. "
                "This installer will not silently remove models or modify the signed bundle."
            )


def stage_and_install(source, destination, target):
    require_model_coverage(source, target)
    staging = Path(tempfile.mkdtemp(prefix=".Nagi-install-", dir=destination))
    backup = None
    installed = False
    try:
        staged_app = staging / "Nagi.app"
        # ditto retains resource forks, extended attributes and the complete bundle.
        run(["/usr/bin/ditto", "--rsrc", "--extattr", source, staged_app])
        validate_bundle(staged_app)
        assert_not_running()  # Do not swap a bundle that was launched during copying.
        require_model_coverage(staged_app, target)
        if target.exists() or target.is_symlink():
            bundle_info(target)
            timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            backup = destination / f"Nagi.previous-{timestamp}-{uuid.uuid4().hex[:8]}.app"
            target.rename(backup)
        try:
            staged_app.rename(target)  # Same filesystem: the complete bundle moves at once.
            installed = True
        except BaseException:
            if backup is not None and not target.exists() and not target.is_symlink():
                backup.rename(target)
            raise
        return backup
    finally:
        # Only this invocation's temporary copy is removed. Existing installs/backups survive.
        shutil.rmtree(staging, ignore_errors=True)
        if backup is not None and not installed and backup.exists():
            print(f"Previous app remains recoverable at: {backup}", file=sys.stderr)


def execute(project, destination, dry_run=False):
    source = project / "build/Nagi.app"
    assert_not_running()  # Includes build/Nagi.app and other installed copies.
    target = check_destination(destination, source)
    if dry_run:
        info = validate_bundle(source)
        require_model_coverage(source, target)
        print(f"Dry run: would rebuild with {project / 'scripts/build.sh'}")
        print(f"Would install Nagi {info['CFBundleShortVersionString']} "
              f"(build {info['CFBundleVersion']}) at {target}")
        print("No build, copy, replacement or launch performed.")
        return
    lock = destination / ".nagi-install.lock"
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise InstallError(
            f"Another installer may be running: {lock}. If none is running, remove "
            "this empty stale lock directory with rmdir, then retry."
        ) from error
    try:
        print("Building as your normal user…", flush=True)
        run([project / "scripts/build.sh"])
        info = validate_bundle(source)
        assert_not_running()
        backup = stage_and_install(source, destination, target)
        print(f"Installed Nagi {info['CFBundleShortVersionString']} "
              f"(build {info['CFBundleVersion']}): {target}")
        if backup:
            print(f"Previous app kept at: {backup}")
        print("Journal, voice profile, settings and Keychain are untouched. App was not launched.")
        print(f"Open it in Finder, or run: open {shlex.quote(str(target))}")
    finally:
        lock.rmdir()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=Path("/Applications"),
                        help="existing writable directory (default: /Applications)")
    parser.add_argument("--dry-run", action="store_true",
                        help="validate an existing build and prerequisites; change nothing")
    args = parser.parse_args(argv)
    if os.geteuid() == 0:
        raise InstallError("Run as your normal user, without sudo. Do not build as root.")
    if sys.platform != "darwin":
        raise InstallError("This installer requires macOS.")
    project = Path(__file__).resolve().parents[2]
    execute(project, args.destination.expanduser().resolve(), args.dry_run)


if __name__ == "__main__":
    try:
        main()
    except (InstallError, OSError, KeyboardInterrupt) as error:
        print(f"Installation stopped: {error}", file=sys.stderr)
        sys.exit(1)
