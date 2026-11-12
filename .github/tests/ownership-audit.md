# 4D ownership audit: custom URL callback

## Defect

`listenerLoopExecuteMethod` (`4DPlugin-Protocol.cpp`), which delivers each incoming
URL to the registered 4D method, leaked engine-owned values on every URL:

- Parameters were created with `PA_CreateVariable(eVK_Unistring)`, which allocates an
  empty unistring (`4DPluginAPI.c` `PA_CreateVariable`). `PA_SetStringVariable` is a
  shallow assignment, so that empty owner was overwritten and leaked: one string per
  URL on the method-ID path, two on the `EXECUTE METHOD` (command 1007) fallback.
- The results of `PA_ExecuteMethodByID` / `PA_ExecuteCommandByID` are owned by the
  caller and were discarded, leaking any text or picture returned by the method.

## Fix

Parameters start as `eVK_Undefined` and are set once. The result is captured,
`PA_GetLastError` is read immediately, the parameters are cleared, and the result is
cleared only on `eER_NoErr` (it is unspecified otherwise). This mirrors
address-book 499cb7ee and apple-file-promises ff0c8d86.

## Reachability

`kInitPlugin` → `OnStartup` → `listener_start` (distributed notification
`com.4D.Protocol` on macOS; message-only window on Windows) and `listenerLoopStart`
(`$CUSTOM URL` process). Each URL event → `CUSTOM_URL` queue → `listenerLoop` →
`listenerLoopExecuteMethod`. The macOS and Windows paths share this function.

## Harness

`test_ownership.py` compiles the actual plugin source and the exact bundled SDK
(blob ids pinned) against a synthetic 4D engine (`ownership_host.mm`) with
ASan/UBSan. `ownership_platform.h` replaces LaunchServices, `NSBundle`, `NSUUID` and
the distributed notification center with recording stubs, so no URL scheme handler
is registered and no notification is sent; `nm`/`otool` checks confirm this.

- `Callback`: 144 cases over method / fallback × ASCII, BMP, supplementary, empty
  URLs × allocated / null empty owners × undefined / text / picture results ×
  none / command failure / handle failure.
- `Controls`: registration, empty method, missing URL key, process close paths, and
  the SDK array ownership contracts.
- `ExpectedFailureProbes`: prove the host detects leaks, double frees and borrowed
  value misuse.

Run: `python3 .github/tests/test_ownership.py -v` (set `OWNERSHIP_SOURCE_ROOT` to
test another source tree with the same harness).

Results with the same harness: fixed source 168/168 pass; baseline `d22e526`
(`git archive`) fails exactly 88 named cases (72 `allocated` owner leaks and 16
`null` text/picture result leaks) and passes all controls and probes.

## Deferred (dormant)

- `support/4DPlugin-JSON.cpp` is neither compiled nor included (it is only an
  include path in the vcxproj); its object helpers have similar issues but are
  unreachable and are left unchanged.
- `Classes/*.cpp` are not build members.

## Not validated

Native Windows build and run (registry, window-message callback), a real 4D host,
real LaunchServices, LeakSanitizer (leaks are tracked by the synthetic host), and
the alignment sanitizer (disabled for the packed SDK structs).
