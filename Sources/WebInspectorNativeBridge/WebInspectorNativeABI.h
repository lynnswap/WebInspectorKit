#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <cstdint>
#include <span>

namespace WTF {

class StringImpl;

// Minimal ABI shim for the inspector probe. We only rely on String being a single
// StringImpl pointer and construct/destroy it through exported JSC symbols.
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

static_assert(sizeof(String) == sizeof(void *), "WTF::String ABI changed");

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

struct StringImplRefCountHeader {
    std::atomic<uint32_t> refCount;
};

static constexpr uint32_t stringImplStaticFlag = 0x1;
static constexpr uint32_t stringImplRefCountIncrement = 0x2;

using StringImplToNSStringFn = NSString *(*)(void *);
using DestroyStringImplFn = void (*)(void *);
using BackendDispatcherDispatchFn = void (*)(void *, const WTF::String&);

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

inline void derefConstructedString(const WTF::String& string, uintptr_t destroyStringImplAddress)
{
    if (!string.impl())
        return;

    auto *header = reinterpret_cast<StringImplRefCountHeader *>(string.impl());
    uint32_t currentRefCount = header->refCount.load(std::memory_order_relaxed);
    if (currentRefCount & stringImplStaticFlag)
        return;

    uint32_t oldRefCount = header->refCount.fetch_sub(stringImplRefCountIncrement, std::memory_order_relaxed);
    if (oldRefCount == stringImplRefCountIncrement && destroyStringImplAddress) {
        auto *destroyStringImpl = reinterpret_cast<DestroyStringImplFn>(destroyStringImplAddress);
        destroyStringImpl(string.impl());
    }
}

class ConstructedString final {
public:
    ConstructedString(NSString *string, uintptr_t stringFromUTF8Address, uintptr_t destroyStringImplAddress)
        : m_destroyStringImplAddress(destroyStringImplAddress)
    {
        constructStringFromNSString(&m_string, string, stringFromUTF8Address);
    }

    ~ConstructedString()
    {
        derefConstructedString(m_string, m_destroyStringImplAddress);
    }

    ConstructedString(const ConstructedString&) = delete;
    ConstructedString& operator=(const ConstructedString&) = delete;

    const WTF::String& get() const
    {
        return m_string;
    }

private:
    WTF::String m_string;
    uintptr_t m_destroyStringImplAddress { 0 };
};

inline void dispatchToBackendDispatcher(
    void *backendDispatcher,
    const WTF::String& string,
    uintptr_t backendDispatcherDispatchAddress
)
{
    if (!backendDispatcher || !backendDispatcherDispatchAddress)
        return;

    auto *dispatch = reinterpret_cast<BackendDispatcherDispatchFn>(backendDispatcherDispatchAddress);
    dispatch(backendDispatcher, string);
}

} // namespace WebInspectorNativeABI
