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

namespace Inspector {
class BackendDispatcher {
public:
    WIK_FIXTURE_SYMBOL void dispatch(const WTF::String&);
};
}

namespace WebKit {
class WebPageInspectorController {
public:
    WIK_FIXTURE_SYMBOL void connectFrontend(Inspector::FrontendChannel&, bool);
    WIK_FIXTURE_SYMBOL void connectFrontend(Inspector::FrontendChannel*, bool, bool);
    WIK_FIXTURE_SYMBOL void connectFrontend(bool, Inspector::FrontendChannel&, bool);
    WIK_FIXTURE_SYMBOL void connectFrontend(Inspector::FrontendChannel&, bool, int);
    WIK_FIXTURE_SYMBOL void connectFrontend(Inspector::FrontendChannel&, bool, bool);
    WIK_FIXTURE_SYMBOL void disconnectFrontend(Inspector::FrontendChannel&);
};
}

namespace WebCore {
class PageInspectorController {
public:
    WIK_FIXTURE_SYMBOL void connectFrontend(Inspector::FrontendChannel&, bool, bool);
    WIK_FIXTURE_SYMBOL void disconnectFrontend(Inspector::FrontendChannel&);
};

class FrameInspectorController {
public:
    WIK_FIXTURE_SYMBOL void connectFrontend(Inspector::FrontendChannel&, bool, bool);
    WIK_FIXTURE_SYMBOL void disconnectFrontend(Inspector::FrontendChannel&);
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

WIK_FIXTURE_SYMBOL void WebKit::WebPageInspectorController::connectFrontend(Inspector::FrontendChannel&, bool)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageInspectorController::connectFrontend(Inspector::FrontendChannel*, bool, bool)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageInspectorController::connectFrontend(bool, Inspector::FrontendChannel&, bool)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageInspectorController::connectFrontend(Inspector::FrontendChannel&, bool, int)
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

WIK_FIXTURE_SYMBOL void Inspector::BackendDispatcher::dispatch(const WTF::String&)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageInspectorController::connectFrontend(
    Inspector::FrontendChannel&,
    bool,
    bool
)
{
}

WIK_FIXTURE_SYMBOL void WebKit::WebPageInspectorController::disconnectFrontend(Inspector::FrontendChannel&)
{
}

WIK_FIXTURE_SYMBOL void WebCore::PageInspectorController::connectFrontend(
    Inspector::FrontendChannel&,
    bool,
    bool
)
{
}

WIK_FIXTURE_SYMBOL void WebCore::PageInspectorController::disconnectFrontend(Inspector::FrontendChannel&)
{
}

WIK_FIXTURE_SYMBOL void WebCore::FrameInspectorController::connectFrontend(
    Inspector::FrontendChannel&,
    bool,
    bool
)
{
}

WIK_FIXTURE_SYMBOL void WebCore::FrameInspectorController::disconnectFrontend(Inspector::FrontendChannel&)
{
}

void WebInspectorNativeSymbolFixtureAnchor(void)
{
    Inspector::FrontendChannel frontendChannel;
    WebKit::WebPageInspectorController webKitController;
    WebCore::PageInspectorController pageController;
    WebCore::FrameInspectorController frameController;
    WTF::String string = WTF::String::fromUTF8(std::span<const char8_t>());
    WTF::StringImpl stringImpl;
    Inspector::BackendDispatcher backendDispatcher;

    webKitController.connectFrontend(frontendChannel, false, false);
    webKitController.disconnectFrontend(frontendChannel);
    webKitController.connectFrontend(frontendChannel, false);
    webKitController.connectFrontend(&frontendChannel, false, false);
    webKitController.connectFrontend(false, frontendChannel, false);
    webKitController.connectFrontend(frontendChannel, false, 0);
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
    backendDispatcher.dispatch(string);
    pageController.connectFrontend(frontendChannel, false, false);
    pageController.disconnectFrontend(frontendChannel);
    frameController.connectFrontend(frontendChannel, false, false);
    frameController.disconnectFrontend(frontendChannel);
}

uintptr_t WebInspectorNativeSymbolFixtureWTFStringFromUTF8Address(void)
{
    using Factory = WTF::String (*)(std::span<const char8_t>);
    return reinterpret_cast<uintptr_t>(static_cast<Factory>(&WTF::String::fromUTF8));
}
