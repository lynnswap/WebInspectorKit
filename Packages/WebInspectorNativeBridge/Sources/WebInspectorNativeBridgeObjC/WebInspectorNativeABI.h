#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <cstdint>
#include <span>

namespace WTF {

class StringImpl;

// Minimal ABI shim for the inspector probe. We only rely on String being a single
// StringImpl pointer and construct/release it through runtime entry points.
class String {
public:
    String() = default;
    // WebKit returns String indirectly because its destructor is nontrivial.
    // ConstructedString releases the actual StringImpl through the runtime.
    ~String() { }

    String(const String&) = delete;
    String& operator=(const String&) = delete;

    StringImpl *impl() const
    {
        return m_impl;
    }

private:
    StringImpl *m_impl { nullptr };
};

static_assert(sizeof(String) == sizeof(void *), "native string ABI changed");

} // namespace WTF

namespace Inspector {

class FrontendChannel {
public:
    enum class ConnectionType : bool {
        Remote,
        Local
    };

    virtual ~FrontendChannel() = default;
    virtual ConnectionType connectionType() const = 0;
    virtual void sendMessageToFrontend(const WTF::String& message) = 0;
};

} // namespace Inspector

namespace WebInspectorNativeABI {

using StringImplToNSStringFn = NSString *(*)(void *);
using DerefStringImplFn = void (*)(void *);
using DispatchMessageFromRemoteFn = void (*)(void *, WTF::String&&);

inline NSString *copyNSString(const WTF::String& string, uintptr_t stringImplToNSStringAddress)
{
    if (!string.impl())
        return @"";
    if (!stringImplToNSStringAddress)
        return @"";

    auto *copyString = reinterpret_cast<StringImplToNSStringFn>(stringImplToNSStringAddress);
    NSString *message = copyString(string.impl());
    return [message copy] ?: @"";
}

inline WTF::String stringFromNSString(NSString *string, uintptr_t stringFromUTF8Address)
{
    NSData *utf8Data = [string dataUsingEncoding:NSUTF8StringEncoding];
    auto *bytes = reinterpret_cast<const char8_t *>(utf8Data.bytes);
    using Factory = WTF::String (*)(std::span<const char8_t>);
    return reinterpret_cast<Factory>(stringFromUTF8Address)(std::span<const char8_t>(bytes, utf8Data.length));
}

inline void derefConstructedString(const WTF::String& string, uintptr_t derefStringImplAddress)
{
    if (!string.impl())
        return;

    auto *derefStringImpl = reinterpret_cast<DerefStringImplFn>(derefStringImplAddress);
    derefStringImpl(string.impl());
}

class ConstructedString final {
public:
    ConstructedString(NSString *string, uintptr_t stringFromUTF8Address, uintptr_t derefStringImplAddress)
        : m_string(stringFromNSString(string, stringFromUTF8Address))
        , m_derefStringImplAddress(derefStringImplAddress)
    {
    }

    ~ConstructedString()
    {
        derefConstructedString(m_string, m_derefStringImplAddress);
    }

    ConstructedString(const ConstructedString&) = delete;
    ConstructedString& operator=(const ConstructedString&) = delete;

    WTF::String& get()
    {
        return m_string;
    }

private:
    WTF::String m_string;
    uintptr_t m_derefStringImplAddress { 0 };
};

inline void dispatchToRemoteTarget(
    void *target,
    WTF::String& string,
    uintptr_t dispatchMessageFromRemoteAddress
)
{
    if (!target || !dispatchMessageFromRemoteAddress)
        return;

    auto *dispatch = reinterpret_cast<DispatchMessageFromRemoteFn>(dispatchMessageFromRemoteAddress);
    dispatch(target, static_cast<WTF::String&&>(string));
}

} // namespace WebInspectorNativeABI
