// System-boundary fixture: returns genuine unposted CG/AX/AppKit objects; never posts input or queries Chrome.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CGEvent.h>
#import <libproc.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <sys/proc.h>
#import <sys/proc_info.h>

#include <assert.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static _Atomic unsigned location_reads;
static _Atomic unsigned role_reads;
static _Atomic unsigned proc_reads;
static _Atomic unsigned hit_pid_reads;
static _Atomic unsigned query_reads;
static _Atomic unsigned hold_claimed;
static _Atomic unsigned refresh_phase;
static pthread_t held_thread;
static _Atomic bool held_thread_set;
static _Thread_local uint64_t point_sample_lower_bound;
static _Thread_local bool point_sample_lower_bound_set;
static AXUIElementRef mismatch_hit;
static CFMachPortRef fixture_tap;
static _Atomic bool fixture_tap_enabled;

static bool enabled(void) { return getenv("MMF_TEST_CHROME_OBSERVATION") != NULL; }

static void marker(const char *name) {
    if (!name) return;
    int fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) close(fd);
}

static uint64_t monotonic_nanoseconds(void) {
    mach_timebase_info_data_t timebase;
    assert(mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom != 0);
    return (uint64_t)((__uint128_t)mach_absolute_time() * timebase.numer / timebase.denom);
}

static void timestamp_marker(const char *name, uint64_t value) {
    if (!name) return;
    char text[32];
    int length = snprintf(text, sizeof(text), "%llu\n", (unsigned long long)value);
    if (length <= 0 || (size_t)length >= sizeof(text)) return;
    int fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) {
        (void)write(fd, text, (size_t)length);
        close(fd);
    }
}

static void hold_query(void) {
    const char *arm = getenv("MMF_TEST_OBSERVATION_ARM");
    const char *warm = getenv("MMF_TEST_OBSERVATION_WARM");
    const char *started = getenv("MMF_TEST_OBSERVATION_QUERY_STARTED");
    const char *release = getenv("MMF_TEST_OBSERVATION_QUERY_RELEASE");
    const char *finished = getenv("MMF_TEST_OBSERVATION_QUERY_FINISHED");
    unsigned query = atomic_fetch_add_explicit(&query_reads, 1, memory_order_relaxed);
    bool hold_first = getenv("MMF_TEST_OBSERVATION_HOLD_FIRST") != NULL;
    if (query == 0) marker(warm);
    if (!arm || !started || !release || access(arm, F_OK) != 0 || (!hold_first && query == 0)) return;
    unsigned expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&hold_claimed, &expected, 1, memory_order_acq_rel, memory_order_acquire)) return;
    assert(point_sample_lower_bound_set);
    held_thread = pthread_self();
    atomic_store_explicit(&held_thread_set, true, memory_order_release);
    timestamp_marker(getenv("MMF_TEST_OBSERVATION_SAMPLE_LOWER_BOUND"), point_sample_lower_bound);
    marker(started);
    while (access(release, F_OK) != 0) usleep(1000);
    if (getenv("MMF_TEST_OBSERVATION_SLOW")) usleep(120000);
    marker(finished);
    atomic_store_explicit(&refresh_phase, 1, memory_order_release);
}

static CGPoint scripted_point(void) {
    const char *mode = getenv("MMF_TEST_OBSERVATION_POINT");
    unsigned read = atomic_fetch_add_explicit(&location_reads, 1, memory_order_relaxed);
    if (mode && strcmp(mode, "changed") == 0 && read > 0) return CGPointMake(101, 200);
    return CGPointMake(100, 200);
}

static AXUIElementRef observation_element(void) {
    return AXUIElementCreateApplication(getpid());
}

static AXUIElementRef fixture_system_wide(void) {
    return observation_element();
}

static AXError fixture_copy_at_position(AXUIElementRef application, float x, float y, AXUIElementRef *element) {
    (void)application; (void)x; (void)y;
    hold_query();
    AXUIElementRef result = observation_element();
    if (!result) return kAXErrorFailure;
    if (getenv("MMF_TEST_OBSERVATION_HIT_PID_MISMATCH")) {
        if (mismatch_hit) CFRelease(mismatch_hit);
        mismatch_hit = CFRetain(result);
    }
    *element = result;
    return kAXErrorSuccess;
}

static AXError fixture_copy_attribute(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value) {
    bool mismatched_hit = getenv("MMF_TEST_OBSERVATION_HIT_PID_MISMATCH") && mismatch_hit && CFEqual(element, mismatch_hit);
    if (CFEqual(attribute, kAXRoleAttribute)) {
        bool attribute_window = getenv("MMF_TEST_OBSERVATION_ATTRIBUTE_WINDOW") != NULL;
        bool initial = atomic_fetch_add_explicit(&role_reads, 1, memory_order_relaxed) % 2 == 0;
        *value = CFRetain((mismatched_hit || (attribute_window && initial)) ? kAXButtonRole : kAXWindowRole);
        return kAXErrorSuccess;
    }
    if ((getenv("MMF_TEST_OBSERVATION_ATTRIBUTE_WINDOW") || mismatched_hit) && CFEqual(attribute, kAXWindowAttribute)) {
        *value = AXUIElementCreateApplication(mismatched_hit ? getpid() + 1 : getpid());
        return *value ? kAXErrorSuccess : kAXErrorFailure;
    }
    (void)element;
    return kAXErrorAttributeUnsupported;
}

static AXError fixture_get_pid(AXUIElementRef element, pid_t *pid) {
    if (getenv("MMF_TEST_OBSERVATION_HIT_PID_MISMATCH") && mismatch_hit) {
        *pid = CFEqual(element, mismatch_hit) ? getpid() : getpid() + 1;
        return kAXErrorSuccess;
    }
    (void)element;
    atomic_fetch_add_explicit(&hit_pid_reads, 1, memory_order_relaxed);
    *pid = getpid();
    return kAXErrorSuccess;
}

static void fixture_receive(CFMachPortRef port, void *message, CFIndex size, void *info) {
    (void)port; (void)message; (void)size; (void)info;
}

static CFMachPortRef fixture_tap_create(CGEventTapLocation location, CGEventTapPlacement placement,
        CGEventTapOptions options, CGEventMask mask, CGEventTapCallBack callback, void *info) {
    (void)location; (void)placement; (void)options; (void)mask; (void)callback; (void)info;
    fixture_tap = CFMachPortCreate(NULL, fixture_receive, NULL, NULL);
    atomic_store_explicit(&fixture_tap_enabled, false, memory_order_release);
    return fixture_tap;
}

static void fixture_tap_enable(CFMachPortRef tap, bool enabled_value) {
    if (tap == fixture_tap) atomic_store_explicit(&fixture_tap_enabled, enabled_value, memory_order_release);
}

static bool fixture_tap_is_enabled(CFMachPortRef tap) {
    return tap == fixture_tap && atomic_load_explicit(&fixture_tap_enabled, memory_order_acquire);
}

static void fixture_tap_invalidate(CFMachPortRef tap) {
    CFMachPortInvalidate(tap);
    assert(!CFMachPortIsValid(tap));
    if (tap == fixture_tap) marker(getenv("MMF_TEST_OBSERVATION_TAP_INVALIDATED"));
}

static AXError fixture_timeout(AXUIElementRef element, float timeout) {
    (void)element; (void)timeout;
    return kAXErrorSuccess;
}

static CGEventRef fixture_event_create(CGEventSourceRef source) {
    (void)source;
    point_sample_lower_bound = monotonic_nanoseconds();
    point_sample_lower_bound_set = true;
    if (!atomic_load_explicit(&held_thread_set, memory_order_acquire) || !pthread_equal(pthread_self(), held_thread)) {
        return CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGPointMake(100, 200), kCGMouseButtonLeft);
    }
    unsigned phase = atomic_load_explicit(&refresh_phase, memory_order_acquire);
    if (phase == 1) {
        atomic_store_explicit(&refresh_phase, 2, memory_order_release);
    } else if (phase == 2) {
        atomic_store_explicit(&refresh_phase, 3, memory_order_release);
        marker(getenv("MMF_TEST_OBSERVATION_REFRESH_COMPLETED"));
        const char *next_release = getenv("MMF_TEST_OBSERVATION_NEXT_REFRESH_RELEASE");
        if (next_release) while (access(next_release, F_OK) != 0) usleep(1000);
    }
    return CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGPointMake(100, 200), kCGMouseButtonLeft);
}

static CGPoint fixture_location(CGEventRef event) {
    (void)event;
    return scripted_point();
}

static int fixture_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int size) {
    (void)arg;
    if (!enabled() || pid != getpid() || flavor != PROC_PIDTBSDINFO || size != (int)sizeof(struct proc_bsdinfo)) {
        return proc_pidinfo(pid, flavor, arg, buffer, size);
    }
    if (getenv("MMF_TEST_OBSERVATION_PROC_SHORT")) return size - 1;
    struct proc_bsdinfo *info = buffer;
    memset(info, 0, sizeof(*info));
    info->pbi_pid = getenv("MMF_TEST_OBSERVATION_PROC_PID_MISMATCH") ? (uint32_t)(pid + 1) : (uint32_t)pid;
    info->pbi_status = getenv("MMF_TEST_OBSERVATION_PROC_DEAD") ? SZOMB : SRUN;
    info->pbi_flags = getenv("MMF_TEST_OBSERVATION_PROC_EXITING") ? PROC_FLAG_INEXIT : 0;
    unsigned read = atomic_fetch_add_explicit(&proc_reads, 1, memory_order_relaxed);
    info->pbi_start_tvsec = getenv("MMF_TEST_OBSERVATION_PROC_REUSED") ? 123 + (read % 2) : 123;
    info->pbi_start_tvusec = 456;
    return size;
}

static id fixture_running_application(id self, SEL command, pid_t pid) {
    (void)self; (void)command; (void)pid;
    return [NSRunningApplication currentApplication];
}

static NSString *fixture_bundle_identifier(id self, SEL command) {
    (void)self; (void)command;
    return @"com.google.Chrome";
}

static BOOL fixture_terminated(id self, SEL command) {
    (void)self; (void)command;
    return NO;
}

static pid_t fixture_process_identifier(id self, SEL command) {
    (void)self; (void)command;
    return getpid();
}

static void replace_method(Class cls, SEL selector, IMP implementation) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method) method_setImplementation(method, implementation);
}

__attribute__((constructor)) static void install_observation_boundary(void) {
    if (!enabled()) return;
    Class running = [NSRunningApplication class];
    replace_method(object_getClass(running), @selector(runningApplicationWithProcessIdentifier:), (IMP)fixture_running_application);
    replace_method(running, @selector(bundleIdentifier), (IMP)fixture_bundle_identifier);
    replace_method(running, @selector(isTerminated), (IMP)fixture_terminated);
    replace_method(running, @selector(processIdentifier), (IMP)fixture_process_identifier);
}

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static const struct { const void *replacement; const void *original; } \
    binding_##original __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original }
INTERPOSE(fixture_system_wide, AXUIElementCreateSystemWide);
INTERPOSE(fixture_copy_at_position, AXUIElementCopyElementAtPosition);
INTERPOSE(fixture_copy_attribute, AXUIElementCopyAttributeValue);
INTERPOSE(fixture_get_pid, AXUIElementGetPid);
INTERPOSE(fixture_timeout, AXUIElementSetMessagingTimeout);
INTERPOSE(fixture_tap_create, CGEventTapCreate);
INTERPOSE(fixture_tap_enable, CGEventTapEnable);
INTERPOSE(fixture_tap_is_enabled, CGEventTapIsEnabled);
INTERPOSE(fixture_tap_invalidate, CFMachPortInvalidate);
INTERPOSE(fixture_event_create, CGEventCreate);
INTERPOSE(fixture_location, CGEventGetLocation);
INTERPOSE(fixture_pidinfo, proc_pidinfo);
