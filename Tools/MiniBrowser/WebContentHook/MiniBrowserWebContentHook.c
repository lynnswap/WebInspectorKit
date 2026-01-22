#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <os/log.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern bool _os_feature_enabled_impl(const char *domain, const char *feature);

static int log_fd = -1;
static bool did_log_first_call;
static bool (*original_os_feature_enabled_impl)(const char *domain, const char *feature);

static const char *log_path(void)
{
    static char path[PATH_MAX];
    if (path[0])
        return path;
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir || !tmpdir[0])
        tmpdir = "/tmp";
    size_t length = strlen(tmpdir);
    const char *separator = (length && tmpdir[length - 1] == '/') ? "" : "/";
    snprintf(path, sizeof(path), "%s%sMiniBrowserWebContentHook.log", tmpdir, separator);
    return path;
}

static void log_line(const char *message)
{
    if (!message)
        return;
    if (log_fd < 0) {
        log_fd = open(log_path(), O_CREAT | O_APPEND | O_WRONLY, 0644);
        if (log_fd < 0)
            return;
    }
    char buffer[768];
    int length = snprintf(buffer, sizeof(buffer), "MiniBrowserWebContentHook: %s\n", message);
    if (length <= 0)
        return;
    if (length >= (int)sizeof(buffer))
        length = (int)sizeof(buffer) - 1;
    (void)write(log_fd, buffer, (size_t)length);
}

static bool replacement_os_feature_enabled_impl(const char *domain, const char *feature)
{
    if (!did_log_first_call) {
        did_log_first_call = true;
        char buffer[256];
        snprintf(buffer, sizeof(buffer), "first _os_feature_enabled_impl domain=%s feature=%s", domain ? domain : "(null)", feature ? feature : "(null)");
        log_line(buffer);
    }
    if (domain && feature && strcmp(domain, "UIKit") == 0 && strcmp(feature, "redesigned_text_cursor") == 0) {
        log_line("forced redesigned_text_cursor -> false");
        return false;
    }
    if (original_os_feature_enabled_impl)
        return original_os_feature_enabled_impl(domain, feature);
    return true;
}

__attribute__((constructor))
static void hook_initialize(void)
{
    log_line("MiniBrowserWebContentHook loaded");
    original_os_feature_enabled_impl = dlsym(RTLD_NEXT, "_os_feature_enabled_impl");
    char buffer[256];
    snprintf(buffer, sizeof(buffer), "dlsym _os_feature_enabled_impl=%p", (void *)original_os_feature_enabled_impl);
    log_line(buffer);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)replacement_os_feature_enabled_impl, (const void *)_os_feature_enabled_impl },
};
