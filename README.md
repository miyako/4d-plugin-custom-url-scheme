![version](https://img.shields.io/badge/version-19%2B-5682DF)
![platform](https://img.shields.io/static/v1?label=platform&message=mac-intel%20|%20mac-arm%20|%20win-64&color=blue)
[![license](https://img.shields.io/github/license/miyako/4d-plugin-custom-url-scheme)](LICENSE)
![downloads](https://img.shields.io/github/downloads/miyako/4d-plugin-custom-url-scheme/total)

# 4d-plugin-custom-url-scheme

Registers a custom URL scheme (e.g. `fourd://...`) for your 4D application with the operating system, and routes every URL the OS subsequently hands to your app to a 4D method of your choosing. On macOS this is driven by Launch Services (`LSSetDefaultHandlerForURLScheme`) and a distributed `CFNotificationCenter` notification; on Windows it's driven by the classic `HKEY_CURRENT_USER\SOFTWARE\Classes\<scheme>` registry association plus a hidden message-only window. A background 4D process (visible as `$CUSTOM URL` in the process list) receives the incoming URLs and calls your method with the raw URL string, one call per URL.

| Command | Returns | Purpose |
|---|---|---|
| [REGISTER PROTOCOL](#register-protocol) | (none) | Associates a custom URL scheme with this app and sets the 4D method to call for each incoming URL. |

**Platforms:** mac-intel \| mac-arm \| win-64

---

## Requirements & platform notes

- **This command has no return value and reports no 4D error on failure.** Both the macOS and Windows registration paths fail silently from 4D's point of view (macOS logs to the system console via `NSLog`; Windows just skips the registry writes). Verify registration worked by actually opening a URL with your scheme (from a browser, `Terminal`/`cmd`, or a second app) rather than checking for an error in 4D.
- **Silently does nothing under Windows Session 0.** If the 4D process is running as a non-interactive Windows service (typical for some 4D Server deployments), `REGISTER PROTOCOL` is skipped entirely — there is no desktop session to register a shell handler against.
- **Only one callback method is tracked at a time, globally — not per scheme.** `REGISTER PROTOCOL` stores a single method name internally. If you register scheme `A` with method `M1` and later register scheme `B` with method `M2`, `M1` is replaced; from then on **both** `A`- and `B`-triggered URLs are delivered to `M2`. The URL string itself still tells you which scheme it came from (it's the whole `scheme://...` string), but you can't route different schemes to different methods simultaneously with this plugin.
- **An empty `$method` still registers the scheme with the OS, but silently drops incoming URLs.** No method is called and no error is raised — this is a valid way to "arm" a scheme without wiring a callback yet, but it's easy to mistake for a bug if you forget you passed an empty string.
- **macOS** requires a companion `url-redirect.app` helper to be present alongside the plugin (looked up via bundle identifier `com.4D.Protocol`); **Windows** requires a companion `url-redirect.exe` in the same folder as the plugin binary, located by the plugin's own module name (`Protocol.4DX`). If the plugin file has been renamed on Windows, registration silently no-ops.
- Works in both 4D and 4D Server, subject to the Session 0 restriction above.

---

## REGISTER PROTOCOL

### Syntax

```4d
REGISTER PROTOCOL(scheme; method)
```

| Parameter | Type | Description |
|---|---|---|
| `scheme` | Text | The URL scheme to register, without `://` (e.g. `"fourd"` registers `fourd://...`). Passed as-is to the OS; the plugin does not validate its syntax. |
| `method` | Text | Name of the 4D method to call for each incoming URL. Pass an empty string to register the scheme with the OS while suspending delivery (see Requirements above). |
| Result | — | No return value. |

### Description

Calling `REGISTER PROTOCOL` does two things: it (re)registers `scheme` with the operating system as belonging to this application, and it updates the single global callback method used for every scheme registered by this plugin instance in the current app.

Once registered, whenever the OS launches or activates your app because the user opened a `scheme://...` URL, the plugin's background `$CUSTOM URL` process receives it and calls `method` with the complete URL as its only parameter:

```4d
#DECLARE($URL : Text)
```

Your method is responsible for parsing the URL (scheme, host, path, query string) — the plugin passes it through unmodified.

**On macOS**, registration uses `LSSetDefaultHandlerForURLScheme` and delivers URLs via a distributed notification (`com.4D.Protocol`); this requires the companion `url-redirect.app` to exist alongside the plugin bundle.

**On Windows**, registration writes `HKEY_CURRENT_USER\SOFTWARE\Classes\<scheme>\shell\open\command` to point at a companion `url-redirect.exe`, and also clears `WarnOnOpen` under `...\Internet Explorer\ProtocolExecute\<scheme>` so the OS doesn't prompt the user to confirm opening the app every time. URLs are delivered to the plugin via a registered window message plus a named shared-memory block; this only works in an interactive desktop session (see Requirements).

### Example

From the plugin's own test method (`TEST.4dm`):

```4d
//%attributes = {}
$scheme:="fourd"

$method:="MYCALLBACK"

REGISTER PROTOCOL($scheme; $method)

var $file : 4D:C1709.File

$file:=Folder:C1567(fk resources folder:K87:11).file("template.html")

var $HTML : Text

$HTML:=$file.getText()

PROCESS 4D TAGS:C816($HTML; $HTML; $scheme)

$file:=Folder:C1567(fk resources folder:K87:11).file("example.html")

$file.setText($HTML)

OPEN URL:C673($file.platformPath)
```

This registers the `fourd` scheme with callback method `MYCALLBACK`, then generates an HTML page (via `PROCESS 4D TAGS`, substituting `$scheme` into any `4DTAG_...` placeholders in `template.html`) and opens it — a typical pattern for building a local HTML page containing a `fourd://...` link that, when clicked, round-trips back into your 4D app.

The callback method itself, from the plugin's own sample (`MYCALLBACK.4dm`):

```4d
//%attributes = {}
#DECLARE($URL : Text)

ALERT:C41($URL)
```

A second, generic pattern — dispatching on the URL's path rather than just alerting it:

```4d
#DECLARE($URL : Text)

var $scheme; $action : Text

$scheme:=Substring($URL; 1; Position("://"; $URL)-1)
$action:=Substring($URL; Position("://"; $URL)+3)

Case of
	: ($action="open")
		// handle fourd://open
	: ($action="sync")
		// handle fourd://sync
	Else
		ALERT:C41("Unrecognized action: "+$action)
End case
```

Re-registering later with a new scheme/method (e.g. at app startup, to point at a different method after a version change):

```4d
REGISTER PROTOCOL("fourd"; "MYCALLBACK_V2")
```

---

## Error handling & troubleshooting

- **No 4D-visible error on registration failure.** The command never raises a 4D error and has no return value — treat it as fire-and-forget, and confirm registration by actually triggering the scheme from outside your app (browser address bar, `start fourd://test` on Windows, `open fourd://test` on macOS).
- **Nothing happens under a Windows service / Session 0.** If your 4D Server runs as a non-interactive Windows service, `REGISTER PROTOCOL` silently does nothing — there's no desktop to hang a shell association off of. Run the app interactively at least once to register the scheme, or handle registration from a client instead.
- **Windows: renamed plugin file breaks registration.** The plugin locates its own folder (to find the companion `url-redirect.exe`) by looking up the currently loaded module named exactly `Protocol.4DX`. If the shipped `.4dx` file has been renamed, this lookup fails and registration is skipped — with no error surfaced to 4D.
- **Empty `$method` = registered but silent.** Passing `""` for `method` still tells the OS about the scheme, but every incoming URL is discarded with no callback and no error. If URLs seem to vanish, check you actually passed a non-empty method name.
- **Only the most recently registered method is active, for every scheme.** See "Requirements & platform notes" above — if you need scheme-specific routing, dispatch on the URL's scheme/path yourself inside a single callback method rather than expecting the plugin to route by scheme.
- **Windows: the OS may take a moment to notice a fresh registration.** The plugin broadcasts `WM_SETTINGCHANGE` after writing the registry so the shell picks up the change without a logoff, but some already-running processes (e.g. an open browser) may need to be restarted to recognize the scheme immediately after your app registers it for the first time.

---

## Quick reference

```4d
// Register once, e.g. at application startup:
REGISTER PROTOCOL("fourd"; "MYCALLBACK")

// Callback method (MYCALLBACK):
#DECLARE($URL : Text)
ALERT:C41($URL)

// Disarm delivery without unregistering the scheme with the OS:
REGISTER PROTOCOL("fourd"; "")

// Re-arm / point at a different method later:
REGISTER PROTOCOL("fourd"; "MYCALLBACK_V2")
```
