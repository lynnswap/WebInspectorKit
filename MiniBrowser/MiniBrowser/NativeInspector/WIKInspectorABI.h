#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <span>

extern "C" void WIKStringFromUTF8Symbol(void) asm("__ZN3WTF6String8fromUTF8ENSt3__14spanIKDuLm18446744073709551615EEE");
extern "C" NSString *WIKStringImplToNSString(void *stringImpl) asm("__ZN3WTF10StringImplcvP8NSStringEv");
extern "C" void WIKDestroyStringImpl(void *stringImpl) asm("__ZN3WTF10StringImpl7destroyEPS0_");

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

namespace WIKInspectorABI {

struct StringImplRefCountHeader {
    std::atomic<uint32_t> refCount;
};

static constexpr uint32_t stringImplStaticFlag = 0x1;
static constexpr uint32_t stringImplRefCountIncrement = 0x2;

inline NSString *copyNSString(const WTF::String& string)
{
    if (!string.impl())
        return @"";

    NSString *message = WIKStringImplToNSString(string.impl());
    return [message copy] ?: @"";
}

inline void constructStringFromUTF8(WTF::String *storage, std::span<const char8_t> characters)
{
#if defined(__aarch64__) || defined(__arm64__)
    register const char8_t *data asm("x0") = characters.data();
    register size_t length asm("x1") = characters.size();
    register WTF::String *result asm("x8") = storage;
    void *symbol = reinterpret_cast<void *>(WIKStringFromUTF8Symbol);
    asm volatile(
        "blr %3"
        : "+r"(data), "+r"(length), "+r"(result)
        : "r"(symbol)
        : "cc", "memory", "x2", "x3", "x4", "x5", "x6", "x7", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "lr"
    );
#else
#error Unsupported architecture for WIKInspectorABI::constructStringFromUTF8
#endif
}

inline void constructStringFromNSString(WTF::String *storage, NSString *string)
{
    NSData *utf8Data = [string dataUsingEncoding:NSUTF8StringEncoding];
    auto *bytes = reinterpret_cast<const char8_t *>(utf8Data.bytes);
    constructStringFromUTF8(storage, std::span<const char8_t>(bytes, utf8Data.length));
}

inline void derefConstructedString(const WTF::String& string)
{
    if (!string.impl())
        return;

    auto *header = reinterpret_cast<StringImplRefCountHeader *>(string.impl());
    uint32_t currentRefCount = header->refCount.load(std::memory_order_relaxed);
    if (currentRefCount & stringImplStaticFlag)
        return;

    uint32_t oldRefCount = header->refCount.fetch_sub(stringImplRefCountIncrement, std::memory_order_relaxed);
    if (oldRefCount == stringImplRefCountIncrement)
        WIKDestroyStringImpl(string.impl());
}

class ConstructedString final {
public:
    explicit ConstructedString(NSString *string)
    {
        constructStringFromNSString(&m_string, string);
    }

    ~ConstructedString()
    {
        derefConstructedString(m_string);
    }

    ConstructedString(const ConstructedString&) = delete;
    ConstructedString& operator=(const ConstructedString&) = delete;

    const WTF::String& get() const
    {
        return m_string;
    }

private:
    WTF::String m_string;
};

} // namespace WIKInspectorABI
