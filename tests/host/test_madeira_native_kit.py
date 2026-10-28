import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest
import warnings
import zipfile
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "madeira_native_kit", ROOT / "scripts/madeira_native_kit.py"
)
kit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(kit)


class MadeiraNativeKitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ideck-kit-test-")
        self.root = pathlib.Path(self.temp.name)
        self.original_root = kit.ROOT
        kit.ROOT = self.root

    def tearDown(self):
        kit.ROOT = self.original_root
        self.temp.cleanup()

    def entries(self, wow64=False, mono=False):
        data = {
            "archives/" + name: b"!<arch>\n" + name.encode() + (
                kit.ARM64EC_MACH_RETURN_BYTES if name == "libntdll_unix.a" else b""
            )
            for name in kit.ARCHIVES
        }
        data.update({
            "resources/cacert.pem": b"# comment\n-----BEGIN CERTIFICATE-----\ntest\n",
            "resources/prefix-template.tar.gz": b"\x1f\x8btest data",
            "resources/nls/locale.nls": b"locale",
            "resources/legal/COPYING": b"license",
            "resources/licenses/NOTICE": b"notice",
            "resources/d3d12/libmetalirconverter.dylib": b"dummy-not-production",
            "resources/d3d12/canary_vs.dxil": b"dxil",
            "resources/d3d12/canary_ps.dxil": b"dxil",
            "resources/d3d12/canary_layout_vs.dxil": b"dxil",
            "resources/d3d12/canary_layout_ps.dxil": b"dxil",
        })
        for name in kit.REQUIRED_PE + (kit.WOW64_FILES if wow64 else ()):
            data["resources/" + name] = b"MZ" + name.encode()
        if mono:
            data["resources/wine-mono/bin/libmono-2.0-x86.dll"] = b"MZmono"
        return data

    def save(self, entries, wow64=False, mono=False, extras=None,
             corrupt=None, revision=None):
        path = self.root / "kit.zip"
        manifest = {
            "schema": 1,
            "madeira_revision": revision or kit.REVISION,
            "platform": "iphoneos-arm64",
            "wow64": wow64,
            "wine_mono": mono,
            "arm64ec_context_patch_sha256": kit.ARM64EC_CONTEXT_PATCH_SHA256,
            "files": {
                name: {
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "size": len(data),
                } for name, data in entries.items()
            },
        }
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("metadata.json", json.dumps(manifest))
            for name, data in entries.items():
                archive.writestr(name, (b"x" * len(data) if name == corrupt else data))
            for name, data in extras or []:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(name, data)
        return path

    def test_flavors_and_locations(self):
        self.assertEqual(kit.flavor(False, False), "base")
        self.assertEqual(kit.flavor(True, False), "wow64")
        self.assertEqual(kit.flavor(False, True), "mono")
        self.assertEqual(kit.flavor(True, True), "wow64-mono")
        self.assertEqual(
            kit.default_path(True, False, False),
            self.root / "runtime/prebuilt/ios-arm64/madeira-wow64.zip",
        )

    def test_unpack_validates_files_and_generates_relocatable_linker_flags(self):
        path = self.save(self.entries())
        output = self.root / "extracted"
        kit.install(path, output, False, False)
        self.assertTrue((output / "resources/arm64ec-windows/d3d11.dll").is_file())
        self.assertTrue((output / "archives/libFEXCore.a").is_file())
        flags = (self.root / "build/madeira-native/link-flags.txt").read_text()
        self.assertIn("-force_load", flags)
        self.assertIn(str(output / "archives/libdxmt_combined.a"), flags)
        self.assertIn("-framework Metal", flags)
        self.assertIn("-lcurses -lxml2", flags)
        self.assertNotIn("vendor/Madeira", flags)

    def test_wow64_and_mono_are_independent(self):
        path = self.save(self.entries(wow64=True, mono=True), True, True)
        kit.install(path, self.root / "full", True, True)
        with self.assertRaisesRegex(kit.KitError, "options mismatch"):
            kit.inspect(path, False, False)

    def test_rejects_invalid_or_unexpected_sha256(self):
        entries = self.entries()
        target = "resources/arm64ec-windows/winemetal.dll"
        path = self.save(entries, corrupt=target)
        with self.assertRaisesRegex(kit.KitError, "SHA-256 mismatch"):
            kit.install(path, self.root / "corrupted", False, False)
        self.assertFalse((self.root / "corrupted").exists())

    def test_rejects_traversal_and_duplicates(self):
        entries = self.entries()
        path = self.save(entries, extras=[("../unsafe", b"bad")])
        with self.assertRaisesRegex(kit.KitError, "Unsafe kit entry"):
            kit.inspect(path, False, False)
        path = self.save(entries, extras=[(next(iter(entries)), b"duplicate")])
        with self.assertRaisesRegex(kit.KitError, "duplicate"):
            kit.inspect(path, False, False)

    def test_rejects_binary_without_mach_return_even_with_current_metadata(self):
        entries = self.entries()
        entries["archives/libntdll_unix.a"] = b"!<arch>\n" + b"old-native"
        path = self.save(entries)
        with self.assertRaisesRegex(kit.KitError, "ARM64EC Mach return opcode missing"):
            kit.install(path, self.root / "old-code", False, False)
        self.assertFalse((self.root / "old-code").exists())

    def test_rejects_old_or_wrong_arm64ec_runtime(self):
        entries = self.entries()
        path = self.save(entries)
        with zipfile.ZipFile(path) as archive:
            meta = json.loads(archive.read("metadata.json"))
            files = {name: archive.read(name) for name in archive.namelist() if name != "metadata.json"}
        meta["arm64ec_context_patch_sha256"] = "0" * 64
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("metadata.json", json.dumps(meta))
            for name, data in files.items():
                archive.writestr(name, data)
        with self.assertRaisesRegex(kit.KitError, "ARM64EC Mach context patch mismatch"):
            kit.inspect(path, False, False)

    def test_rejects_revision_mismatch(self):
        path = self.save(self.entries(), revision="0" * 40)
        with self.assertRaisesRegex(kit.KitError, "revision/platform/options mismatch"):
            kit.inspect(path, False, False)

    def test_rejects_symlink_entries(self):
        path = self.save(self.entries())
        with zipfile.ZipFile(path, "a") as archive:
            link = zipfile.ZipInfo("resources/symlink")
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            archive.writestr(link, b"/etc/passwd")
        with self.assertRaisesRegex(kit.KitError, "symbolic links"):
            kit.inspect(path, False, False)

    def test_export_ignores_empty_madeira_resource_placeholders(self):
        madeira = self.root / "vendor/Madeira"
        bridge = self.root / "build/madeira-native"
        for name, path in kit.archive_paths(madeira, bridge).items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(
                b"!<arch>\n" + name.encode() +
                (kit.ARM64EC_MACH_RETURN_BYTES if name == "libntdll_unix.a" else b"")
            )

        for wow64 in (False, True):
            with self.subTest(wow64=wow64):
                staged = self.root / ("staged-wow64" if wow64 else "staged-base")
                staged.mkdir()
                for name, value in self.entries(wow64=wow64).items():
                    if name.startswith("resources/"):
                        target = staged / name.removeprefix("resources/")
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(value)
                for folder in ("arm64ec-windows", "i386-windows", "legal"):
                    directory = staged / folder
                    directory.mkdir(parents=True, exist_ok=True)
                    (directory / ".gitkeep").touch()
                    (directory / "unused-empty.txt").touch()
                (staged / "legal" / ".DS_Store").write_bytes(b"incidental-metadata")

                archive_path = self.root / ("kit-wow64.zip" if wow64 else "kit-base.zip")
                with mock.patch.object(kit.subprocess, "check_output", return_value=kit.REVISION + "\n"):
                    kit.build_kit(archive_path, madeira, bridge, wow64, False, staged)
                with zipfile.ZipFile(archive_path) as archive:
                    names = archive.namelist()
                    self.assertIn("resources/arm64ec-windows/ntdll.dll", names)
                    self.assertFalse(any(name.endswith((".gitkeep", "unused-empty.txt", ".DS_Store")) for name in names))
                    if wow64:
                        self.assertIn("resources/i386-windows/ntdll.dll", names)
                installed = self.root / ("installed-wow64" if wow64 else "installed-base")
                kit.install(archive_path, installed, wow64, False)
                self.assertTrue((installed / "resources/arm64ec-windows/ntdll.dll").is_file())

    def test_collect_can_use_staged_ipa_as_resource_source(self):
        madeira = self.root / "vendor/Madeira"
        bridge = self.root / "build/madeira-native"
        resource_root = self.root / "staged-iDeck.app"
        resource_root.mkdir()
        for name, value in self.entries().items():
            if name.startswith("resources/"):
                destination = resource_root / name.removeprefix("resources/")
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(value)
        for name, path in kit.archive_paths(madeira, bridge).items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"!<arch>\n" + name.encode())
        with mock.patch.object(kit.subprocess, "check_output", return_value=kit.REVISION + "\n"):
            output = self.root / "built.zip"
            kit.build_kit(output, madeira, bridge, False, False, resource_root)
        archive, _ = kit.inspect(output, False, False)
        archive.close()
        kit.install(output, self.root / "reinstalled", False, False)
        self.assertTrue((self.root / "reinstalled/resources/d3d12/canary_ps.dxil").is_file())


if __name__ == "__main__":
    unittest.main()
