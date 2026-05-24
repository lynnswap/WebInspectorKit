#include "WebInspectorNativeSymbolFixtures.h"

#define WIK_FIXTURE_SYMBOL(name, symbol) \
    void name(void) __asm__(symbol); \
    __attribute__((visibility("default"), used, noinline)) void name(void) {}

WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureWebKitConnectFrontend,
    "__ZN6WebKit26WebPageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb"
)
WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureWebKitDisconnectFrontend,
    "__ZN6WebKit26WebPageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE"
)
WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureWTFStringFromUTF8,
    "__ZN3WTF6String8fromUTF8ENSt3__14spanIKDuLm18446744073709551615EEE"
)
WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureWTFStringImplToNSString,
    "__ZN3WTF10StringImplcvP8NSStringEv"
)
WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureWTFDestroyStringImpl,
    "__ZN3WTF10StringImpl7destroyEPS0_"
)
WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureBackendDispatcherDispatch,
    "__ZN9Inspector17BackendDispatcher8dispatchERKN3WTF6StringE"
)
WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureWebCorePageInspectorConnect,
    "__ZN7WebCore23PageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb"
)
WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureWebCorePageInspectorDisconnect,
    "__ZN7WebCore23PageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE"
)
WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureWebCoreFrameInspectorConnect,
    "__ZN7WebCore24FrameInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb"
)
WIK_FIXTURE_SYMBOL(
    WebInspectorNativeFixtureWebCoreFrameInspectorDisconnect,
    "__ZN7WebCore24FrameInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE"
)

static void (*volatile WebInspectorNativeSymbolFixtureReference)(void);

__attribute__((visibility("default"), used, noinline))
void WebInspectorNativeSymbolFixtureAnchor(void)
{
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureWebKitConnectFrontend;
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureWebKitDisconnectFrontend;
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureWTFStringFromUTF8;
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureWTFStringImplToNSString;
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureWTFDestroyStringImpl;
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureBackendDispatcherDispatch;
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureWebCorePageInspectorConnect;
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureWebCorePageInspectorDisconnect;
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureWebCoreFrameInspectorConnect;
    WebInspectorNativeSymbolFixtureReference = WebInspectorNativeFixtureWebCoreFrameInspectorDisconnect;
}
