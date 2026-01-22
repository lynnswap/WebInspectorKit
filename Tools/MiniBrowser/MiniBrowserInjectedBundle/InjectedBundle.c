#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <os/log.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <objc/message.h>
#include <objc/runtime.h>

typedef const void *WKBundleRef;
typedef const void *WKBundlePageRef;
typedef const void *WKStringRef;
typedef const void *WKTypeRef;

typedef WKStringRef (*WKStringCreateWithUTF8CStringFunc)(const char *);
typedef void (*WKBundleSetClientFunc)(WKBundleRef, void *);
typedef void (*WKBundlePagePostMessageFunc)(WKBundlePageRef, WKStringRef, WKTypeRef);
typedef void *(*WKRetainFunc)(const void *);
typedef void (*WKReleaseFunc)(const void *);

typedef void (*WKBundleDidCreatePageCallback)(WKBundleRef, WKBundlePageRef, const void *);
typedef void (*WKBundleWillDestroyPageCallback)(WKBundleRef, WKBundlePageRef, const void *);

typedef struct WKBundleClientBase {
    int version;
    const void *clientInfo;
} WKBundleClientBase;

typedef struct WKBundleClientV0 {
    WKBundleClientBase base;
    WKBundleDidCreatePageCallback didCreatePage;
    WKBundleWillDestroyPageCallback willDestroyPage;
    void *didInitializePageGroup;
    void *didReceiveMessage;
} WKBundleClientV0;

static WKBundleRef injected_bundle;
static WKBundlePageRef injected_bundle_page;
static WKStringCreateWithUTF8CStringFunc wkStringCreateWithUTF8CString;
static WKBundleSetClientFunc wkBundleSetClient;
static WKBundlePagePostMessageFunc wkBundlePagePostMessage;
static WKRetainFunc wkRetain;
static WKReleaseFunc wkRelease;
static bool did_resolve_bundle_symbols;

void MiniBrowserInjectedBundleInstallHooks(void);
void MiniBrowserInjectedBundleLog(const char *message);
void MiniBrowserInjectedBundleSendRemoteLog(const char *message);

#ifndef SECT_LAZY_SYMBOL_POINTERS
#define SECT_LAZY_SYMBOL_POINTERS "__la_symbol_ptr"
#endif

#ifndef SECT_NON_LAZY_SYMBOL_POINTERS
#define SECT_NON_LAZY_SYMBOL_POINTERS "__nl_symbol_ptr"
#endif

#ifndef SECT_GOT
#define SECT_GOT "__got"
#endif

#ifndef SEG_AUTH_CONST
#define SEG_AUTH_CONST "__AUTH_CONST"
#endif

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif

struct rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

struct rebindings_entry {
    struct rebinding *rebindings;
    size_t rebindings_nel;
    struct rebindings_entry *next;
};

static struct rebindings_entry *rebindings_head;
static bool did_log_rebind_feature_impl;
static bool did_log_rebind_feature_simple_impl;

static bool set_memory_protection(void *address, size_t size, vm_prot_t protection);

static os_log_t injected_bundle_log(void)
{
    static os_log_t log;
    if (!log)
        log = os_log_create("MiniBrowserInjectedBundle", "InjectedBundle");
    return log;
}

static bool should_log(void)
{
    return true;
}

static void log_to_unified_log(os_log_type_t type, const char *message)
{
    os_log_with_type(injected_bundle_log(), type, "%{public}s", message);
    os_log_with_type(OS_LOG_DEFAULT, type, "MiniBrowserInjectedBundle: %{public}s", message);
}

static void log_line_always(const char *message)
{
    fprintf(stderr, "MiniBrowserInjectedBundle: %s\n", message);
    log_to_unified_log(OS_LOG_TYPE_FAULT, message);
    MiniBrowserInjectedBundleSendRemoteLog(message);
}

static void log_line_if_enabled(const char *message)
{
    if (!should_log())
        return;
    fprintf(stderr, "MiniBrowserInjectedBundle: %s\n", message);
    log_to_unified_log(OS_LOG_TYPE_FAULT, message);
    MiniBrowserInjectedBundleSendRemoteLog(message);
}

static void log_format_if_enabled(const char *format, ...)
{
    if (!should_log())
        return;
    va_list args;
    va_start(args, format);
    char buffer[512];
    vsnprintf(buffer, sizeof(buffer), format, args);
    fprintf(stderr, "MiniBrowserInjectedBundle: %s\n", buffer);
    log_to_unified_log(OS_LOG_TYPE_FAULT, buffer);
    MiniBrowserInjectedBundleSendRemoteLog(buffer);
    va_end(args);
}

static void resolve_bundle_symbols(void)
{
    if (did_resolve_bundle_symbols)
        return;
    did_resolve_bundle_symbols = true;
    wkStringCreateWithUTF8CString = (WKStringCreateWithUTF8CStringFunc)dlsym(RTLD_DEFAULT, "WKStringCreateWithUTF8CString");
    wkBundleSetClient = (WKBundleSetClientFunc)dlsym(RTLD_DEFAULT, "WKBundleSetClient");
    wkBundlePagePostMessage = (WKBundlePagePostMessageFunc)dlsym(RTLD_DEFAULT, "WKBundlePagePostMessage");
    wkRetain = (WKRetainFunc)dlsym(RTLD_DEFAULT, "WKRetain");
    wkRelease = (WKReleaseFunc)dlsym(RTLD_DEFAULT, "WKRelease");
}

static void did_create_page(WKBundleRef bundle, WKBundlePageRef page, const void *clientInfo)
{
    (void)bundle;
    (void)clientInfo;
    if (wkRetain && page) {
        if (injected_bundle_page && wkRelease)
            wkRelease(injected_bundle_page);
        injected_bundle_page = wkRetain(page);
    } else {
        injected_bundle_page = page;
    }
}

static void will_destroy_page(WKBundleRef bundle, WKBundlePageRef page, const void *clientInfo)
{
    (void)bundle;
    (void)clientInfo;
    if (page != injected_bundle_page)
        return;
    if (wkRelease && injected_bundle_page)
        wkRelease(injected_bundle_page);
    injected_bundle_page = NULL;
}

__attribute__((used, visibility("default")))
void WKBundleInitialize(WKBundleRef bundle, WKTypeRef userData)
{
    (void)userData;
    injected_bundle = bundle;
    resolve_bundle_symbols();
    if (wkRetain && bundle)
        wkRetain(bundle);
    if (wkBundleSetClient) {
        static WKBundleClientV0 client;
        client.base.version = 0;
        client.base.clientInfo = NULL;
        client.didCreatePage = did_create_page;
        client.willDestroyPage = will_destroy_page;
        client.didInitializePageGroup = NULL;
        client.didReceiveMessage = NULL;
        wkBundleSetClient(bundle, &client);
    }
    MiniBrowserInjectedBundleLog("WKBundleInitialize");
    MiniBrowserInjectedBundleInstallHooks();
}

void MiniBrowserInjectedBundleSendRemoteLog(const char *message)
{
    if (!message || !message[0])
        return;
    if (!injected_bundle_page)
        return;
    resolve_bundle_symbols();
    if (!wkStringCreateWithUTF8CString || !wkBundlePagePostMessage)
        return;

    WKStringRef name = wkStringCreateWithUTF8CString("MiniBrowserInjectedBundleLog");
    WKStringRef body = wkStringCreateWithUTF8CString(message);
    if (name && body)
        wkBundlePagePostMessage(injected_bundle_page, name, body);
    if (wkRelease) {
        if (name)
            wkRelease(name);
        if (body)
            wkRelease(body);
    }
}

typedef Class (*ObjCGetClassFunc)(const char *);
typedef SEL (*SelGetUidFunc)(const char *);
typedef Method (*ClassGetClassMethodFunc)(Class, SEL);
typedef IMP (*MethodGetImplementationFunc)(Method);
typedef IMP (*MethodSetImplementationFunc)(Method, IMP);

struct objc_runtime_functions {
    ObjCGetClassFunc objc_getClass;
    SelGetUidFunc sel_getUid;
    ClassGetClassMethodFunc class_getClassMethod;
    MethodGetImplementationFunc method_getImplementation;
    MethodSetImplementationFunc method_setImplementation;
    void *objc_msgSend;
};

static struct objc_runtime_functions objc_runtime;
static bool did_log_missing_objc_runtime;

static bool resolve_objc_runtime(void)
{
    if (objc_runtime.objc_getClass)
        return true;

    objc_runtime.objc_getClass = (ObjCGetClassFunc)dlsym(RTLD_DEFAULT, "objc_getClass");
    objc_runtime.sel_getUid = (SelGetUidFunc)dlsym(RTLD_DEFAULT, "sel_getUid");
    objc_runtime.class_getClassMethod = (ClassGetClassMethodFunc)dlsym(RTLD_DEFAULT, "class_getClassMethod");
    objc_runtime.method_getImplementation = (MethodGetImplementationFunc)dlsym(RTLD_DEFAULT, "method_getImplementation");
    objc_runtime.method_setImplementation = (MethodSetImplementationFunc)dlsym(RTLD_DEFAULT, "method_setImplementation");
    objc_runtime.objc_msgSend = dlsym(RTLD_DEFAULT, "objc_msgSend");

    if (!objc_runtime.objc_getClass || !objc_runtime.sel_getUid || !objc_runtime.class_getClassMethod
        || !objc_runtime.method_getImplementation || !objc_runtime.method_setImplementation || !objc_runtime.objc_msgSend) {
        if (!did_log_missing_objc_runtime) {
            did_log_missing_objc_runtime = true;
            log_line_always("objc runtime symbols unavailable");
        }
        return false;
    }

    return true;
}

static bool should_enable_feature_hook(void)
{
    const char *value = getenv("MINIBROWSER_ENABLE_FEATURE_HOOK");
    if (!value || !value[0])
        return true;
    return value[0] == '1';
}

static bool should_override_system_blue(void)
{
    const char *value = getenv("MINIBROWSER_SYSTEM_BLUE_OVERRIDE");
    if (!value || !value[0])
        return true;
    return !(value[0] == '0' || value[0] == 'N' || value[0] == 'n');
}

typedef id (*ObjCMsgSendColorFunc)(id, SEL, double, double, double, double);

static id (*original_system_blue_color)(id, SEL);
static bool did_install_system_blue_swizzle;
static bool did_log_system_blue_call;
static bool did_log_system_blue_override;

static id make_rgba_color(double red, double green, double blue, double alpha)
{
    if (!resolve_objc_runtime())
        return nil;
    Class uiColorClass = objc_runtime.objc_getClass("UIColor");
    if (!uiColorClass)
        return nil;
    SEL selector = objc_runtime.sel_getUid("colorWithRed:green:blue:alpha:");
    if (!selector)
        return nil;
    ObjCMsgSendColorFunc msgSend = (ObjCMsgSendColorFunc)objc_runtime.objc_msgSend;
    return msgSend(uiColorClass, selector, red, green, blue, alpha);
}

static id replacement_systemBlueColor(id self, SEL _cmd)
{
    if (!did_log_system_blue_call) {
        did_log_system_blue_call = true;
        log_line_always("UIColor systemBlueColor called");
    }

    if (!original_system_blue_color)
        return nil;

    if (!should_override_system_blue())
        return original_system_blue_color(self, _cmd);

    id override = make_rgba_color(1.0, 0.5529411765, 0.1568627451, 1.0);
    if (override) {
        if (!did_log_system_blue_override) {
            did_log_system_blue_override = true;
            log_line_always("UIColor systemBlueColor overridden");
        }
        return override;
    }

    return original_system_blue_color(self, _cmd);
}

static void install_system_blue_swizzle(void)
{
    if (did_install_system_blue_swizzle)
        return;
    if (!resolve_objc_runtime())
        return;

    Class uiColorClass = objc_runtime.objc_getClass("UIColor");
    if (!uiColorClass) {
        log_line_if_enabled("UIColor not available yet");
        return;
    }

    SEL selector = objc_runtime.sel_getUid("systemBlueColor");
    Method method = objc_runtime.class_getClassMethod(uiColorClass, selector);
    if (!method) {
        log_line_always("UIColor systemBlueColor method not found");
        return;
    }

    original_system_blue_color = (id (*)(id, SEL))objc_runtime.method_getImplementation(method);
    objc_runtime.method_setImplementation(method, (IMP)replacement_systemBlueColor);
    did_install_system_blue_swizzle = true;
    log_line_always("swizzled UIColor systemBlueColor");
}

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_COMMAND LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_COMMAND LC_SEGMENT
#endif

static int prepend_rebindings(struct rebindings_entry **head, struct rebinding rebindings[], size_t nel)
{
    struct rebindings_entry *entry = (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
    if (!entry)
        return -1;
    entry->rebindings = (struct rebinding *)malloc(sizeof(struct rebinding) * nel);
    if (!entry->rebindings) {
        free(entry);
        return -1;
    }
    memcpy(entry->rebindings, rebindings, sizeof(struct rebinding) * nel);
    entry->rebindings_nel = nel;
    entry->next = *head;
    *head = entry;
    return 0;
}

static void perform_rebinding_with_section(struct rebindings_entry *rebindings, section_t *section, intptr_t slide, nlist_t *symtab, char *strtab, uint32_t *indirect_symtab, bool make_writable)
{
    uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
    void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);
    uint32_t count = (uint32_t)(section->size / sizeof(void *));
    bool did_make_writable = false;

    for (uint32_t i = 0; i < count; i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL || symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS))
            continue;

        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        if (!strtab_offset)
            continue;

        char *symbol_name = strtab + strtab_offset;
        if (symbol_name[0] != '_')
            continue;

        struct rebindings_entry *cur = rebindings;
        while (cur) {
            for (size_t j = 0; j < cur->rebindings_nel; j++) {
                if (strcmp(&symbol_name[1], cur->rebindings[j].name) == 0) {
                    if (make_writable && !did_make_writable) {
                        if (!set_memory_protection(indirect_symbol_bindings, section->size, VM_PROT_READ | VM_PROT_WRITE)) {
                            log_line_if_enabled("failed to make symbol pointers writable");
                            return;
                        }
                        did_make_writable = true;
                    }
                    if (cur->rebindings[j].replaced && !*cur->rebindings[j].replaced)
                        *cur->rebindings[j].replaced = indirect_symbol_bindings[i];
                    if (!did_log_rebind_feature_impl && strcmp(cur->rebindings[j].name, "_os_feature_enabled_impl") == 0) {
                        did_log_rebind_feature_impl = true;
                        log_format_if_enabled("rebound %s: %p -> %p", symbol_name, indirect_symbol_bindings[i], cur->rebindings[j].replacement);
                    }
                    if (!did_log_rebind_feature_simple_impl && strcmp(cur->rebindings[j].name, "_os_feature_enabled_simple_impl") == 0) {
                        did_log_rebind_feature_simple_impl = true;
                        log_format_if_enabled("rebound %s: %p -> %p", symbol_name, indirect_symbol_bindings[i], cur->rebindings[j].replacement);
                    }
                    indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
                    goto symbol_bound;
                }
            }
            cur = cur->next;
        }
symbol_bound:
        ;
    }

    if (make_writable && did_make_writable)
        set_memory_protection(indirect_symbol_bindings, section->size, VM_PROT_READ);
}

static section_t *find_section(const struct mach_header *header, const char *segment, const char *section)
{
#ifdef __LP64__
    if (header->magic != MH_MAGIC_64 && header->magic != MH_CIGAM_64)
        return NULL;
    return (section_t *)getsectbynamefromheader_64((const struct mach_header_64 *)header, segment, section);
#else
    if (header->magic != MH_MAGIC && header->magic != MH_CIGAM)
        return NULL;
    return (section_t *)getsectbynamefromheader((const struct mach_header *)header, segment, section);
#endif
}

static void rebind_symbols_for_image(const struct mach_header *header, intptr_t slide)
{
    segment_command_t *cur_seg_cmd;
    segment_command_t *linkedit_segment = NULL;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_COMMAND) {
            if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0)
                linkedit_segment = cur_seg_cmd;
        } else if (cur_seg_cmd->cmd == LC_SYMTAB)
            symtab_cmd = (struct symtab_command *)cur_seg_cmd;
        else if (cur_seg_cmd->cmd == LC_DYSYMTAB)
            dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
    }

    if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment)
        return;

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    section_t *section = find_section(header, SEG_DATA, SECT_LAZY_SYMBOL_POINTERS);
    if (section)
        perform_rebinding_with_section(rebindings_head, section, slide, symtab, strtab, indirect_symtab, false);
    section = find_section(header, SEG_DATA, SECT_NON_LAZY_SYMBOL_POINTERS);
    if (section)
        perform_rebinding_with_section(rebindings_head, section, slide, symtab, strtab, indirect_symtab, false);
    section = find_section(header, SEG_DATA, SECT_GOT);
    if (section)
        perform_rebinding_with_section(rebindings_head, section, slide, symtab, strtab, indirect_symtab, false);

    section = find_section(header, SEG_DATA_CONST, SECT_LAZY_SYMBOL_POINTERS);
    if (section)
        perform_rebinding_with_section(rebindings_head, section, slide, symtab, strtab, indirect_symtab, true);
    section = find_section(header, SEG_DATA_CONST, SECT_NON_LAZY_SYMBOL_POINTERS);
    if (section)
        perform_rebinding_with_section(rebindings_head, section, slide, symtab, strtab, indirect_symtab, true);
    section = find_section(header, SEG_DATA_CONST, SECT_GOT);
    if (section)
        perform_rebinding_with_section(rebindings_head, section, slide, symtab, strtab, indirect_symtab, true);

    section = find_section(header, SEG_AUTH_CONST, SECT_GOT);
    if (section)
        perform_rebinding_with_section(rebindings_head, section, slide, symtab, strtab, indirect_symtab, true);
}

static int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel)
{
    int retval = prepend_rebindings(&rebindings_head, rebindings, rebindings_nel);
    if (retval < 0)
        return retval;

    if (!rebindings_head->next)
        _dyld_register_func_for_add_image(rebind_symbols_for_image);

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++)
        rebind_symbols_for_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    return 0;
}

static bool set_memory_protection(void *address, size_t size, vm_prot_t protection)
{
    size_t page_size = (size_t)getpagesize();
    uintptr_t page_start = (uintptr_t)address & ~(page_size - 1);
    uintptr_t page_end = ((uintptr_t)address + size + page_size - 1) & ~(page_size - 1);
    vm_size_t length = (vm_size_t)(page_end - page_start);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page_start, length, false, protection);
    if (kr != KERN_SUCCESS) {
        log_format_if_enabled("vm_protect failed: %d", kr);
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
        log_line_if_enabled("adrp immediate out of range");
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
    log_line_if_enabled("inline hook unsupported on this architecture");
    return false;
#endif
}

static void *install_inline_hook(void *target, void *replacement)
{
    if (!target || !replacement)
        return NULL;

    const size_t patch_size = 16;
    uint8_t original[patch_size];
    memcpy(original, target, patch_size);

    void *trampoline = mmap(NULL, patch_size + 16, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (trampoline == MAP_FAILED) {
        log_line_if_enabled("mmap failed for trampoline");
        return NULL;
    }
    memcpy(trampoline, original, patch_size);
    if (!write_absolute_jump((uint8_t *)trampoline + patch_size, (uint8_t *)target + patch_size)) {
        log_line_if_enabled("failed to write trampoline jump");
        return NULL;
    }

    if (!set_memory_protection(target, patch_size, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE))
        return NULL;
    if (!write_absolute_jump(target, replacement)) {
        log_line_if_enabled("failed to write target jump");
        return NULL;
    }
    flush_instruction_cache(target, patch_size);
    set_memory_protection(target, patch_size, VM_PROT_READ | VM_PROT_EXECUTE);
    flush_instruction_cache(trampoline, patch_size + 16);
    return trampoline;
}

static bool (*original_os_feature_enabled_impl)(const char *domain, const char *feature);
static bool (*original_os_feature_enabled_simple_impl)(const char *domain, const char *feature);
static bool did_log_feature;
static bool did_log_first_call;
static bool did_install_hooks;

static bool replacement_os_feature_enabled_impl(const char *domain, const char *feature)
{
    if (!did_log_first_call) {
        did_log_first_call = true;
        log_format_if_enabled("replacement _os_feature_enabled_impl called domain=%s feature=%s", domain ? domain : "(null)", feature ? feature : "(null)");
    }
    if (domain && feature && strcmp(domain, "UIKit") == 0 && strcmp(feature, "redesigned_text_cursor") == 0) {
        if (!did_log_feature) {
            did_log_feature = true;
        log_line_if_enabled("hooked os_feature_enabled for UIKit/redesigned_text_cursor -> false");
        }
        return false;
    }

    if (original_os_feature_enabled_impl)
        return original_os_feature_enabled_impl(domain, feature);

    if (original_os_feature_enabled_simple_impl)
        return original_os_feature_enabled_simple_impl(domain, feature);

    return true;
}

static void install_hooks(void)
{
    if (did_install_hooks)
        return;
    did_install_hooks = true;
    log_line_always("install_hooks begin");
    if (!should_enable_feature_hook()) {
        log_line_if_enabled("feature flag hook disabled; skipping os_feature_enabled_impl hook");
        return;
    }

    const char *featureflags_path = "/usr/lib/system/libsystem_featureflags.dylib";
    void *featureflags_handle = dlopen(featureflags_path, RTLD_NOW | RTLD_GLOBAL);
    if (featureflags_handle)
        log_format_if_enabled("dlopen %s handle=%p", featureflags_path, featureflags_handle);
    else
        log_format_if_enabled("dlopen %s failed: %s", featureflags_path, dlerror());

    struct rebinding rebindings[] = {
        { "_os_feature_enabled_impl", (void *)replacement_os_feature_enabled_impl, (void **)&original_os_feature_enabled_impl },
        { "_os_feature_enabled_simple_impl", (void *)replacement_os_feature_enabled_impl, (void **)&original_os_feature_enabled_simple_impl },
    };
    const char *impl_names[] = { "_os_feature_enabled_impl", "__os_feature_enabled_impl", "os_feature_enabled_impl" };
    const char *simple_names[] = { "_os_feature_enabled_simple_impl", "__os_feature_enabled_simple_impl", "os_feature_enabled_simple_impl" };
    void *target = NULL;
    void *simple_target = NULL;
    for (size_t i = 0; i < sizeof(impl_names) / sizeof(impl_names[0]); i++) {
        void *candidate = dlsym(featureflags_handle ? featureflags_handle : RTLD_DEFAULT, impl_names[i]);
        log_format_if_enabled("dlsym %s=%p", impl_names[i], candidate);
        if (!target && candidate)
            target = candidate;
    }
    for (size_t i = 0; i < sizeof(simple_names) / sizeof(simple_names[0]); i++) {
        void *candidate = dlsym(featureflags_handle ? featureflags_handle : RTLD_DEFAULT, simple_names[i]);
        log_format_if_enabled("dlsym %s=%p", simple_names[i], candidate);
        if (!simple_target && candidate)
            simple_target = candidate;
    }
    int result = rebind_symbols(rebindings, 2);
    log_format_if_enabled("rebind_symbols result=%d original_impl=%p simple_impl=%p", result, (void *)original_os_feature_enabled_impl, (void *)original_os_feature_enabled_simple_impl);
    if (!original_os_feature_enabled_impl && target) {
        void *trampoline = install_inline_hook(target, (void *)replacement_os_feature_enabled_impl);
        if (trampoline) {
            original_os_feature_enabled_impl = trampoline;
            log_line_always("inline hook installed");
        } else {
            log_line_always("inline hook failed");
        }
    }
}

void MiniBrowserInjectedBundleLog(const char *message)
{
    log_line_always(message);
}

void MiniBrowserInjectedBundleInstallHooks(void)
{
    install_system_blue_swizzle();
    install_hooks();
}
