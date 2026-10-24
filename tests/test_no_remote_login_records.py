"""Exercise the ``just check-no-remote-login-records`` image guard.

``just verify`` only ever runs this guard on an image the build has already
cleaned, so nothing proved that it refuses Avahi's sample SSH/SFTP service
files. These tests run the real recipe from the Justfile with a ``podman`` stub
on PATH. The stub checks how the recipe invokes the image, points the recipe's
own shell script at a scratch ``etc/avahi/services`` directory and runs it, so
the guard's logic is exercised unchanged. They require a refusal naming the
offending file for each record the recipe lists, acceptance for an image with
no records or only unrelated ones, and a failure when the container cannot run.

They need ``just`` and run without an image or a container runtime.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
JUSTFILE = REPO / "Justfile"
IMAGE = "registry.invalid/ps-printer-app:under-test"
SERVICES = "/etc/avahi/services/"

PODMAN_STUB = """#!/usr/bin/env bash
printf '%s\\n' "${*:1:$#-1}" >> "$PODMAN_LOG"
[[ "$1" == run ]] || { echo "stub: unexpected podman $1" >&2; exit 99; }
if [[ -n "${PODMAN_RUN_FAIL:-}" ]]; then
  echo "stub: image not found" >&2
  exit 125
fi
script="${!#}"
printf '%s' "$script" > "$PODMAN_SCRIPT"
[[ "$script" == *"$SERVICES"* ]] || { echo "stub: script no longer reads $SERVICES" >&2; exit 98; }
exec bash -ec "${script//"$SERVICES"/"$FAKE_ROOT$SERVICES"}"
"""


@unittest.skipUnless(shutil.which("just"), "just is not installed")
class NoRemoteLoginRecordsTest(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="no-remote-login-"))
        self.addCleanup(shutil.rmtree, self.work, ignore_errors=True)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        podman = self.bin / "podman"
        podman.write_text(PODMAN_STUB)
        podman.chmod(0o755)
        self.root = self.work / "rootfs"
        self.services = self.root / SERVICES.strip("/")
        self.log = self.work / "podman.log"
        self.script = self.work / "script.sh"

    def check(self, services=None, run_fail=False):
        if services is not None:
            self.services.mkdir(parents=True)
            for name in services:
                (self.services / name).write_text("<service-group/>\n")
        env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "IMAGE_REF": IMAGE,
            "PODMAN_LOG": str(self.log),
            "PODMAN_SCRIPT": str(self.script),
            "FAKE_ROOT": str(self.root),
            "SERVICES": SERVICES,
        }
        env.pop("PODMAN_RUN_FAIL", None)
        if run_fail:
            env["PODMAN_RUN_FAIL"] = "1"
        return subprocess.run(
            ["just", "--justfile", str(JUSTFILE), "check-no-remote-login-records"],
            cwd=REPO,
            env=env,
            text=True,
            capture_output=True,
        )

    def assert_ran_image_shell(self):
        self.assertEqual(
            self.log.read_text().splitlines(),
            [f"run --rm --entrypoint /usr/bin/bash {IMAGE} -ec"],
        )

    def assert_refused(self, result, name):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"unexpected Avahi service file: {self.root}{SERVICES}{name}", result.stderr)
        self.assert_ran_image_shell()

    def test_the_recipe_checks_both_sample_records(self):
        self.assertEqual(self.check(services=[]).returncode, 0)
        script = self.script.read_text()
        self.assertIn("ssh.service", script)
        self.assertIn("sftp-ssh.service", script)

    def test_an_image_without_avahi_services_passes(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_ran_image_shell()

    def test_unrelated_service_files_pass(self):
        result = self.check(services=["ipp.service", "ssh.service.disabled", "my-ssh.service"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(f"unexpected Avahi service file: {self.root}", result.stderr)

    def test_the_ssh_record_is_refused(self):
        self.assert_refused(self.check(services=["ssh.service"]), "ssh.service")

    def test_the_sftp_record_is_refused(self):
        self.assert_refused(self.check(services=["sftp-ssh.service"]), "sftp-ssh.service")

    def test_the_ssh_record_is_refused_beside_printer_records(self):
        result = self.check(services=["ipp.service", "ssh.service", "sftp-ssh.service"])
        self.assert_refused(result, "ssh.service")

    def test_a_container_that_cannot_run_fails_closed(self):
        result = self.check(run_fail=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("image not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
