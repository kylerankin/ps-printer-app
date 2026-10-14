import gzip
import hashlib
import io
import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from scripts import benchmark_foomatic_ppds as benchmark
from scripts.benchmark_foomatic_ppds import (
    PHASES,
    RECIPE,
    benchmark_commands,
    inventory,
    recipe_build_commands,
    run_phase,
    stage_fsdk_install,
    time_operation,
)

PPD_TEXT = "*PPD-Adobe: 4.3\n*CloseUI *Duplex\n*1284DeviceId: MFG:Acme;\n"


class PpdPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.work = Path(self.temporary.name)
        self.build = self.work / "build"
        self.root = self.build / "PPD"
        self.root.mkdir(parents=True)

    def tearDown(self):
        self.temporary.cleanup()

    def write_gz(self, path: Path, text: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(gzip.compress(text.encode("ascii")))

    def retained(self) -> list[str]:
        return sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*") if p.is_file())

    def test_fsdk_staging_gzips_every_ppd_and_keeps_other_files(self):
        source = self.work / "source/PPD"
        (source / "Acme").mkdir(parents=True)
        (source / "Acme/printer.ppd").write_text(PPD_TEXT, encoding="ascii")
        (source / "Acme/PDF").mkdir()
        (source / "Acme/PDF/pdf.ppd").write_text(PPD_TEXT, encoding="ascii")
        (source / "Acme/ReadMe.htm").write_text("<p>notes</p>", encoding="ascii")
        (source / ".svn").mkdir()
        (source / ".svn/entries").write_text("svn", encoding="ascii")
        staged = self.work / "staged/PPD"

        stage_fsdk_install(source, staged)

        self.assertEqual(
            sorted(p.relative_to(staged).as_posix() for p in staged.rglob("*") if p.is_file()),
            ["Acme/PDF/pdf.ppd.gz", "Acme/ReadMe.htm", "Acme/printer.ppd.gz"],
        )
        self.assertEqual(
            gzip.decompress((staged / "Acme/printer.ppd.gz").read_bytes()).decode("ascii"),
            PPD_TEXT,
        )
        self.assertEqual(inventory(staged)["compressed_ppd_files"], 2)

    def test_family_removal_drops_only_pdf_pxl_pcl5_directories(self):
        for family in ("PDF", "PXL", "PCL5", "PS"):
            self.write_gz(self.root / "Acme" / family / f"{family}.ppd.gz", PPD_TEXT)
        self.write_gz(self.root / "Acme/printer.ppd.gz", PPD_TEXT)

        run_phase("family_removal", self.build)

        self.assertEqual(self.retained(), ["Acme/PS/PS.ppd.gz", "Acme/printer.ppd.gz"])

    def test_decompression_gunzips_ppd_gz_inputs(self):
        self.write_gz(self.root / "Acme/printer.ppd.gz", PPD_TEXT)
        self.write_gz(self.root / "Acme/sub/other.ppd.gz", "*PPD-Adobe: 4.3\n")

        run_phase("decompression", self.build)

        self.assertEqual(self.retained(), ["Acme/printer.ppd", "Acme/sub/other.ppd"])
        self.assertEqual((self.root / "Acme/printer.ppd").read_text(encoding="ascii"), PPD_TEXT)
        after = inventory(self.root)
        self.assertEqual((after["ppd_files"], after["compressed_ppd_files"]), (2, 0))

    def test_non_ppd_removal_deletes_other_files_and_sets_mode_0644(self):
        manufacturer = self.root / "Acme"
        manufacturer.mkdir()
        (manufacturer / "printer.ppd").write_text(PPD_TEXT, encoding="ascii")
        (manufacturer / "printer.ppd").chmod(0o755)
        (manufacturer / "private.ppd").write_text(PPD_TEXT, encoding="ascii")
        (manufacturer / "private.ppd").chmod(0o600)
        (manufacturer / "ReadMe.htm").write_text("<p>notes</p>", encoding="ascii")
        (manufacturer / "broken.ppd.gz").write_bytes(b"not gzip")

        run_phase("non_ppd_removal_and_mode", self.build)

        self.assertEqual(self.retained(), ["Acme/printer.ppd", "Acme/private.ppd"])
        for name in ("printer.ppd", "private.ppd"):
            self.assertEqual((manufacturer / name).stat().st_mode & 0o7777, 0o644, name)

    def test_sanitization_applies_both_upstream_compatibility_corrections(self):
        ppd = self.root / "Acme/printer.ppd"
        ppd.parent.mkdir()
        ppd.write_text(
            "*CloseUI *Duplex\n*CloseUI: *InputSlot\n*1284DeviceId: MFG:Acme;\n"
            "*%*CloseUI comment\n",
            encoding="ascii",
        )

        run_phase("sanitization", self.build)

        self.assertEqual(
            ppd.read_text(encoding="ascii"),
            "*CloseUI: *Duplex\n*CloseUI: *InputSlot\n*1284DeviceID: MFG:Acme;\n"
            "*%*CloseUI comment\n",
        )

    def test_full_recipe_yields_sanitized_postscript_ppds_only(self):
        self.write_gz(self.root / "Acme/printer.ppd.gz", PPD_TEXT)
        self.write_gz(self.root / "Acme/PXL/pxl.ppd.gz", PPD_TEXT)
        (self.root / "Acme/ReadMe.htm").write_text("<p>notes</p>", encoding="ascii")

        for key, _, _ in PHASES:
            run_phase(key, self.build)

        self.assertEqual(self.retained(), ["Acme/printer.ppd"])
        ppd = self.root / "Acme/printer.ppd"
        self.assertEqual(
            ppd.read_text(encoding="ascii"),
            "*PPD-Adobe: 4.3\n*CloseUI: *Duplex\n*1284DeviceID: MFG:Acme;\n",
        )
        self.assertEqual(ppd.stat().st_mode & 0o7777, 0o644)


class RecipeDriftGuardTests(unittest.TestCase):
    """`main()` refuses to benchmark commands the shipped element no longer runs."""

    def test_benchmark_commands_match_the_shipped_recipe(self):
        self.assertEqual(recipe_build_commands(RECIPE), benchmark_commands())

    def test_benchmark_commands_cover_every_phase_and_the_untimed_edges(self):
        commands = benchmark_commands()
        self.assertEqual(commands[:2], list(benchmark.RECIPE_COPY))
        self.assertEqual(commands[-1], benchmark.RECIPE_PYPPD)
        for _, _, script in PHASES:
            for line in script.splitlines():
                self.assertIn(line, commands)

    def test_recipe_build_commands_reads_only_the_build_commands_block(self):
        recipe = Path(self.enterContext(tempfile.TemporaryDirectory())) / "element.bst"
        recipe.write_text(
            "kind: manual\n"
            "config:\n"
            "  build-commands:\n"
            "    - |\n"
            "      mkdir -p PPD\n"
            "\n"
            "      pyppd -v -o foomatic-ps-ppds PPD\n"
            "  install-commands:\n"
            "    - install -D -m 0755 foomatic-ps-ppds \"%{install-root}/usr/share/ppd/x\"\n",
            encoding="utf-8",
        )

        self.assertEqual(
            recipe_build_commands(recipe),
            ["mkdir -p PPD", "pyppd -v -o foomatic-ps-ppds PPD"],
        )


class MainRefusalTests(unittest.TestCase):
    """The three checks `main()` makes before it stages or times anything."""

    def setUp(self):
        self.work = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.foomatic = self.work / "foomatic-db"
        (self.foomatic / "db/source/PPD").mkdir(parents=True)
        self.pyppd = self.work / "pyppd"
        (self.pyppd / "bin").mkdir(parents=True)
        (self.pyppd / "bin/pyppd").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.report = self.work / "reports/benchmark.json"

    def run_main(self, foomatic=None, pyppd=None):
        argv = [
            "benchmark_foomatic_ppds.py",
            str(foomatic or self.foomatic),
            str(pyppd or self.pyppd),
            str(self.report),
        ]
        stderr = io.StringIO()
        with patch.object(benchmark.sys, "argv", argv), redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as raised:
                with redirect_stdout(io.StringIO()):
                    benchmark.main()
        return raised.exception.code, stderr.getvalue()

    def test_refuses_a_missing_foomatic_ppd_source(self):
        code, message = self.run_main(foomatic=self.work / "absent")

        self.assertEqual(code, 2)
        self.assertIn("Foomatic PPD source directory not found", message)
        self.assertFalse(self.report.parent.exists())

    def test_refuses_a_missing_pyppd_executable(self):
        (self.pyppd / "bin/pyppd").unlink()

        code, message = self.run_main()

        self.assertEqual(code, 2)
        self.assertIn("pyppd executable not found", message)
        self.assertFalse(self.report.parent.exists())

    def test_refuses_a_recipe_whose_build_commands_drifted(self):
        drifted = self.work / "drifted.bst"
        drifted.write_text(
            "config:\n"
            "  build-commands:\n"
            "    - |\n"
            "      mkdir -p PPD\n"
            "  install-commands:\n"
            "    - install -D -m 0755 foomatic-ps-ppds \"%{install-root}/usr/share/ppd/x\"\n",
            encoding="utf-8",
        )

        with patch.object(benchmark, "RECIPE", drifted):
            code, message = self.run_main()

        self.assertEqual(code, 2)
        self.assertIn("build-commands changed; update PHASES", message)
        self.assertFalse(self.report.parent.exists())


class TimeOperationTests(unittest.TestCase):
    def test_returns_the_elapsed_time_and_reports_the_phase_name(self):
        stdout = io.StringIO()
        calls = []

        with redirect_stdout(stdout):
            elapsed = time_operation("decompression", lambda: calls.append(1))

        self.assertEqual(calls, [1])
        self.assertGreaterEqual(elapsed, 0.0)
        self.assertRegex(stdout.getvalue(), r"^decompression: \d+\.\d{3}s\n$")


class InventoryTests(unittest.TestCase):
    def test_counts_nothing_for_an_empty_tree_and_ignores_directories(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (root / "Acme").mkdir()

        self.assertEqual(
            inventory(root),
            {
                "files": 0,
                "ppd_files": 0,
                "compressed_ppd_files": 0,
                "bytes": 0,
                "ppd_bytes": 0,
                "compressed_ppd_bytes": 0,
            },
        )


if __name__ == "__main__":
    unittest.main()


FAKE_PYPPD = r'''#!/usr/bin/env python3
"""Stand-in for pyppd: records what it was given and writes a listing archive."""
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
source = Path(args[-1])
ppds = sorted(p.relative_to(source).as_posix() for p in source.rglob("*.ppd"))
Path(os.environ["FAKE_PYPPD_LOG"]).write_text(
    json.dumps(
        {
            "args": args,
            "cwd": os.getcwd(),
            "pythonpath": os.environ.get("PYTHONPATH"),
            "ppds": {p: (source / p).read_text(encoding="ascii") for p in ppds},
        }
    ),
    encoding="utf-8",
)
archive = Path(args[args.index("-o") + 1])
if os.environ.get("FAKE_PYPPD_EMPTY"):
    archive.write_bytes(b"")
else:
    listing = "".join(f"foomatic-ps-ppds:0/{p}\n" for p in ppds)
    archive.write_text(
        '#!/bin/sh\n[ "$1" = list ] || exit 64\ncat <<\'LISTING\'\n' + listing + "LISTING\n",
        encoding="ascii",
    )
    archive.chmod(0o755)
'''


class MainRunTests(unittest.TestCase):
    """`main()` past its refusals: staging, phases, archive checks and the report."""

    RETAINED = ["Acme/laser.ppd", "Acme/printer.ppd"]

    def setUp(self):
        self.work = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.foomatic = self.work / "foomatic-db"
        source = self.foomatic / "db/source/PPD"
        for name in ("Acme/printer.ppd", "Acme/laser.ppd", "Acme/PDF/pdf.ppd", "Acme/PXL/pxl.ppd"):
            (source / name).parent.mkdir(parents=True, exist_ok=True)
            (source / name).write_text(PPD_TEXT, encoding="ascii")
        (source / "Acme/ReadMe.htm").write_text("<p>notes</p>", encoding="ascii")
        (source / ".svn").mkdir()
        (source / ".svn/entries").write_text("svn", encoding="ascii")
        self.foomatic_commit = self.git_commit(self.foomatic)

        self.pyppd = self.work / "pyppd"
        (self.pyppd / "bin").mkdir(parents=True)
        (self.pyppd / "bin/pyppd").write_text(FAKE_PYPPD, encoding="utf-8")
        self.pyppd_commit = self.git_commit(self.pyppd)

        self.pyppd_log = self.work / "pyppd-log.json"
        self.scratch = self.work / "tmp"
        self.scratch.mkdir()
        self.report = self.work / "reports/benchmark.json"
        self.enterContext(patch.dict(benchmark.os.environ, {"FAKE_PYPPD_LOG": str(self.pyppd_log)}))
        self.enterContext(patch.object(benchmark.tempfile, "tempdir", str(self.scratch)))
        self.enterContext(patch.object(benchmark, "MINIMUM_DRIVERS", len(self.RETAINED)))

    @staticmethod
    def git_commit(path: Path) -> str:
        def git(*args: str) -> str:
            return subprocess.run(
                ["git", "-C", str(path), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                 "-c", "commit.gpgsign=false", *args],
                check=True, capture_output=True, text=True,
            ).stdout.strip()

        git("init", "-q")
        git("add", "-A")
        git("commit", "-q", "--allow-empty", "-m", "fixture")
        return git("rev-parse", "HEAD")

    def run_main(self):
        argv = ["benchmark_foomatic_ppds.py", str(self.foomatic), str(self.pyppd), str(self.report)]
        stdout = io.StringIO()
        with patch.object(benchmark.sys, "argv", argv), redirect_stdout(stdout):
            code = benchmark.main()
        return code, stdout.getvalue()

    def assert_aborted(self, message: str) -> None:
        with self.assertRaisesRegex(RuntimeError, message):
            self.run_main()
        self.assertFalse(self.report.exists())
        self.assertFalse(self.report.with_suffix(".md").exists())
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_writes_the_json_and_markdown_report_for_the_archived_ppds(self):
        code, stdout = self.run_main()

        self.assertEqual(code, 0)
        report = json.loads(self.report.read_text(encoding="utf-8"))
        self.assertEqual(report["recipe"], "elements/printer-app/foomatic-ps-ppds.bst")
        self.assertEqual(
            report["source"],
            {"foomatic_commit": self.foomatic_commit, "pyppd_commit": self.pyppd_commit},
        )
        self.assertEqual(report["source_inventory"]["ppd_files"], 4)
        self.assertEqual(report["source_inventory"]["files"], 6)
        self.assertEqual(report["staged_inventory"]["compressed_ppd_files"], 4)
        self.assertEqual(report["staged_inventory"]["files"], 5)
        self.assertEqual(sorted(report["inventory_after_phase"]), sorted(key for key, _, _ in PHASES))
        after = report["inventory_after_phase"]
        self.assertEqual(after["family_removal"]["compressed_ppd_files"], 2)
        self.assertEqual(after["decompression"]["ppd_files"], 2)
        self.assertEqual(after["decompression"]["files"], 3)
        self.assertEqual(after["sanitization"]["files"], 2)
        self.assertEqual(sorted(report["phase_seconds"]), sorted(benchmark.PHASE_KEYS))
        self.assertEqual(
            list(report["untimed_seconds"]),
            ["archive_listing", "build_tree_copy", "fsdk_install_staging"],
        )

        listing = "".join(f"foomatic-ps-ppds:0/{p}\n" for p in self.RETAINED)
        self.assertEqual(report["archive"]["drivers"], 2)
        self.assertEqual(report["archive"]["listing_bytes"], len(listing))
        self.assertEqual(
            report["archive"]["driver_listing_sha256"], hashlib.sha256(listing.encode()).hexdigest()
        )
        self.assertEqual(
            report["retained_ppd_paths_sha256"],
            hashlib.sha256(("\n".join(self.RETAINED) + "\n").encode()).hexdigest(),
        )

        pyppd = json.loads(self.pyppd_log.read_text(encoding="utf-8"))
        self.assertEqual(pyppd["args"], ["-v", "-o", "foomatic-ps-ppds", "PPD"])
        self.assertEqual(Path(pyppd["cwd"]).name, "build")
        self.assertEqual(pyppd["pythonpath"], str(self.pyppd.resolve()))
        self.assertEqual(sorted(pyppd["ppds"]), self.RETAINED)
        for text in pyppd["ppds"].values():
            self.assertIn("*CloseUI: *Duplex", text)
            self.assertIn("*1284DeviceID:", text)

        markdown = self.report.with_suffix(".md").read_text(encoding="utf-8")
        self.assertEqual(stdout[stdout.index("### Foomatic PPD benchmark"):], markdown)
        self.assertIn(f"foomatic-db `{self.foomatic_commit}`", markdown)
        self.assertIn("- FSDK-staged input: 4 `.ppd.gz`", markdown)
        self.assertIn("- Archived PPD files: 2 (", markdown)
        self.assertIn("2 discoverable driver entries", markdown)
        for _, label, _ in PHASES:
            self.assertIn(f"| {label} | ", markdown)
        self.assertIn("| pyppd parse/compress/archive | ", markdown)
        self.assertIn(f"JSON report: `{self.report}`", markdown)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_aborts_when_a_ppd_is_not_mode_0644_after_the_phases(self):
        real_run_phase = benchmark.run_phase

        def run_phase_then_loosen_mode(key, build_dir):
            real_run_phase(key, build_dir)
            if key == "sanitization":
                (build_dir / "PPD/Acme/laser.ppd").chmod(0o755)

        with patch.object(benchmark, "run_phase", run_phase_then_loosen_mode):
            self.assert_aborted(r"PPDs not mode 0644 after chmod: \['Acme/laser.ppd'\]")
        self.assertFalse(self.pyppd_log.exists())

    def test_aborts_when_pyppd_writes_an_empty_archive(self):
        with patch.dict(benchmark.os.environ, {"FAKE_PYPPD_EMPTY": "1"}):
            self.assert_aborted("pyppd did not produce a non-empty archive")

    def test_aborts_when_the_archive_lists_fewer_drivers_than_the_floor(self):
        with patch.object(benchmark, "MINIMUM_DRIVERS", len(self.RETAINED) + 1):
            self.assert_aborted("pyppd archive exposes only 2 drivers; expected at least 3")
