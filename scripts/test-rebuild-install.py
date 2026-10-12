#!/usr/bin/env python3
"""Isolated installer tests. Never builds/installs the user's app or quits a process."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).parent / "lib/rebuild_install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_dir = tempfile.TemporaryDirectory(prefix="Nagi installer fixture ")
        cls.fixture = Path(cls.fixture_dir.name) / "Nagi.app"
        executable = cls.fixture / "Contents/MacOS/Nagi"
        executable.parent.mkdir(parents=True)
        subprocess.run(["/usr/bin/clang", "-x", "c", "-", "-o", str(executable)],
                       input="int main(void) { return 0; }\n", text=True, check=True)
        runtime = cls.fixture / "Contents/Resources/Runtime"
        for path in [runtime / "bin/ASRWorker", runtime / "bin/LiveASRWorker",
                     runtime / ".build/debug/SpeakerWorker"]:
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(executable, path)
        (runtime / "bin/libNagiVAD.dylib").write_bytes(b"synthetic fixture library")
        (runtime / "Models").mkdir()
        (runtime / "Models/test-model.gguf").write_bytes(b"synthetic fixture, not model weights")
        with (cls.fixture / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": installer.IDENTITY, "CFBundleExecutable": "Nagi",
                           "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "test",
                           "CFBundleVersion": "1"}, stream)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(cls.fixture)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture_dir.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Nagi install test ' spaces ")
        self.root = Path(self.temp.name)
        self.project = self.root / "Project with spaces"
        self.source = self.project / "build/Nagi.app"
        self.source.parent.mkdir(parents=True)
        shutil.copytree(self.fixture, self.source)
        self.destination = self.root / "Applications with spaces"
        self.destination.mkdir()
        self.target = self.destination / "Nagi.app"

    def tearDown(self):
        self.temp.cleanup()

    def existing(self):
        shutil.copytree(self.fixture, self.target)
        (self.target / "previous-marker").write_text("recoverable previous app")

    def execute(self, dry_run=False):
        real_run = installer.run
        def fake_build(command):
            if Path(command[0]) == self.project / "scripts/build.sh":
                return  # Only the build pipeline is mocked; copy/signature/moves are real.
            real_run(command)
        with patch.object(installer, "assert_not_running"), patch.object(installer, "run", side_effect=fake_build):
            installer.execute(self.project, self.destination, dry_run)

    def test_fresh_install_preserves_models_signature_and_spaces(self):
        self.execute()
        installer.validate_bundle(self.target)
        self.assertEqual((self.target / "Contents/Resources/Runtime/Models/test-model.gguf").read_bytes(),
                         b"synthetic fixture, not model weights")
        self.assertFalse((self.destination / ".nagi-install.lock").exists())
        self.assertFalse(list(self.destination.glob(".Nagi-install-*")))

    def test_replace_keeps_recoverable_backup(self):
        self.existing(); self.execute()
        backups = list(self.destination.glob("Nagi.previous-*.app"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "previous-marker").exists())
        self.assertFalse((self.target / "previous-marker").exists())

    def test_build_failure_leaves_existing_install(self):
        self.existing()
        with patch.object(installer, "assert_not_running"), patch.object(installer, "run", side_effect=installer.InstallError("synthetic build failure")):
            with self.assertRaises(installer.InstallError):
                installer.execute(self.project, self.destination)
        self.assertTrue((self.target / "previous-marker").exists())
        self.assertFalse((self.destination / ".nagi-install.lock").exists())

    def test_copy_failure_leaves_existing_install(self):
        self.existing()
        with patch.object(installer, "run", side_effect=installer.InstallError("synthetic copy failure")):
            with self.assertRaises(installer.InstallError):
                installer.stage_and_install(self.source, self.destination, self.target)
        self.assertTrue((self.target / "previous-marker").exists())
        self.assertFalse(list(self.destination.glob(".Nagi-install-*")))

    def test_swap_failure_rolls_back_previous_install(self):
        self.existing()
        original = Path.rename
        def fail_new_app(path, destination):
            if path.parent.name.startswith(".Nagi-install-"):
                raise OSError("synthetic rename failure")
            return original(path, destination)
        with patch.object(installer, "assert_not_running"), patch.object(Path, "rename", fail_new_app):
            with self.assertRaises(OSError):
                installer.stage_and_install(self.source, self.destination, self.target)
        self.assertTrue((self.target / "previous-marker").exists())
        self.assertFalse(list(self.destination.glob("Nagi.previous-*.app")))

    def test_running_app_in_spaced_path_refuses_without_kill(self):
        process = subprocess.CompletedProcess([], 0, " 42 /Applications with spaces/Nagi.app/Contents/MacOS/Nagi\n")
        with patch.object(installer.subprocess, "run", return_value=process):
            with self.assertRaisesRegex(installer.InstallError, "Nagi is running"):
                installer.assert_not_running()

    def test_process_check_failure_is_closed(self):
        with patch.object(installer.subprocess, "run", side_effect=OSError("synthetic ps failure")):
            with self.assertRaisesRegex(installer.InstallError, "Cannot check"):
                installer.assert_not_running()

    def test_unrelated_bundle_symlink_and_source_destination_refused(self):
        self.target.mkdir()
        with self.assertRaises(installer.InstallError):
            installer.check_destination(self.destination, self.source)
        self.target.rmdir(); self.target.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(installer.InstallError):
            installer.check_destination(self.destination, self.source)
        with self.assertRaises(installer.InstallError):
            installer.check_destination(self.source.parent, self.source)

    def test_bad_signature_or_missing_helper_refused(self):
        (self.source / "Contents/Resources/Runtime/bin/ASRWorker").unlink()
        with self.assertRaises(installer.InstallError):
            installer.validate_bundle(self.source)
        shutil.copytree(self.fixture, self.source, dirs_exist_ok=True)
        (self.source / "Contents/Resources/Runtime/Models/test-model.gguf").write_bytes(b"modified")
        with self.assertRaises(installer.InstallError):
            installer.validate_bundle(self.source)

    def test_dry_run_creates_nothing_and_does_not_build(self):
        with patch.object(installer, "assert_not_running"):
            installer.execute(self.project, self.destination, True)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_destination_permission_and_stale_lock_fail_safely(self):
        with patch.object(installer.os, "access", return_value=False):
            with self.assertRaisesRegex(installer.InstallError, "Do not sudo"):
                installer.check_destination(self.destination, self.source)
        (self.destination / ".nagi-install.lock").mkdir()
        with patch.object(installer, "assert_not_running"):
            with self.assertRaisesRegex(installer.InstallError, "Another installer"):
                installer.execute(self.project, self.destination)
        self.assertFalse(self.target.exists())

    def test_app_started_during_copy_leaves_existing_install(self):
        self.existing()
        with patch.object(installer, "assert_not_running", side_effect=installer.InstallError("Nagi is running")):
            with self.assertRaises(installer.InstallError):
                installer.stage_and_install(self.source, self.destination, self.target)
        self.assertTrue((self.target / "previous-marker").exists())
        self.assertFalse(list(self.destination.glob("Nagi.previous-*.app")))

    def test_sudo_and_missing_destination_are_refused(self):
        with patch.object(installer.os, "geteuid", return_value=0):
            with self.assertRaisesRegex(installer.InstallError, "without sudo"):
                installer.main([])
        with self.assertRaisesRegex(installer.InstallError, "does not exist"):
            installer.check_destination(self.root / "missing", self.source)

    def test_destination_only_models_refused_without_touching_install(self):
        self.existing()
        asset = self.target / "Contents/Resources/Runtime/Models/old-only-model.gguf"
        asset.write_bytes(b"synthetic old-only model")
        with self.assertRaisesRegex(installer.InstallError, "model assets missing"):
            installer.stage_and_install(self.source, self.destination, self.target)
        self.assertEqual(asset.read_bytes(), b"synthetic old-only model")
        self.assertTrue((self.target / "previous-marker").exists())
        self.assertFalse(list(self.destination.glob(".Nagi-install-*")))
        self.assertFalse(list(self.destination.glob("Nagi.previous-*.app")))
        with patch.object(installer, "assert_not_running"):
            with self.assertRaisesRegex(installer.InstallError, "model assets missing"):
                installer.execute(self.project, self.destination, True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
