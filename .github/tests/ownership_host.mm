/*
 * Synthetic 4D engine host for the Protocol (custom URL scheme) ownership harness.
 *
 * Links the unchanged bundled 4D plugin SDK and the real 4DPlugin-Protocol.cpp.
 * LaunchServices, the distributed notification center, NSBundle and NSUUID are
 * replaced by recording or deny-by-default stubs (see ownership_platform.h):
 * no URL scheme handler is registered or modified and no Apple Event or
 * distributed notification is sent or observed. URL events are delivered by
 * calling the plugin's own registered callback synthetically. Every engine
 * owner (unistring, picture, handle) is tracked so leaks and invalid/double
 * disposal are reported by name.
 *
 * Usage: ownership_host <case>   (one case per isolated process)
 */
#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"

#include <objc/runtime.h>
#include <mach-o/dyld.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

typedef std::basic_string<PA_Unichar> U16;

namespace customurl {
extern std::vector<U16> CUSTOM_URL;
extern U16 LISTENER_METHOD;
extern PA_long32 METHOD_PROCESS_ID;
extern bool PROCESS_SHOULD_TERMINATE;
extern bool PROCESS_SHOULD_RESUME;
}

static void deny(const char *what)
{
    fprintf(stderr, "DENY %s\n", what);
    fflush(stderr);
    abort();
}

// ---------------------------------------------------------------- engine state

struct Host {
    bool nullEmpty = false;          // engine represents "" as fString == NULL
    PA_long32 methodId = 123;        // 0 selects the EXECUTE METHOD (1007) fallback
    int resultKind = 0;              // 0 undefined, 1 text, 2 picture
    std::string failure = "none";    // none | command | handle
    size_t armHandleSize = 0;        // fail the next handle allocation of this size
    U16 processName;
    int aliveIterations = 1;
    int dyingCalls = 0;
    bool closeOnYield = false;       // deliver kCloseProcess from "$xx" inside the listener loop

    std::map<PA_Unichar *, U16> strings;
    std::set<void *> pictures;
    std::map<PA_Handle, size_t> handles;

    std::vector<U16> calls;          // URL received by the listener method
    std::vector<U16> fallbackNames;  // method name passed to EXECUTE METHOD
    std::vector<U16> methodLookups;
    int newProcess = 0, runInMain = 0, kills = 0, sleeps = 0, yields = 0;
    void *newProcessProc = nullptr;
    U16 newProcessName;

    int centerLookups = 0, observersAdded = 0, observersRemoved = 0;
    CFNotificationCallback callback = nullptr;
    int bundleLookups = 0;
    std::vector<std::string> schemes; // LSSetDefaultHandlerForURLScheme (stubbed)
    std::vector<std::string> handlers;
    std::vector<std::string> failures;
};
static Host g;
static int centerToken;

static void fail(const std::string &msg)
{
    g.failures.push_back(msg);
}

static U16 u16(const char16_t *s)
{
    U16 out;
    for (; *s; ++s) out.push_back((PA_Unichar)*s);
    return out;
}

static std::string utf8(const U16 &s)
{
    NSString *n = [[NSString alloc] initWithCharacters:(const unichar *)s.data() length:s.size()];
    std::string out = [n UTF8String] ? [n UTF8String] : "";
    [n release];
    return out;
}

static std::string utf8(CFStringRef s)
{
    return s ? std::string([(NSString *)s UTF8String]) : std::string("(null)");
}

static PA_Unistring makeString(const PA_Unichar *src)
{
    PA_Unistring u;
    memset(&u, 0, sizeof(u));
    size_t n = 0;
    if (src) while (src[n]) ++n;
    if (n == 0 && g.nullEmpty) return u;
    PA_Unichar *buf = (PA_Unichar *)calloc(n + 1, sizeof(PA_Unichar));
    if (n) memcpy(buf, src, n * sizeof(PA_Unichar));
    g.strings[buf] = U16(buf, n);
    u.fString = buf;
    u.fLength = (PA_long32)n;
    return u;
}

static void disposeString(PA_Unichar *p, const char *where)
{
    if (!p) return;
    auto it = g.strings.find(p);
    if (it == g.strings.end()) {
        fprintf(stderr, "VIOLATION invalid-dispose string %p in %s\n", (void *)p, where);
        fflush(stderr);
        abort();
    }
    g.strings.erase(it);
    free(p);
}

static U16 textOf(const PA_Variable &v, const char *where)
{
    if (v.fType != eVK_Unistring) {
        fail(std::string("argument kind not text in ") + where);
        return U16();
    }
    PA_Unichar *p = v.uValue.fString.fString;
    if (!p) {
        if (v.uValue.fString.fLength != 0) fail(std::string("null text with length in ") + where);
        return U16();
    }
    auto it = g.strings.find(p);
    if (it == g.strings.end()) {
        fprintf(stderr, "VIOLATION argument references non-live string in %s\n", where);
        fflush(stderr);
        abort();
    }
    if ((size_t)v.uValue.fString.fLength != it->second.size()) fail(std::string("length mismatch in ") + where);
    return it->second;
}

static void *makePicture()
{
    void *p = malloc(16);
    g.pictures.insert(p);
    return p;
}

static void clearVariable(PA_Variable *v)
{
    switch ((unsigned char)v->fType) {
        case eVK_Unistring:
            disposeString(v->uValue.fString.fString, "EX_CLEAR_VARIABLE");
            break;
        case eVK_Picture:
            if (v->uValue.fPicture) {
                if (!g.pictures.erase(v->uValue.fPicture)) {
                    fprintf(stderr, "VIOLATION invalid-dispose picture in EX_CLEAR_VARIABLE\n");
                    fflush(stderr);
                    abort();
                }
                free(v->uValue.fPicture);
            }
            break;
        case eVK_ArrayUnicode: {
            PA_Handle h = v->uValue.fArray.fData;
            if (h) {
                PA_Unistring *e = (PA_Unistring *)*h;
                for (PA_long32 i = 0; i <= v->uValue.fArray.fNbElements; ++i)
                    disposeString(e[i].fString, "EX_CLEAR_VARIABLE array element");
                if (!g.handles.erase(h)) {
                    fprintf(stderr, "VIOLATION invalid-dispose array handle\n");
                    fflush(stderr);
                    abort();
                }
                free(*h);
                delete h;
            }
            break;
        }
        case eVK_Undefined:
        case eVK_Longint:
        case eVK_Real:
            break;
        default:
            fprintf(stderr, "VIOLATION clear of unspecified variable kind %d\n", (int)(unsigned char)v->fType);
            fflush(stderr);
            abort();
    }
    v->fType = eVK_Undefined;
}

static void setResult(PA_Variable *r)
{
    if (g.failure == "command") {
        // engine reported an error: the result slot is unspecified (poisoned)
        r->fType = eVK_Unistring;
        r->uValue.fString.fString = (PA_Unichar *)(uintptr_t)0xa5a5a5a5a5a0ULL;
        r->uValue.fString.fLength = 7;
        return;
    }
    if (g.resultKind == 1) {
        r->fType = eVK_Unistring;
        r->fFiller = 0;
        r->uValue.fString = makeString((const PA_Unichar *)u"method result");
    } else if (g.resultKind == 2) {
        r->fType = eVK_Picture;
        r->fFiller = 0;
        r->uValue.fPicture = makePicture();
    }
}

static void handleManager(EngineBlock *eb)
{
    PA_Handle h = eb->fHandle;
    switch (eb->fParam1) {
        case 1: {
            size_t len = (size_t)eb->fParam2;
            if (g.armHandleSize && len == g.armHandleSize) {
                eb->fHandle = 0;
                eb->fError = -108;
                return;
            }
            PA_Handle nh = new char *;
            *nh = (char *)calloc(len ? len : 1, 1);
            g.handles[nh] = len;
            eb->fHandle = nh;
            return;
        }
        case 2:
            if (!g.handles.erase(h)) {
                fprintf(stderr, "VIOLATION invalid-dispose handle\n");
                fflush(stderr);
                abort();
            }
            free(*h);
            delete h;
            return;
        case 3: {
            auto it = g.handles.find(h);
            if (it == g.handles.end()) deny("resize of unknown handle");
            size_t len = (size_t)eb->fParam2;
            char *p = (char *)realloc(*h, len ? len : 1);
            if (len > it->second) memset(p + it->second, 0, len - it->second);
            *h = p;
            it->second = len;
            return;
        }
        case 4: {
            auto it = g.handles.find(h);
            if (it == g.handles.end()) deny("size of unknown handle");
            eb->fParam2 = (sLONG_PTR)it->second;
            return;
        }
        case 5:
            if (!g.handles.count(h)) deny("lock of unknown handle");
            eb->fParam3 = (sLONG_PTR)*h;
            return;
        case 6:
        case 8:
            return;
        case 7:
            eb->fParam2 = 0;
            return;
        default:
            deny("handle manager subselector");
    }
}

static void closeFromExitProcess();

static void engine(short sel, EngineBlock *eb)
{
    switch (sel) {
        case EX_CREATE_UNISTRING:
            eb->fUniString1 = makeString((const PA_Unichar *)eb->fHandle);
            return;
        case EX_DISPOSE_UNISTRING:
            disposeString(eb->fUniString1.fString, "EX_DISPOSE_UNISTRING");
            return;
        case EX_CLEAR_VARIABLE:
            clearVariable((PA_Variable *)eb->fPtr1);
            return;
        case EX_HANDLE_MANAGER:
            handleManager(eb);
            return;
        case EX_GET_METHOD_ID:
            g.methodLookups.push_back(U16(eb->fUName));
            eb->fParam1 = g.methodId;
            eb->fError = 0;
            return;
        case EX_CALL_BY_PROCID: {
            PA_Variable *v = (PA_Variable *)*eb->fHandle;
            if (eb->fParam1 != 123) fail("EX_CALL_BY_PROCID id");
            if (eb->fParam2 > 1) fail("EX_CALL_BY_PROCID parameter count");
            if (v[0].fType != eVK_Undefined) fail("result slot not undefined on entry");
            if (eb->fParam2 == 1) g.calls.push_back(textOf(v[1], "method argument"));
            setResult(&v[0]);
            eb->fError = (g.failure == "command") ? 17 : 0;
            return;
        }
        case EX_EXECUTE_COMMAND_BY_ID: {
            if (eb->fParam1 != 1007 || eb->fParam2 != 2) fail("EX_EXECUTE_COMMAND_BY_ID id/count");
            PA_Variable **pv = (PA_Variable **)eb->fPtr1;
            g.fallbackNames.push_back(textOf(*pv[0], "EXECUTE METHOD name"));
            g.calls.push_back(textOf(*pv[1], "EXECUTE METHOD argument"));
            setResult((PA_Variable *)eb->fPtr2);
            eb->fError = (g.failure == "command") ? 17 : 0;
            return;
        }
        case EX_GET_PROCESS_INFO:
            memset(eb->fUString, 0, sizeof(eb->fUString));
            memcpy(eb->fUString, g.processName.data(), g.processName.size() * sizeof(PA_Unichar));
            eb->fParam2 = 0;
            eb->fParam3 = 0;
            eb->fError = 0;
            return;
        case EX_CURRENT_PROCESS_NUMBER:
            eb->fParam1 = 7;
            return;
        case EX_IS_PROCESS_DYING:
            eb->fManyToOne = (++g.dyingCalls > g.aliveIterations) ? 1 : 0;
            return;
        case EX_YIELD_ABSOLUTE:
            g.yields++;
            if (g.closeOnYield) {
                g.closeOnYield = false;
                closeFromExitProcess();
            }
            return;
        case EX_PUT_PROCESS_TO_SLEEP:
            g.sleeps++;
            eb->fError = 0;
            return;
        case EX_NEW_PROCESS:
            g.newProcess++;
            g.newProcessProc = (void *)eb->fHandle;
            g.newProcessName = U16(eb->fUString);
            eb->fParam1 = 7;
            eb->fError = 0;
            return;
        case EX_RUN_IN_MAIN_PROCESS:
            g.runInMain++;
            ((void (*)(void *))eb->fPtr1)(eb->fPtr2);
            return;
        case EX_KILL_PROCESS:
            g.kills++;
            return;
        default: {
            char msg[64];
            snprintf(msg, sizeof(msg), "unexpected engine selector %d", (int)sel);
            deny(msg);
        }
    }
}

static pascal void engineEntry(short sel, EngineBlock *eb)
{
    engine(sel, eb);
}

// ------------------------------------------------- platform stubs

extern "C" OSStatus OwnershipLSRegisterURL(CFURLRef, Boolean)
{
    deny("LSRegisterURL");
    return -1;
}

extern "C" OSStatus OwnershipLSSetDefaultHandlerForURLScheme(CFStringRef scheme, CFStringRef bundleId)
{
    // recorded only; the real LaunchServices database is never touched
    g.schemes.push_back(utf8(scheme));
    g.handlers.push_back(utf8(bundleId));
    return 0;
}

extern "C" CFNotificationCenterRef OwnershipGetDistributedCenter(void)
{
    g.centerLookups++;
    return (CFNotificationCenterRef)&centerToken;
}

extern "C" void OwnershipAddObserver(CFNotificationCenterRef center, const void *,
                                     CFNotificationCallback callback, CFStringRef name,
                                     const void *object, CFNotificationSuspensionBehavior)
{
    g.observersAdded++;
    if (center != (CFNotificationCenterRef)&centerToken) fail("observer on unexpected center");
    if (utf8(name) != "com.4D.Protocol") fail("observer for unexpected notification");
    if (object) fail("observer for unexpected object");
    g.callback = callback;
}

extern "C" void OwnershipRemoveObserver(CFNotificationCenterRef center, const void *, CFStringRef name, const void *)
{
    g.observersRemoved++;
    if (center != (CFNotificationCenterRef)&centerToken) fail("remove on unexpected center");
    if (utf8(name) != "com.4D.Protocol") fail("remove for unexpected notification");
    g.callback = nullptr;
}

@implementation OwnershipBundle
+ (void)initialize {}
+ (NSBundle *)bundleWithIdentifier:(NSString *)identifier
{
    g.bundleLookups++;
    if (![identifier isEqualToString:@"com.4D.Protocol"]) fail("unexpected bundle identifier");
    return nil; // not hosted in a plugin bundle: LSRegisterURL must not be reached
}
+ (void)doesNotRecognizeSelector:(SEL)sel { deny([[NSString stringWithFormat:@"+[NSBundle %@]", NSStringFromSelector(sel)] UTF8String]); }
@end

@implementation OwnershipDeniedUUID
+ (void)initialize { deny("NSUUID"); }
@end

// ------------------------------------------------------------- utilities

static void *packTwo(PA_Unistring *a, PA_Unistring *b)
{
    static void *slots[4];
    slots[0] = a;
    slots[1] = b;
    return (void *)slots;
}

static void dispatch(PA_long32 selector, void *params)
{
    sLONG_PTR result = 0;
    void *data = nullptr;
    FourDPackex(selector, params, &data, &result);
}

static void initPlugin()
{
    PackInitBlock init;
    memset(&init, 0, sizeof(init));
    init.fCall4Dex = (Call4DProcPtr)engineEntry;
    dispatch(kInitPlugin, &init);
    if (gCall4D != (Call4DProcPtr)engineEntry) fail("FourDPackex did not install engine callback");
    if (g.runInMain != 1 || g.centerLookups != 1 || g.observersAdded != 1 || !g.callback)
        fail("listener_start did not register the URL observer once");
    if (g.newProcess != 1 || !g.newProcessProc || customurl::METHOD_PROCESS_ID != 7)
        fail("listener process not started");
    if (g.newProcessName != u16(u"$CUSTOM URL")) fail("listener process name");
}

static void closeFromExitProcess()
{
    U16 saved = g.processName;
    g.processName = u16(u"$xx");
    dispatch(kCloseProcess, NULL);
    g.processName = saved;
}

static PA_Unistring schemeParam, methodParam;

static void registerProtocol(const U16 &scheme, const U16 &method)
{
    schemeParam = makeString(scheme.c_str());
    methodParam = makeString(method.c_str());
    dispatch(1, packTwo(&schemeParam, &methodParam));
}

static void releaseParams()
{
    disposeString(schemeParam.fString, "harness scheme");
    disposeString(methodParam.fString, "harness method");
}

static NSString *ns(const U16 &u)
{
    return [NSString stringWithCharacters:(const unichar *)u.data() length:u.size()];
}

static void deliver(NSDictionary *userInfo)
{
    if (!g.callback) deny("no registered URL callback");
    g.callback((CFNotificationCenterRef)&centerToken, NULL, CFSTR("com.4D.Protocol"), NULL, (CFDictionaryRef)userInfo);
}

static void runListener()
{
    ((void (*)(void))g.newProcessProc)();
}

static void expectTeardown()
{
    if (g.kills != 1) fail("listener process not killed once");
    if (g.runInMain != 2 || g.observersRemoved != 1 || g.callback) fail("listener_end did not remove the observer");
    if (customurl::METHOD_PROCESS_ID != 0) fail("METHOD_PROCESS_ID not reset");
    if (!customurl::CUSTOM_URL.empty()) fail("URL queue not drained");
    if (!customurl::LISTENER_METHOD.empty()) fail("LISTENER_METHOD not reset");
}

static int finish(const std::string &name, bool expectBalanced = true)
{
    if (expectBalanced) {
        if (!g.strings.empty()) {
            std::string sample;
            for (auto &kv : g.strings) { sample += " \"" + utf8(kv.second) + "\""; if (sample.size() > 120) break; }
            fail("leaked strings=" + std::to_string(g.strings.size()) + sample);
        }
        if (!g.pictures.empty()) fail("leaked pictures=" + std::to_string(g.pictures.size()));
        if (!g.handles.empty()) fail("leaked handles=" + std::to_string(g.handles.size()));
    }
    if (g.failures.empty()) {
        printf("PASS %s\n", name.c_str());
        return 0;
    }
    for (auto &f : g.failures) printf("FAIL %s: %s\n", name.c_str(), f.c_str());
    return 1;
}

static std::vector<std::string> split(const std::string &s)
{
    std::vector<std::string> out;
    size_t start = 0, pos;
    while ((pos = s.find(':', start)) != std::string::npos) { out.push_back(s.substr(start, pos - start)); start = pos + 1; }
    out.push_back(s.substr(start));
    return out;
}

static std::vector<U16> urls(const std::string &text)
{
    if (text == "ascii") return { u16(u"myapp://open?id=42&x=y"), u16(u"myapp:second") };
    if (text == "bmp") return { u16(u"myapp://\u65e5\u672c/\u00e9t\u00e9?q=\u0416"), u16(u"myapp:\u4e2d\u6587") };
    if (text == "supplementary") return { u16(u"myapp://\U0001F600/\U00020B9F?f=\U0001F468\u200D\U0001F469"), u16(u"myapp:\U0001D11E") };
    return { U16(), U16() };
}

// ------------------------------------------------------------------ cases

// callback:<method|fallback>:<ascii|bmp|supplementary|empty>:<allocated|null>:<undefined|text|picture>:<none|command|handle>
static int runCallback(const std::string &name)
{
    std::vector<std::string> p = split(name);
    if (p.size() != 6) deny("malformed callback case");
    bool method = p[1] == "method";
    g.methodId = method ? 123 : 0;
    g.nullEmpty = (p[3] == "null");
    g.resultKind = (p[4] == "text") ? 1 : (p[4] == "picture") ? 2 : 0;
    g.failure = p[5];
    g.processName = u16(u"Main");
    U16 listener = u16(u"ON_URL_\u65e5\u672c");

    initPlugin();
    registerProtocol(u16(u"myapp"), listener);
    if (g.schemes.size() != 1 || g.schemes[0] != "myapp" || g.handlers[0] != "com.4D.url-redirect")
        fail("REGISTER PROTOCOL scheme/handler");
    if (customurl::LISTENER_METHOD != listener) fail("LISTENER_METHOD not stored");

    std::vector<U16> sent = urls(p[2]);
    for (const U16 &u : sent) deliver(@{ @"url": ns(u) });
    if (customurl::CUSTOM_URL.size() != sent.size()) fail("URL queue size after delivery");

    if (g.failure == "handle")
        g.armHandleSize = method ? 2 * sizeof(PA_Variable) : 2 * sizeof(PA_Variable *);
    runListener();
    g.armHandleSize = 0;

    size_t expectedCalls = (g.failure == "handle") ? 0 : sent.size();
    if (g.calls.size() != expectedCalls)
        fail("callback count " + std::to_string(g.calls.size()) + " != " + std::to_string(expectedCalls));
    for (size_t i = 0; i < g.calls.size() && i < sent.size(); ++i)
        if (g.calls[i] != sent[i]) fail("call " + std::to_string(i) + " URL \"" + utf8(g.calls[i]) + "\" != \"" + utf8(sent[i]) + "\"");
    for (const U16 &n : g.fallbackNames)
        if (n != listener) fail("EXECUTE METHOD name \"" + utf8(n) + "\"");
    if (!method && g.fallbackNames.size() != g.calls.size()) fail("fallback name count");
    if (g.methodLookups.size() != sent.size()) fail("method lookup count");
    for (const U16 &l : g.methodLookups)
        if (l != listener) fail("method lookup by name");
    expectTeardown();

    releaseParams();
    return finish(name);
}

static int runControl(const std::string &name)
{
    g.processName = u16(u"Main");
    initPlugin();
    if (name == "control:register") {
        registerProtocol(u16(u"x-\u00e9\U0001F600"), u16(u"M"));
        if (g.bundleLookups != 1) fail("bundle lookup");
        if (g.schemes.size() != 1 || g.schemes[0] != "x-\u00e9\U0001F600" || g.handlers[0] != "com.4D.url-redirect")
            fail("LSSetDefaultHandlerForURLScheme arguments");
        if (customurl::LISTENER_METHOD != u16(u"M")) fail("LISTENER_METHOD");
        g.aliveIterations = 0;
        runListener();
        expectTeardown();
    } else if (name == "control:empty-method") {
        g.methodId = 0;
        registerProtocol(u16(u"myapp"), U16());
        if (!customurl::LISTENER_METHOD.empty()) fail("LISTENER_METHOD not empty");
        deliver(@{ @"url": @"myapp:x" });
        runListener();
        if (!g.calls.empty() || !g.fallbackNames.empty()) fail("method invoked without listener");
        expectTeardown();
    } else if (name == "control:no-url-key") {
        registerProtocol(u16(u"myapp"), u16(u"M"));
        deliver(@{ @"other": @"myapp:x" });
        if (!customurl::CUSTOM_URL.empty() || customurl::PROCESS_SHOULD_RESUME) fail("event without url enqueued");
        runListener();
        if (g.sleeps != 1 || !g.calls.empty()) fail("idle listener did not sleep");
        expectTeardown();
    } else if (name == "control:close-exit-process") {
        registerProtocol(u16(u"myapp"), u16(u"M"));
        g.aliveIterations = 100;
        g.closeOnYield = true;
        runListener();
        if (g.closeOnYield || g.dyingCalls != 1 || !g.calls.empty()) fail("listener did not terminate on exit request");
        expectTeardown();
    } else if (name == "control:close-other-process") {
        registerProtocol(u16(u"myapp"), u16(u"M"));
        dispatch(kCloseProcess, NULL);
        if (customurl::PROCESS_SHOULD_TERMINATE) fail("non-exit process stopped listener");
        runListener();
        if (g.sleeps != 1) fail("listener did not idle");
        expectTeardown();
    } else {
        deny("unknown control");
    }
    releaseParams();
    return finish(name);
}

static PA_Variable newTextArray(const std::vector<U16> &values)
{
    PA_Variable a = PA_CreateVariable(eVK_ArrayUnicode);
    PA_ResizeArray(&a, (PA_long32)values.size());
    for (size_t i = 0; i < values.size(); ++i) {
        PA_Unistring s = PA_CreateUnistring((PA_Unichar *)values[i].c_str());
        PA_SetStringInArray(a, (PA_long32)i + 1, &s);
    }
    return a;
}

// SDK contract controls: PA_SetStringInArray takes ownership only when it accepts the value.
static int runArray(const std::string &name)
{
    std::vector<std::string> p = split(name);
    initPlugin();
    const std::string &mode = p[1];
    PA_Variable a = newTextArray({ u16(u"one"), u16(u"two") });
    PA_Unistring s = PA_CreateUnistring((PA_Unichar *)u"candidate");
    PA_Unichar *candidate = s.fString;
    bool accepted = false;
    if (mode == "accept-index0") { PA_SetStringInArray(a, 0, &s); accepted = true; }
    else if (mode == "accept-last") { PA_SetStringInArray(a, 2, &s); accepted = true; }
    else if (mode == "reject-negative") PA_SetStringInArray(a, -1, &s);
    else if (mode == "reject-past-end") PA_SetStringInArray(a, 3, &s);
    else if (mode == "reject-null-ustr") PA_SetStringInArray(a, 1, NULL);
    else if (mode == "reject-wrong-kind") { PA_Variable w = a; w.fType = eVK_ArrayLongint; PA_SetStringInArray(w, 1, &s); }
    else if (mode == "reject-null-data") { PA_Variable w = a; w.uValue.fArray.fData = 0; PA_SetStringInArray(w, 1, &s); }
    else deny("unknown array case");
    if (!g.strings.count(candidate)) fail("candidate disposed by SDK");
    if (accepted) {
        PA_Unistring e = PA_GetStringInArray(a, mode == "accept-index0" ? 0 : 2);
        if (e.fString != candidate) fail("accepted element not transferred");
    } else {
        PA_DisposeUnistring(&s);
    }
    PA_ClearVariable(&a);
    releaseParams();
    return finish(name);
}

static int runPlatform(const std::string &name)
{
    for (const char *cls : { "OwnershipBundle", "OwnershipDeniedUUID" }) {
        Class c = (Class)objc_getClass(cls);
        const char *image = c ? class_getImageName(c) : NULL;
        const char *tail = image ? strrchr(image, '/') : NULL;
        if (!tail || strcmp(tail, "/ownership_host") != 0) fail(std::string("class not provided by harness: ") + cls);
    }
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *img = _dyld_get_image_name(i);
        if (strstr(img, "/Protocol.bundle") || strstr(img, "url-redirect"))
            fail(std::string("forbidden image loaded: ") + img);
    }
    return finish(name);
}

// Expected-failure probes. Each runs in its own process; the Python driver asserts the outcome.
static int runProbe(const std::string &name)
{
    initPlugin();
    if (name == "probe:shallow-overwrite-leak") {
        PA_Variable v = PA_CreateVariable(eVK_Unistring);   // allocated empty owner
        PA_Unistring s = PA_CreateUnistring((PA_Unichar *)u"x");
        PA_SetStringVariable(&v, &s);                        // shallow: empty owner lost
        PA_ClearVariable(&v);
        return finish(name);
    }
    if (name == "probe:discarded-result-leak") {
        g.resultKind = 1;
        PA_Variable none = PA_CreateVariable(eVK_Undefined);
        PA_ExecuteMethodByID(123, &none, 0);                 // owned text result discarded
        return finish(name);
    }
    if (name == "probe:alias-double-clear") {
        PA_Variable a = PA_CreateVariable(eVK_Undefined);
        PA_Unistring s = PA_CreateUnistring((PA_Unichar *)u"x");
        PA_SetStringVariable(&a, &s);
        PA_Variable b = a;
        PA_ClearVariable(&a);
        PA_ClearVariable(&b);
        return finish(name);
    }
    if (name == "probe:array-transfer-then-dispose") {
        PA_Variable a = newTextArray({ u16(u"one") });
        PA_Unistring s = PA_CreateUnistring((PA_Unichar *)u"x");
        PA_SetStringInArray(a, 1, &s);
        PA_DisposeUnistring(&s);                             // violates contract (1)
        PA_ClearVariable(&a);
        return finish(name);
    }
    if (name == "probe:clear-failed-result") {
        g.failure = "command";
        PA_Variable none = PA_CreateVariable(eVK_Undefined);
        PA_Variable r = PA_ExecuteMethodByID(123, &none, 0);
        PA_ClearVariable(&r);
        return finish(name);
    }
    if (name == "probe:denied-lsregister") {
        OwnershipLSRegisterURL(NULL, false);
        return finish(name);
    }
    if (name == "probe:denied-uuid") {
        [OwnershipDeniedUUID class];
        return finish(name);
    }
    deny("unknown probe");
    return 2;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s <case>\n", argv[0]);
            return 2;
        }
        std::string name = argv[1];
        setvbuf(stdout, NULL, _IONBF, 0);
        if (name.rfind("callback:", 0) == 0) return runCallback(name);
        if (name.rfind("control:", 0) == 0) return runControl(name);
        if (name.rfind("array:", 0) == 0) return runArray(name);
        if (name == "platform:isolation") return runPlatform(name);
        if (name.rfind("probe:", 0) == 0) return runProbe(name);
        deny("unknown case");
    }
    return 2;
}
