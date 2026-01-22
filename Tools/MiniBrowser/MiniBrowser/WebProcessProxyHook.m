#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <unistd.h>

#if DEBUG && TARGET_OS_IOS && !TARGET_OS_MACCATALYST

static bool did_install_hook;
static bool did_log_missing_symbol;
static bool did_log_install_failure;
static bool did_install_be_swizzle;
static bool did_log_missing_be_class;
static bool did_log_missing_be_method;
// Temporarily disable WebContent.Development override to verify behavior.
// (Keep the flag around in case we re-enable the override.)
static bool did_log_development_fallback;

static void log_line(const char *message)
{
    fprintf(stderr, "WebProcessProxyHook: %s\n", message);
}

static bool set_memory_protection(void *address, size_t size, vm_prot_t protection)
{
    size_t page_size = (size_t)getpagesize();
    uintptr_t page_start = (uintptr_t)address & ~(page_size - 1);
    uintptr_t page_end = ((uintptr_t)address + size + page_size - 1) & ~(page_size - 1);
    vm_size_t length = (vm_size_t)(page_end - page_start);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page_start, length, false, protection);
    if (kr != KERN_SUCCESS) {
        log_line("vm_protect failed");
        return false;
    }
    return true;
}

static void flush_instruction_cache(void *address, size_t size)
{
    sys_icache_invalidate(address, size);
}

static bool write_absolute_jump(void *from, void *to)
{
#if defined(__arm64__)
    uint32_t *insn = (uint32_t *)from;
    uint64_t target = (uint64_t)to;
    uint64_t pc = (uint64_t)from;
    uint64_t pc_page = pc & ~0xFFFULL;
    uint64_t target_page = target & ~0xFFFULL;
    int64_t page_delta = (int64_t)target_page - (int64_t)pc_page;
    int64_t imm = page_delta >> 12;
    if (imm < -(1LL << 20) || imm >= (1LL << 20)) {
        log_line("adrp immediate out of range");
        return false;
    }
    uint32_t immlo = (uint32_t)(imm & 0x3);
    uint32_t immhi = (uint32_t)((imm >> 2) & 0x7FFFF);
    uint32_t adrp = 0x90000000 | (immlo << 29) | (immhi << 5) | 16;
    uint32_t add = 0x91000000 | ((uint32_t)(target & 0xFFF) << 10) | (16 << 5) | 16;
    uint32_t br = 0xD61F0000 | (16 << 5);
    insn[0] = adrp;
    insn[1] = add;
    insn[2] = br;
    insn[3] = 0xD503201F;
    return true;
#else
    (void)from;
    (void)to;
    log_line("inline hook unsupported on this architecture");
    return false;
#endif
}

static bool install_jump(void *target, void *replacement)
{
    const size_t patch_size = 16;
    if (!set_memory_protection(target, patch_size, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE))
        return false;
    if (!write_absolute_jump(target, replacement)) {
        set_memory_protection(target, patch_size, VM_PROT_READ | VM_PROT_EXECUTE);
        return false;
    }
    flush_instruction_cache(target, patch_size);
    set_memory_protection(target, patch_size, VM_PROT_READ | VM_PROT_EXECUTE);
    flush_instruction_cache(target, patch_size);
    return true;
}

static bool replacement_shouldAllowNonValidInjectedCode(void *self)
{
    (void)self;
    return true;
}

typedef void (^BEWebContentProcessInterruptionHandler)(void);
typedef void (^BEWebContentProcessCompletion)(id _Nullable process, NSError * _Nullable error);
typedef void (*BEWebContentProcessWithBundleIDFunc)(id, SEL, NSString *, BEWebContentProcessInterruptionHandler, BEWebContentProcessCompletion);
static BEWebContentProcessWithBundleIDFunc original_webContentProcessWithBundleID;

static void replacement_webContentProcessWithBundleID(id self, SEL _cmd, NSString *bundleID, BEWebContentProcessInterruptionHandler interruptionHandler, BEWebContentProcessCompletion completion)
{
    if (!bundleID || ![bundleID isEqualToString:@"com.apple.WebKit.WebContent"]) {
        original_webContentProcessWithBundleID(self, _cmd, bundleID, interruptionHandler, completion);
        return;
    }

#if 0
    __block bool didFallback = false;
    BEWebContentProcessCompletion wrappedCompletion = ^(id process, NSError *error) {
        if (!error || didFallback) {
            if (completion)
                completion(process, error);
            return;
        }
        if (!did_log_development_fallback) {
            did_log_development_fallback = true;
            log_line("WebContent.Development unavailable; retrying with WebContent");
        }
        didFallback = true;
        original_webContentProcessWithBundleID(self, _cmd, @"com.apple.WebKit.WebContent", interruptionHandler, completion);
    };

    original_webContentProcessWithBundleID(self, _cmd, @"com.apple.WebKit.WebContent.Development", interruptionHandler, wrappedCompletion);
#else
    original_webContentProcessWithBundleID(self, _cmd, bundleID, interruptionHandler, completion);
#endif
}

static void install_be_webcontent_swizzle(void)
{
    if (did_install_be_swizzle)
        return;

    Class beWebContentProcessClass = objc_getClass("BEWebContentProcess");
    if (!beWebContentProcessClass) {
        if (!did_log_missing_be_class) {
            did_log_missing_be_class = true;
            log_line("BEWebContentProcess not available");
        }
        return;
    }

    SEL selector = sel_getUid("webContentProcessWithBundleID:interruptionHandler:completion:");
    Method method = class_getClassMethod(beWebContentProcessClass, selector);
    if (!method) {
        if (!did_log_missing_be_method) {
            did_log_missing_be_method = true;
            log_line("BEWebContentProcess webContentProcessWithBundleID:interruptionHandler:completion: not found");
        }
        return;
    }

    original_webContentProcessWithBundleID = (BEWebContentProcessWithBundleIDFunc)method_getImplementation(method);
    if (!original_webContentProcessWithBundleID) {
        if (!did_log_missing_be_method) {
            did_log_missing_be_method = true;
            log_line("BEWebContentProcess webContentProcessWithBundleID:interruptionHandler:completion: impl missing");
        }
        return;
    }

    method_setImplementation(method, (IMP)replacement_webContentProcessWithBundleID);
    did_install_be_swizzle = true;
    log_line("swizzled BEWebContentProcess webContentProcessWithBundleID:interruptionHandler:completion:");
}

void MiniBrowserInstallWebProcessProxyHook(void)
{
    if (did_install_hook || did_install_be_swizzle)
        return;

    const char *symbol = "__ZNK6WebKit15WebProcessProxy31shouldAllowNonValidInjectedCodeEv";
    void *target = dlsym(RTLD_DEFAULT, symbol);
    if (target) {
        if (install_jump(target, (void *)replacement_shouldAllowNonValidInjectedCode)) {
            did_install_hook = true;
            log_line("installed shouldAllowNonValidInjectedCode hook");
        } else if (!did_log_install_failure) {
            did_log_install_failure = true;
            log_line("failed to install shouldAllowNonValidInjectedCode hook");
        }
        return;
    }

    install_be_webcontent_swizzle();
    if (!did_install_be_swizzle && !did_log_missing_symbol) {
        did_log_missing_symbol = true;
        log_line("symbol not found for WebProcessProxy::shouldAllowNonValidInjectedCode");
    }
}
#else
void MiniBrowserInstallWebProcessProxyHook(void)
{
}
#endif
