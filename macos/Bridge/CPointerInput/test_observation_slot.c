#include "mmf_observation_slot.h"

#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

static struct timespec deadline_after_seconds(time_t seconds) {
    struct timespec deadline;
    assert(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_sec += seconds;
    return deadline;
}

static void publish(mmf_observation_slot *slot, uintptr_t token, uint64_t epoch) {
    mmf_observation_slot_publish(slot, token, (double)token, (double)(token + 1), token,
        token + 100, epoch);
}

static void assert_reserved(mmf_observation_slot *slot, uintptr_t token, uint64_t epoch) {
    assert(mmf_observation_slot_reserve(slot, epoch, (double)token, (double)(token + 1), token + 1));
    assert(atomic_load_explicit(&slot->payload, memory_order_relaxed) == token);
    assert(slot->point_x == (double)token);
    assert(slot->point_y == (double)(token + 1));
    assert(slot->sampled_ns == token);
    assert(slot->expires_ns == token + 100);
}

typedef struct {
    mmf_observation_slot *slot;
    uintptr_t retired;
    bool prepared;
} prepare_once;

static void *prepare_slot(void *argument) {
    prepare_once *test = argument;
    test->prepared = mmf_observation_slot_prepare(test->slot, &test->retired);
    return NULL;
}

typedef struct {
    mmf_observation_slot *slot;
    uintptr_t token;
    pthread_mutex_t lock;
    pthread_cond_t condition;
    bool prepared;
    bool completed;
    bool release;
    uintptr_t retired;
} held_prepare;

static void *hold_preparing(void *argument) {
    held_prepare *test = argument;
    bool prepared = mmf_observation_slot_prepare(test->slot, &test->retired);
    pthread_mutex_lock(&test->lock);
    test->prepared = prepared;
    test->completed = true;
    pthread_cond_signal(&test->condition);
    struct timespec deadline = deadline_after_seconds(2);
    while (!test->release) {
        assert(pthread_cond_timedwait(&test->condition, &test->lock, &deadline) == 0);
    }
    pthread_mutex_unlock(&test->lock);
    if (prepared) publish(test->slot, test->token, 7);
    return NULL;
}

typedef struct {
    mmf_observation_slot *slot;
    pthread_mutex_t lock;
    pthread_cond_t condition;
    bool ready;
    bool release;
    bool worker_won;
    bool worker_done;
    bool reserve_won;
    bool reserve_done;
    uintptr_t retired;
} simultaneous_race;

static void *race_prepare(void *argument) {
    simultaneous_race *test = argument;
    pthread_mutex_lock(&test->lock);
    test->ready = true;
    pthread_cond_signal(&test->condition);
    struct timespec deadline = deadline_after_seconds(2);
    while (!test->release) {
        assert(pthread_cond_timedwait(&test->condition, &test->lock, &deadline) == 0);
    }
    pthread_mutex_unlock(&test->lock);
    uintptr_t retired = 0;
    bool won = mmf_observation_slot_prepare(test->slot, &retired);
    pthread_mutex_lock(&test->lock);
    test->worker_won = won;
    test->worker_done = true;
    test->retired = retired;
    pthread_cond_signal(&test->condition);
    struct timespec reserve_deadline = deadline_after_seconds(2);
    while (won && !test->reserve_done) {
        assert(pthread_cond_timedwait(&test->condition, &test->lock, &reserve_deadline) == 0);
    }
    pthread_mutex_unlock(&test->lock);
    if (won) publish(test->slot, 40, 7);
    return NULL;
}

static void *race_reserve(void *argument) {
    simultaneous_race *test = argument;
    pthread_mutex_lock(&test->lock);
    struct timespec deadline = deadline_after_seconds(2);
    while (!test->ready) {
        assert(pthread_cond_timedwait(&test->condition, &test->lock, &deadline) == 0);
    }
    test->release = true;
    assert(pthread_cond_signal(&test->condition) == 0);
    pthread_mutex_unlock(&test->lock);
    bool won = mmf_observation_slot_reserve(test->slot, 7, 30, 31, 31);
    if (won) {
        assert(atomic_load_explicit(&test->slot->payload, memory_order_relaxed) == 30);
        assert(test->slot->point_x == 30 && test->slot->point_y == 31);
        assert(test->slot->sampled_ns == 30 && test->slot->expires_ns == 130);
    }
    pthread_mutex_lock(&test->lock);
    struct timespec worker_deadline = deadline_after_seconds(2);
    while (!test->worker_done) {
        assert(pthread_cond_timedwait(&test->condition, &test->lock, &worker_deadline) == 0);
    }
    test->reserve_won = won;
    test->reserve_done = true;
    pthread_cond_signal(&test->condition);
    pthread_mutex_unlock(&test->lock);
    if (won) assert(mmf_observation_slot_abort_reservation(test->slot));
    return NULL;
}

int main(void) {
    mmf_observation_slot *slot = mmf_observation_slot_create();
    assert(slot && mmf_observation_slot_lock_free(slot));
    mmf_observation_slot_enable_admissions(slot, 7);

    // A reservation owns plain fields, so concurrent worker replacement must fail.
    uintptr_t retired = 0;
    assert(mmf_observation_slot_prepare(slot, &retired));
    assert(retired == 0);
    publish(slot, 10, 7);
    assert_reserved(slot, 10, 7);
    prepare_once blocked = { .slot = slot };
    pthread_t worker;
    assert(pthread_create(&worker, NULL, prepare_slot, &blocked) == 0);
    assert(pthread_join(worker, NULL) == 0);
    assert(!blocked.prepared);
    assert(mmf_observation_slot_abort_reservation(slot));
    assert(mmf_observation_slot_prepare(slot, &retired));
    assert(retired == 10);
    mmf_observation_slot_empty(slot);

    // Fresh Eligible rejections must remain fail-open for wrong point, expiry, and epoch.
    assert(mmf_observation_slot_prepare(slot, &retired));
    assert(retired == 0);
    publish(slot, 15, 7);
    assert(!mmf_observation_slot_reserve(slot, 7, 16, 16, 16));
    assert(mmf_observation_slot_state(slot) == MMF_OBSERVATION_EMPTY);
    assert(mmf_observation_slot_prepare(slot, &retired));
    assert(retired == 15);
    publish(slot, 16, 7);
    assert(!mmf_observation_slot_reserve(slot, 7, 16, 17, 117));
    assert(mmf_observation_slot_state(slot) == MMF_OBSERVATION_EMPTY);
    assert(mmf_observation_slot_prepare(slot, &retired));
    assert(retired == 16);
    publish(slot, 17, 7);
    assert(!mmf_observation_slot_reserve(slot, 8, 17, 18, 18));
    assert(mmf_observation_slot_state(slot) == MMF_OBSERVATION_EMPTY);
    assert(mmf_observation_slot_prepare(slot, &retired));
    assert(retired == 17);
    mmf_observation_slot_empty(slot);

    // A worker-owned Preparing state excludes reservation until publication is complete.
    held_prepare held = { .slot = slot, .token = 20, .lock = PTHREAD_MUTEX_INITIALIZER, .condition = PTHREAD_COND_INITIALIZER };
    pthread_mutex_lock(&held.lock);
    assert(pthread_create(&worker, NULL, hold_preparing, &held) == 0);
    struct timespec held_deadline = deadline_after_seconds(2);
    while (!held.completed) {
        assert(pthread_cond_timedwait(&held.condition, &held.lock, &held_deadline) == 0);
    }
    assert(held.prepared && held.retired == 0);
    pthread_mutex_unlock(&held.lock);
    assert(!mmf_observation_slot_reserve(slot, 7, 20, 21, 21));
    pthread_mutex_lock(&held.lock);
    held.release = true;
    assert(pthread_cond_signal(&held.condition) == 0);
    pthread_mutex_unlock(&held.lock);
    assert(pthread_join(worker, NULL) == 0);
    assert_reserved(slot, 20, 7);
    assert(mmf_observation_slot_abort_reservation(slot));
    assert(mmf_observation_slot_prepare(slot, &retired));
    assert(retired == 20);
    mmf_observation_slot_empty(slot);

    // Exactly one simultaneous ownership claim wins; the winner determines safe field access.
    assert(mmf_observation_slot_prepare(slot, &retired));
    assert(retired == 0);
    publish(slot, 30, 7);
    simultaneous_race race = {
        .slot = slot,
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .condition = PTHREAD_COND_INITIALIZER,
    };
    pthread_t replacement, reservation;
    assert(pthread_create(&replacement, NULL, race_prepare, &race) == 0);
    pthread_mutex_lock(&race.lock);
    struct timespec race_deadline = deadline_after_seconds(2);
    while (!race.ready) {
        assert(pthread_cond_timedwait(&race.condition, &race.lock, &race_deadline) == 0);
    }
    pthread_mutex_unlock(&race.lock);
    assert(pthread_create(&reservation, NULL, race_reserve, &race) == 0);
    assert(pthread_join(replacement, NULL) == 0);
    assert(pthread_join(reservation, NULL) == 0);
    assert(race.worker_won != race.reserve_won);
    if (race.worker_won) {
        assert(race.retired == 30);
        assert_reserved(slot, 40, 7);
        assert(mmf_observation_slot_abort_reservation(slot));
        assert(mmf_observation_slot_prepare(slot, &retired));
        assert(retired == 40);
    } else {
        assert(mmf_observation_slot_prepare(slot, &retired));
        assert(retired == 30);
    }
    mmf_observation_slot_empty(slot);

    mmf_observation_slot_disable_admissions(slot, 8);
    mmf_observation_slot_destroy(slot);
    return 0;
}
