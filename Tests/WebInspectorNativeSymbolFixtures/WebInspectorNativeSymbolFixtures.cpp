#include "WebInspectorNativeSymbolFixtures.h"

#include <span>

class NSString;

#define WIK_FIXTURE_SYMBOL __attribute__((visibility("default"), used, noinline))

namespace Inspector {
class FrontendChannel { };
}

namespace WTF {
class String {
public:
    WIK_FIXTURE_SYMBOL static String fromUTF8(std::span<const char8_t>);
    WIK_FIXTURE_SYMBOL static String fromUTF8(std::span<const char8_t, 4>);
    WIK_FIXTURE_SYMBOL static String fromUTF8(std::span<const char>);
    WIK_FIXTURE_SYMBOL static String fromUTF8(std::span<const char8_t>, bool);
    WIK_FIXTURE_SYMBOL static String fromUTF8ReplacingInvalidSequences(std::span<const char8_t>);
    WIK_FIXTURE_SYMBOL static String fromUTF8WithLatin1Fallback(std::span<const char8_t>);
};

class StringImpl {
public:
    WIK_FIXTURE_SYMBOL operator NSString*();
    WIK_FIXTURE_SYMBOL static void destroy(StringImpl*);
    WIK_FIXTURE_SYMBOL void deref();
    WIK_FIXTURE_SYMBOL void deref(unsigned);
};
}

namespace WebKit {
class WebPageDebuggable {
public:
    WIK_FIXTURE_SYMBOL virtual ~WebPageDebuggable();
    WIK_FIXTURE_SYMBOL void dispatchMessageFromRemote(WTF::String&&);
    WIK_FIXTURE_SYMBOL void connect(Inspector::FrontendChannel&, bool);
    WIK_FIXTURE_SYMBOL void connect(Inspector::FrontendChannel*, bool, bool);
    WIK_FIXTURE_SYMBOL void connect(bool, Inspector::FrontendChannel&, bool);
    WIK_FIXTURE_SYMBOL void connect(Inspector::FrontendChannel&, bool, int);
    WIK_FIXTURE_SYMBOL void connect(Inspector::FrontendChannel&, bool, bool);
    WIK_FIXTURE_SYMBOL void disconnect(Inspector::FrontendChannel&);
};
}

WIK_FIXTURE_SYMBOL WTF::String WTF::String::fromUTF8(std::span<const char8_t>)
{
    return { };
}

WIK_FIXTURE_SYMBOL WTF::String WTF::String::fromUTF8(std::span<const char8_t, 4>)
{
    return { };
}

WIK_FIXTURE_SYMBOL WTF::String WTF::String::fromUTF8(std::span<const char>)
{
    return { };
}

WIK_FIXTURE_SYMBOL WTF::String WTF::String::fromUTF8(std::span<const char8_t>, bool)
{
    return { };
}

WIK_FIXTURE_SYMBOL void WTF::StringImpl::deref(unsigned)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageDebuggable::connect(Inspector::FrontendChannel&, bool)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageDebuggable::connect(Inspector::FrontendChannel*, bool, bool)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageDebuggable::connect(bool, Inspector::FrontendChannel&, bool)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageDebuggable::connect(Inspector::FrontendChannel&, bool, int)
{
}

WIK_FIXTURE_SYMBOL WTF::String WTF::String::fromUTF8ReplacingInvalidSequences(std::span<const char8_t>)
{
    return { };
}

WIK_FIXTURE_SYMBOL WTF::String WTF::String::fromUTF8WithLatin1Fallback(std::span<const char8_t>)
{
    return { };
}

WIK_FIXTURE_SYMBOL WTF::StringImpl::operator NSString*()
{
    return nullptr;
}

WIK_FIXTURE_SYMBOL void WTF::StringImpl::destroy(StringImpl*)
{
}

WIK_FIXTURE_SYMBOL void WTF::StringImpl::deref()
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageDebuggable::connect(
    Inspector::FrontendChannel&,
    bool,
    bool
)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageDebuggable::disconnect(Inspector::FrontendChannel&)
{
}

void WebInspectorNativeSymbolFixtureAnchor(void)
{
    Inspector::FrontendChannel frontendChannel;
    WebKit::WebPageDebuggable webKitController;
    WTF::String string = WTF::String::fromUTF8(std::span<const char8_t>());
    WTF::StringImpl stringImpl;

    webKitController.connect(frontendChannel, false, false);
    webKitController.disconnect(frontendChannel);
    webKitController.dispatchMessageFromRemote(static_cast<WTF::String&&>(string));
    webKitController.connect(frontendChannel, false);
    webKitController.connect(&frontendChannel, false, false);
    webKitController.connect(false, frontendChannel, false);
    webKitController.connect(frontendChannel, false, 0);
    char8_t fixedCharacters[4] { };
    (void)WTF::String::fromUTF8(std::span<const char8_t, 4>(fixedCharacters));
    (void)WTF::String::fromUTF8(std::span<const char>());
    (void)WTF::String::fromUTF8(std::span<const char8_t>(), false);
    stringImpl.deref(1);
    (void)WTF::String::fromUTF8ReplacingInvalidSequences(std::span<const char8_t>());
    (void)WTF::String::fromUTF8WithLatin1Fallback(std::span<const char8_t>());
    (void)static_cast<NSString*>(stringImpl);
    WTF::StringImpl::destroy(&stringImpl);
    stringImpl.deref();
}

uintptr_t WebInspectorNativeSymbolFixtureWTFStringFromUTF8Address(void)
{
    using Factory = WTF::String (*)(std::span<const char8_t>);
    return reinterpret_cast<uintptr_t>(static_cast<Factory>(&WTF::String::fromUTF8));
}

WIK_FIXTURE_SYMBOL WebKit::WebPageDebuggable::~WebPageDebuggable() = default;
WIK_FIXTURE_SYMBOL void WebKit::WebPageDebuggable::dispatchMessageFromRemote(WTF::String&&) { }

namespace WKRuntimeFixture {
__attribute__((visibility("default"), used)) int value = 42;
}
