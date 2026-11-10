import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from support import ROOT, repo_text


class RuntimeFileUtilitiesTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('xcrun'), 'Requires macOS CryptoKit and Swift')
    def test_compiled_checksums_and_windows_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / 'file-utilities'
            subprocess.run(['xcrun', 'swiftc', str(ROOT / 'iDeck/RuntimeFileUtilities.swift'),
                            str(ROOT / 'tests/host/RuntimeFileUtilitiesTests.swift'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_shared_helpers_are_linked_and_used(self):
        project = repo_text('iDeck.xcodeproj/project.pbxproj')
        self.assertEqual(project.count('/* RuntimeFileUtilities.swift in Sources */'), 2)
        for file in ('PrefixInstaller.swift', 'WineMono.swift', 'WineGeckoRuntime.swift', 'MadeiraRuntime.swift'):
            text = repo_text('iDeck/' + file)
            self.assertIn('FileChecksum.sha256(of:', text)
            self.assertNotIn('var hasher = SHA256()', text)
            self.assertNotIn('var digest = SHA256()', text)
        for file in ('GOGLaunchServices.swift', 'WindowsInstallerEnvironment.swift'):
            self.assertIn('WindowsDrivePath.relative(', repo_text('iDeck/' + file))
