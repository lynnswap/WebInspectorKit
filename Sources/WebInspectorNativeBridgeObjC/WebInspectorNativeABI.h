#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <cstdint>
#include <span>
#include <ABIBridge/NativeInvocation.hpp>

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

using StringImplToNSString = abi_bridge::method<NSString *()>;
using StringFromUTF8 = abi_bridge::function<WTF::String(std::span<const char8_t>)>;
using DerefStringImpl = abi_bridge::method<void()>;
using DispatchMessageFromRemote = abi_bridge::method<void(WTF::String&&)>;

inline NSString *copyNSString(const WTF::String& string, const StringImplToNSString& copyString)
{
    if (!string.impl())
        return @"";
    NSString *message = copyString.unsafe_invoke(string.impl());
    return [message copy] ?: @"";
}

inline WTF::String stringFromNSString(NSString *string, const StringFromUTF8& factory)
{
    NSData *utf8Data = [string dataUsingEncoding:NSUTF8StringEncoding];
    auto *bytes = reinterpret_cast<const char8_t *>(utf8Data.bytes);
    return factory.unsafe_invoke(std::span<const char8_t>(bytes, utf8Data.length));
}

inline void derefConstructedString(const WTF::String& string, const DerefStringImpl& deref)
{
    if (!string.impl())
        return;

    deref.unsafe_invoke(string.impl());
}

class ConstructedString final {
public:
    ConstructedString(NSString *string, const StringFromUTF8& factory, const DerefStringImpl& deref)
        : m_string(stringFromNSString(string, factory))
        , m_deref(deref)
    {
    }

    ~ConstructedString()
    {
        derefConstructedString(m_string, m_deref);
    }

    ConstructedString(const ConstructedString&) = delete;
    ConstructedString& operator=(const ConstructedString&) = delete;

    WTF::String& get()
    {
        return m_string;
    }

private:
    WTF::String m_string;
    DerefStringImpl m_deref;
};

inline void dispatchToRemoteTarget(
    void *target,
    WTF::String& string,
    const DispatchMessageFromRemote& dispatch
)
{
    if (!target)
        return;

    dispatch.unsafe_invoke(target, static_cast<WTF::String&&>(string));
}

} // namespace WebInspectorNativeABI
