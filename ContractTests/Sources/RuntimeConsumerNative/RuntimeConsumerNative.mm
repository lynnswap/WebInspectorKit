#import "RuntimeConsumerNative.h"
#import "WebKitRuntimeObjC.h"

uintptr_t RuntimeConsumerAnchorAddress(void)
{
    return reinterpret_cast<uintptr_t>(&RuntimeConsumerAnchorAddress);
}
NSUInteger RuntimeConsumerPageSize(WKWebView *view)
{
    WKRuntimePageStorage *storage = [WKRuntimePageStorage storageForWebView:view];
    return storage.byteCount;
}
