#import <Foundation/Foundation.h>

@protocol WKWebProcessPlugIn <NSObject>
@optional
- (void)webProcessPlugIn:(id)plugInController initializeWithObject:(id)initializationObject;
- (void)webProcessPlugIn:(id)plugInController didCreateBrowserContextController:(id)browserContextController;
@end

extern void MiniBrowserInjectedBundleInstallHooks(void);
extern void MiniBrowserInjectedBundleLog(const char *message);

@interface MiniBrowserInjectedBundleMain : NSObject <WKWebProcessPlugIn>
@end

@implementation MiniBrowserInjectedBundleMain

+ (void)load
{
    MiniBrowserInjectedBundleLog("MiniBrowserInjectedBundleMain +load");
    MiniBrowserInjectedBundleInstallHooks();
}

- (void)webProcessPlugIn:(id)plugInController initializeWithObject:(id)initializationObject
{
    (void)plugInController;
    (void)initializationObject;
    MiniBrowserInjectedBundleLog("MiniBrowserInjectedBundleMain initializeWithObject");
    MiniBrowserInjectedBundleInstallHooks();
}

- (void)webProcessPlugIn:(id)plugInController didCreateBrowserContextController:(id)browserContextController
{
    (void)plugInController;
    (void)browserContextController;
    MiniBrowserInjectedBundleLog("MiniBrowserInjectedBundleMain didCreateBrowserContextController");
}

@end
