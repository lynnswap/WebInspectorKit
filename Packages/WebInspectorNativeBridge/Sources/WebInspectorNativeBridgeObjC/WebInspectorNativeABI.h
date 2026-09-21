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

inline void constructStringFromUTF8(
    WTF::String *storage,
    std::span<const char8_t> characters,
    uintptr_t stringFromUTF8Address
)
{
    if (!stringFromUTF8Address)
        return;

#if defined(__aarch64__) || defined(__arm64__)
    register const char8_t *data asm("x0") = characters.data();
    register size_t length asm("x1") = characters.size();
    register WTF::String *result asm("x8") = storage;
    void *symbol = reinterpret_cast<void *>(stringFromUTF8Address);
    asm volatile(
        "blr %3"
        : "+r"(data), "+r"(length), "+r"(result)
        : "r"(symbol)
        : "cc", "memory", "x2", "x3", "x4", "x5", "x6", "x7", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "lr"
    );
#elif defined(__x86_64__)
    register WTF::String *result asm("rdi") = storage;
    register const char8_t *data asm("rsi") = characters.data();
    register size_t length asm("rdx") = characters.size();
    void *symbol = reinterpret_cast<void *>(stringFromUTF8Address);
    asm volatile(
        "call *%3"
        : "+r"(result), "+r"(data), "+r"(length)
        : "r"(symbol)
        : "cc", "memory", "rax", "rcx", "r8", "r9", "r10", "r11"
    );
#else
#error Unsupported architecture for WebInspectorNativeABI::constructStringFromUTF8
#endif
}

inline void constructStringFromNSString(
    WTF::String *storage,
    NSString *string,
    uintptr_t stringFromUTF8Address
)
{
    NSData *utf8Data = [string dataUsingEncoding:NSUTF8StringEncoding];
    auto *bytes = reinterpret_cast<const char8_t *>(utf8Data.bytes);
    constructStringFromUTF8(storage, std::span<const char8_t>(bytes, utf8Data.length), stringFromUTF8Address);
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
        : m_derefStringImplAddress(derefStringImplAddress)
    {
        constructStringFromNSString(&m_string, string, stringFromUTF8Address);
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
