#!/usr/bin/env python3
"""Native ownership harness for the Protocol (custom URL scheme) plugin.

Standard library only. Builds the unchanged bundled 4D plugin SDK and the real
4DPlugin-Protocol.cpp with ASan/UBSan against a synthetic engine host
(ownership_host.mm). LaunchServices, the distributed notification center,
NSBundle and NSUUID are replaced by recording or deny-by-default stubs: no URL
scheme handler is registered or modified and no Apple Event or distributed
notification is sent. Each case runs in its own process.

OWNERSHIP_SOURCE_ROOT selects the plugin/SDK tree to compile (default: this
checkout), so the same harness can be run against a `git archive` baseline.
"""
import concurrent.futures
import hashlib
import itertools
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = pathlib.Path(os.environ.get("OWNERSHIP_SOURCE_ROOT", ROOT)).resolve()
API = SOURCE / "4D Plugin API"

# Exact git blob ids of the complete bundled SDK; never edited by the plugin.
SDK_BLOBS = {
    "4D Plugin API/4DPluginAPI.c": "62f745e91d81ef2c3c901c656ea8e175d3b173e8",
    "4D Plugin API/4DPluginAPI.h": "528bf1d2552df08d6a8b1bc95011a9b72934ad5c",
    "4D Plugin API/4DPluginAPI.def": "5bbdb82fb724b6f8e307feb01d9f158b802de89d",
    "4D Plugin API/EntryPoints.h": "da428d5f6ca23b0a30371c7288a01d29aa3c466a",
    "4D Plugin API/Flags.h": "7a5a35539f27430a3fd9cb711d6b789051316471",
    "4D Plugin API/PrivateTypes.h": "a3098cb662cdbc43ba574fdef72a059c4c6d1cd4",
    "4D Plugin API/PublicTypes.h": "9ae20b001bff9128f690fff3e6c3f873b6238333",
}

# Platform functions that must never be imported by the compiled plugin object or host.
FORBIDDEN_IMPORTS = [
    "_LSRegisterURL",
    "_LSSetDefaultHandlerForURLScheme",
    "_LSCopyDefaultHandlerForURLScheme",
    "_CFNotificationCenterGetDistributedCenter",
    "_CFNotificationCenterAddObserver",
    "_CFNotificationCenterRemoveObserver",
    "_CFNotificationCenterPostNotification",
    "_AESend",
    "_AESendMessage",
]

# Classes the plugin object must reach only through harness subclasses
# (the host itself references them as superclasses of its stubs).
FORBIDDEN_PLUGIN_CLASSES = [
    "_OBJC_CLASS_$_NSBundle",
    "_OBJC_CLASS_$_NSUUID",
    "_OBJC_CLASS_$_NSWorkspace",
    "_OBJC_CLASS_$_NSTask",
    "_OBJC_CLASS_$_NSDistributedNotificationCenter",
]

PATHS = ["method", "fallback"]
TEXTS = ["ascii", "bmp", "supplementary", "empty"]
EMPTIES = ["allocated", "null"]
RESULTS = ["undefined", "text", "picture"]
FAILURES = ["none", "command", "handle"]

OTHER_CASES = [
    "platform:isolation",
    "control:register",
    "control:empty-method",
    "control:no-url-key",
    "control:close-exit-process",
    "control:close-other-process",
    "array:accept-index0",
    "array:accept-last",
    "array:reject-negative",
    "array:reject-past-end",
    "array:reject-null-ustr",
    "array:reject-wrong-kind",
    "array:reject-null-data",
]

# name -> (expected return code, expected stderr/stdout marker)
PROBES = {
    "probe:shallow-overwrite-leak": (1, "leaked strings=1"),
    "probe:discarded-result-leak": (1, "leaked strings=1"),
    "probe:alias-double-clear": (-signal.SIGABRT, "VIOLATION invalid-dispose string"),
    "probe:array-transfer-then-dispose": (-signal.SIGABRT, "VIOLATION invalid-dispose string"),
    "probe:clear-failed-result": (-signal.SIGABRT, "VIOLATION invalid-dispose string"),
    "probe:denied-lsregister": (-signal.SIGABRT, "DENY LSRegisterURL"),
    "probe:denied-uuid": (-signal.SIGABRT, "DENY NSUUID"),
}

ENV = dict(
    os.environ,
    ASAN_OPTIONS="detect_leaks=0:halt_on_error=1:abort_on_error=0",
    UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1",
)


def blob_id(path):
    data = path.read_bytes()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


class Build:
    directory = None
    binary = None
    plugin_object = None
    error = None

    @classmethod
    def ensure(cls):
        if cls.binary or cls.error:
            return
        try:
            cls._build()
        except Exception as exc:  # reported by every dependent test
            cls.error = str(exc)

    @classmethod
    def _build(cls):
        if sys.platform != "darwin":
            raise RuntimeError("macOS toolchain required")
        cls.directory = pathlib.Path(tempfile.mkdtemp(prefix="protocol-ownership-"))
        flags = [
            "clang++", "-std=c++14", "-x", "objective-c++",
            "-include", str(HERE / "ownership_platform.h"),
            "-I", str(API), "-I", str(SOURCE),
            "-fsanitize=address,undefined", "-fno-sanitize=alignment",
            "-fno-sanitize-recover=undefined", "-g", "-O0", "-w", "-c",
        ]
        units = [
            (API / "4DPluginAPI.c", []),
            (SOURCE / "4DPlugin-Protocol.cpp", []),
            (HERE / "ownership_host.mm", ["-DOWNERSHIP_HOST=1"]),
        ]
        jobs = []
        for index, (src, extra) in enumerate(units):
            obj = cls.directory / f"{index:02d}-{src.stem}.o"
            jobs.append((flags + extra + [str(src), "-o", str(obj)], src, obj))
        with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 2) as pool:
            results = list(pool.map(lambda job: (job, run(job[0])), jobs))
        for (cmd, src, obj), res in results:
            if res.returncode != 0:
                raise RuntimeError(f"compile failed: {src}\n{res.stderr[-4000:]}")
            if src.name == "4DPlugin-Protocol.cpp":
                cls.plugin_object = obj
        binary = cls.directory / "ownership_host"
        res = run(["clang++", "-fsanitize=address,undefined"] + [str(o) for _, _, o in jobs]
                  + ["-framework", "Foundation", "-framework", "CoreGraphics", "-o", str(binary)])
        if res.returncode != 0:
            raise RuntimeError(f"link failed\n{res.stderr[-4000:]}")
        cls.binary = binary

    @classmethod
    def case(cls, name):
        cls.ensure()
        if cls.error:
            raise AssertionError(cls.error)
        return run([str(cls.binary), name], env=ENV, timeout=120)


def tearDownModule():
    if Build.directory and not os.environ.get("OWNERSHIP_KEEP_BUILD"):
        shutil.rmtree(Build.directory, ignore_errors=True)


class Identity(unittest.TestCase):
    def test_bundled_sdk_is_exact_and_unchanged(self):
        for rel, expected in SDK_BLOBS.items():
            with self.subTest(file=rel):
                self.assertEqual(blob_id(SOURCE / rel), expected)

    def test_build_members_are_the_compiled_units(self):
        pbx = (SOURCE / "Protocol.xcodeproj" / "project.pbxproj").read_text()
        built = sorted(set(re.findall(r"/\* (\S+) in Sources \*/", pbx)))
        self.assertEqual(built, ["4DPlugin-Protocol.cpp", "4DPluginAPI.c"])
        vcx = (SOURCE / "Protocol.vcxproj").read_text()
        compiled = sorted(re.findall(r'<ClCompile Include="([^"]+)"', vcx))
        self.assertEqual(compiled, ["4D Plugin API\\4DPluginAPI.c", "4DPlugin-Protocol.cpp"])

    def test_no_platform_escape_imports(self):
        Build.ensure()
        self.assertIsNone(Build.error, Build.error)
        for target in (Build.plugin_object, Build.binary):
            undefined = run(["nm", "-u", str(target)]).stdout.split()
            for symbol in FORBIDDEN_IMPORTS:
                with self.subTest(target=target.name, symbol=symbol):
                    self.assertNotIn(symbol, undefined)
        undefined = run(["nm", "-u", str(Build.plugin_object)]).stdout.split()
        for symbol in FORBIDDEN_PLUGIN_CLASSES:
            with self.subTest(target="plugin", symbol=symbol):
                self.assertNotIn(symbol, undefined)
        self.assertIn("_OBJC_CLASS_$_OwnershipBundle", undefined)
        self.assertIn("_PA_ExecuteMethodByID", undefined)
        self.assertIn("_PA_ExecuteCommandByID", undefined)

    def test_launch_services_frameworks_are_not_linked(self):
        Build.ensure()
        self.assertIsNone(Build.error, Build.error)
        linked = run(["otool", "-L", str(Build.binary)]).stdout
        self.assertNotIn("CoreServices.framework", linked)
        self.assertNotIn("AppKit.framework", linked)


def _method_name(case):
    return "test_" + re.sub(r"[^0-9A-Za-z]+", "_", case)


def _passing(case):
    def test(self):
        res = Build.case(case)
        self.assertEqual(res.returncode, 0, f"{case}\n{res.stdout}{res.stderr[-3000:]}")
        self.assertIn(f"PASS {case}", res.stdout)
    return test


def _probe(case, code, marker):
    def test(self):
        res = Build.case(case)
        self.assertEqual(res.returncode, code, f"{case}\n{res.stdout}{res.stderr[-3000:]}")
        self.assertIn(marker, res.stdout + res.stderr)
    return test


class Callback(unittest.TestCase):
    """REGISTER PROTOCOL -> URL event -> listener -> listenerLoopExecuteMethod, two queued URLs."""


for combo in itertools.product(PATHS, TEXTS, EMPTIES, RESULTS, FAILURES):
    name = "callback:" + ":".join(combo)
    setattr(Callback, _method_name(name), _passing(name))


class Controls(unittest.TestCase):
    """Command dispatch, listener lifecycle, SDK array transfer/rejection and isolation controls."""


for name in OTHER_CASES:
    setattr(Controls, _method_name(name), _passing(name))


class ExpectedFailureProbes(unittest.TestCase):
    """Isolated processes that must fail in exactly the named way."""


for name, (code, marker) in PROBES.items():
    setattr(ExpectedFailureProbes, _method_name(name), _probe(name, code, marker))


if __name__ == "__main__":
    unittest.main()
