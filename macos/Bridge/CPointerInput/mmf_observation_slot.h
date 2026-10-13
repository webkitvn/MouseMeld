#ifndef MMF_OBSERVATION_SLOT_H
#define MMF_OBSERVATION_SLOT_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <libproc.h>
#include <sys/proc.h>
#include <sys/proc_info.h>

typedef struct mmf_observation_slot {
    _Atomic uint32_t state;
    _Atomic bool admissions_enabled;
    _Atomic uint64_t epoch;
    _Atomic uintptr_t payload;
    double point_x;
    double point_y;
    uint64_t sampled_ns;
    uint64_t expires_ns;
} mmf_observation_slot;

typedef struct mmf_process_witness {
    uint32_t pid;
    uint64_t start_seconds;
    uint64_t start_microseconds;
} mmf_process_witness;

static inline bool mmf_process_witness_current(pid_t pid, mmf_process_witness *out) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
        || info.pbi_pid != (uint32_t)pid
        || (info.pbi_status != SRUN && info.pbi_status != SSLEEP && info.pbi_status != SSTOP)
        || (info.pbi_flags & PROC_FLAG_INEXIT) != 0) return false;
    *out = (mmf_process_witness){ .pid = info.pbi_pid, .start_seconds = info.pbi_start_tvsec,
        .start_microseconds = info.pbi_start_tvusec };
    return true;
}

enum mmf_observation_state {
    MMF_OBSERVATION_EMPTY = 0,
    MMF_OBSERVATION_PREPARING = 1,
    MMF_OBSERVATION_ELIGIBLE = 2,
    MMF_OBSERVATION_RESERVED = 3,
    MMF_OBSERVATION_READY = 4,
    MMF_OBSERVATION_EXECUTING = 5,
};

static inline mmf_observation_slot *mmf_observation_slot_create(void) {
    mmf_observation_slot *slot = calloc(1, sizeof(*slot));
    if (!slot) return NULL;
    atomic_init(&slot->state, MMF_OBSERVATION_EMPTY);
    atomic_init(&slot->admissions_enabled, false);
    atomic_init(&slot->epoch, 0);
    atomic_init(&slot->payload, 0);
    return slot;
}

static inline void mmf_observation_slot_destroy(mmf_observation_slot *slot) {
    free(slot);
}

static inline bool mmf_observation_slot_lock_free(const mmf_observation_slot *slot) {
    return atomic_is_lock_free(&slot->state)
        && atomic_is_lock_free(&slot->admissions_enabled)
        && atomic_is_lock_free(&slot->epoch)
        && atomic_is_lock_free(&slot->payload);
}

static inline void mmf_observation_slot_enable_admissions(mmf_observation_slot *slot, uint64_t epoch) {
    atomic_store_explicit(&slot->epoch, epoch, memory_order_release);
    atomic_store_explicit(&slot->admissions_enabled, true, memory_order_release);
}

static inline void mmf_observation_slot_disable_admissions(mmf_observation_slot *slot, uint64_t epoch) {
    atomic_store_explicit(&slot->admissions_enabled, false, memory_order_release);
    atomic_store_explicit(&slot->epoch, epoch, memory_order_release);
}

/* Only the worker may call this. It claims Empty or Eligible before touching payload. */
static inline bool mmf_observation_slot_prepare(mmf_observation_slot *slot, uintptr_t *old_payload) {
    uint32_t expected = MMF_OBSERVATION_EMPTY;
    if (!atomic_compare_exchange_strong_explicit(&slot->state, &expected, MMF_OBSERVATION_PREPARING,
            memory_order_acq_rel, memory_order_acquire)) {
        if (expected != MMF_OBSERVATION_ELIGIBLE ||
            !atomic_compare_exchange_strong_explicit(&slot->state, &expected, MMF_OBSERVATION_PREPARING,
                memory_order_acq_rel, memory_order_acquire)) return false;
    }
    *old_payload = atomic_exchange_explicit(&slot->payload, 0, memory_order_acq_rel);
    return true;
}

/* Only the worker may call this while it owns Preparing. */
static inline void mmf_observation_slot_publish(mmf_observation_slot *slot, uintptr_t payload,
        double point_x, double point_y, uint64_t sampled_ns, uint64_t expires_ns, uint64_t epoch) {
    slot->point_x = point_x;
    slot->point_y = point_y;
    slot->sampled_ns = sampled_ns;
    slot->expires_ns = expires_ns;
    atomic_store_explicit(&slot->epoch, epoch, memory_order_relaxed);
    atomic_store_explicit(&slot->payload, payload, memory_order_relaxed);
    atomic_store_explicit(&slot->state, MMF_OBSERVATION_ELIGIBLE, memory_order_release);
}

/* Only the worker may call this while it owns Preparing. */
static inline void mmf_observation_slot_empty(mmf_observation_slot *slot) {
    atomic_store_explicit(&slot->state, MMF_OBSERVATION_EMPTY, memory_order_release);
}

/* Callback ownership begins only after this succeeds. No payload is exposed to it. */
static inline bool mmf_observation_slot_reserve(mmf_observation_slot *slot, uint64_t epoch,
        double point_x, double point_y, uint64_t now_ns) {
    if (!atomic_load_explicit(&slot->admissions_enabled, memory_order_acquire)) return false;
    uint32_t expected = MMF_OBSERVATION_ELIGIBLE;
    if (!atomic_compare_exchange_strong_explicit(&slot->state, &expected, MMF_OBSERVATION_RESERVED,
            memory_order_acq_rel, memory_order_acquire)) return false;
    bool valid = atomic_load_explicit(&slot->admissions_enabled, memory_order_acquire)
        && atomic_load_explicit(&slot->epoch, memory_order_acquire) == epoch
        && slot->point_x == point_x && slot->point_y == point_y
        && now_ns >= slot->sampled_ns && now_ns <= slot->expires_ns;
    if (!valid) atomic_store_explicit(&slot->state, MMF_OBSERVATION_EMPTY, memory_order_release);
    return valid;
}

/* Callback may abandon only its own reservation. Retention remains worker-owned. */
static inline bool mmf_observation_slot_abort_reservation(mmf_observation_slot *slot) {
    uint32_t expected = MMF_OBSERVATION_RESERVED;
    return atomic_compare_exchange_strong_explicit(&slot->state, &expected, MMF_OBSERVATION_EMPTY,
        memory_order_release, memory_order_relaxed);
}

static inline uint32_t mmf_observation_slot_state(const mmf_observation_slot *slot) {
    return atomic_load_explicit(&slot->state, memory_order_acquire);
}

#endif
