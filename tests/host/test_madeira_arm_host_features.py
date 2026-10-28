import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-arm-host-feature-probe.patch"
FETCH = ROOT / "scripts/fetch_madeira_sources.sh"
NATIVE = "app/Madeira/FEXBridge.mm"
HEADER = "app/Madeira/iDeckARMHostFeatures.h"


def make_fixture(diff, root):
    source = root / NATIVE
    source.parent.mkdir(parents=True, exist_ok=True)
    section = diff.split("diff --git a/" + NATIVE + " b/" + NATIVE, 1)[1]
    section = section.split("\ndiff --git ", 1)[0]
    lines = []
    current = 1
    for match in re.finditer(r"(?m)^@@ -(\d+),(\d+) \+\d+,\d+ @@\n", section):
        start = int(match.group(1))
        lines.extend(["// filler"] * (start - current))
        current = start
        tail = section[match.end():]
        tail = tail.split("\n@@ ", 1)[0]
        for line in tail.splitlines():
            if line.startswith((" ", "-")):
                lines.append(line[1:])
                current += 1
            elif line.startswith("+"):
                continue
            else:
                raise AssertionError("Malformed native source hunk: " + line)
    source.write_text("\n".join(lines) + "\n", encoding="utf-8")


C_TEST = r"""
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "iDeckARMHostFeatures.h"

static const char *present[24];
static size_t present_count;
static int cores = 8;
static int corrupt_length;

static int read_sysctl(const char *key, void *output, size_t *length) {
    if (strcmp(key, "hw.ncpu") == 0) {
        if (*length != sizeof(int)) return -1;
        memcpy(output, &cores, sizeof(cores));
        *length = sizeof(cores);
        return 0;
    }
    for (size_t i = 0; i < present_count; ++i) {
        if (strcmp(key, present[i]) == 0) {
            if (*length != sizeof(int)) return -1;
            int one = 1;
            memcpy(output, &one, sizeof(one));
            *length = corrupt_length ? 1 : sizeof(one);
            return 0;
        }
    }
    return -1;
}
static void add(const char *key) { present[present_count++] = key; }
int main(void) {
    IDeckARMHostProfile empty = ideck_arm_probe(read_sysctl);
    assert(!empty.armv84_user_profile);
    assert(!empty.flagm && !empty.rcpc2 && !empty.lse);
    assert(empty.logical_cores == 8);
    IDeckARMHostProfile missing_reader = ideck_arm_probe(NULL);
    assert(!missing_reader.armv84_user_profile && missing_reader.logical_cores == 1);

    add("hw.optional.arm.FEAT_FlagM");
    add("hw.optional.arm.FEAT_LRCPC");
    add("hw.optional.arm.FEAT_LRCPC2");
    add("hw.optional.arm.FEAT_DotProd");
    add("hw.optional.arm.FEAT_LSE2");
    add("hw.optional.arm.FEAT_DIT");
    add("hw.optional.arm.FEAT_LSE");
    add("hw.optional.arm.FEAT_AES");
    add("hw.optional.arm.FEAT_SHA1");
    add("hw.optional.arm.FEAT_SHA256");
    add("hw.optional.arm.FEAT_PMULL");
    add("hw.optional.arm.FEAT_FP16");
    add("hw.optional.arm.FEAT_FHM");
    add("hw.optional.armv8_crc32");

    IDeckARMHostProfile full = ideck_arm_probe(read_sysctl);
    assert(full.armv84_user_profile && full.flagm && full.dotprod && full.rcpc2);
    assert(full.lse && full.crc && full.aes && full.logical_cores == 8);
    assert(full.sha1 && full.sha256 && full.pmull && full.fhm);
    cores = 1000;
    full = ideck_arm_probe(read_sysctl);
    assert(full.logical_cores == 1);
    cores = 8;
    corrupt_length = 1;
    full = ideck_arm_probe(read_sysctl);
    assert(!full.armv84_user_profile && !full.flagm && !full.lse);
    corrupt_length = 0;

    present_count = 0;
    add("hw.optional.arm.FEAT_LRCPC2");
    add("hw.optional.arm.FEAT_FlagM2");
    full = ideck_arm_probe(read_sysctl);
    assert(!full.rcpc2 && !full.flagm2 && !full.armv84_user_profile);
    puts("PASS: runtime ARM feature detection uses verified host capabilities");
    return 0;
}
"""


class MadeiraARMHostFeatureTests(unittest.TestCase):
    def test_patch_applies_and_c_code_runs(self):
        compiler = shutil.which("clang") or shutil.which("cc")
        if compiler is None or shutil.which("git") is None:
            self.skipTest("C compiler and git are required")
        diff = PATCH.read_text(encoding="utf-8")
        self.assertEqual(diff.count("diff --git "), 2)
        self.assertIn("iDeckARMHostFeatures.h", diff)
        self.assertIn("Features.SupportsAtomics = Host.lse", diff)
        self.assertIn("Features.SupportsTSOImm9 = Host.rcpc2", diff)
        self.assertIn("Features.CPUMIDRs.resize(Host.logical_cores, 0)", diff)
        self.assertIn("Features.SupportsFlagM = Host.flagm", diff)
        self.assertIn("Features.SupportsFlagM2 = Host.flagm2", diff)
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            make_fixture(diff, root)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "apply", "--check", str(PATCH)], check=True)
            subprocess.run(["git", "-C", str(root), "apply", str(PATCH)], check=True)
            subprocess.run(["git", "-C", str(root), "apply", "--reverse",
                            "--check", str(PATCH)], check=True)
            native = (root / NATIVE).read_text(encoding="utf-8")
            self.assertNotIn("Features.CPUMIDRs.resize(8, 0x611F0250)", native)
            self.assertIn("#include \"iDeckARMHostFeatures.h\"", native)
            self.assertIn("ideck_arm_probe_system()", native)
            c_file = root / "host_arm_features_test.c"
            c_file.write_text(C_TEST, encoding="utf-8")
            executable = root / "feature-check"
            subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-I", str(root / "app/Madeira"),
                            str(c_file), "-o", str(executable)],
                           capture_output=True, text=True, check=True)
            subprocess.run([str(executable)], capture_output=True, text=True, check=True)

    def test_native_checkout_patches_pinned_source(self):
        fetch = FETCH.read_text(encoding="utf-8")
        self.assertIn('apply --reverse --check "$ARM_HOST_PATCH"', fetch)
        self.assertIn('apply --check "$ARM_HOST_PATCH"', fetch)
        self.assertIn('apply "$ARM_HOST_PATCH"', fetch)
        self.assertIn('iDeckARMHostFeatures.h', fetch)
        self.assertIn('grep -Fq', fetch)

if __name__ == "__main__":
    unittest.main()
