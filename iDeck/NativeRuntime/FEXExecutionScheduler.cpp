#include "NativePerformance.h"

#include <condition_variable>
#include <deque>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

struct IDeckExecutionScheduler {
    struct Work {
        IDeckNativeTask callback;
        void *context;
    };

    explicit IDeckExecutionScheduler(size_t capacity) : capacity(capacity) {}

    size_t capacity;
    std::mutex mutex;
    std::condition_variable ready;
    std::condition_variable idle;
    std::deque<Work> queue;
    std::vector<std::thread> workers;
    size_t active = 0;
    bool stopping = false;
};

static void ideck_scheduler_worker(IDeckExecutionScheduler *scheduler) {
    for (;;) {
        IDeckExecutionScheduler::Work work{};
        {
            std::unique_lock<std::mutex> lock(scheduler->mutex);
            scheduler->ready.wait(lock, [scheduler] {
                return scheduler->stopping || !scheduler->queue.empty();
            });
            if (scheduler->queue.empty()) {
                if (scheduler->stopping) return;
                continue;
            }
            work = scheduler->queue.front();
            scheduler->queue.pop_front();
            ++scheduler->active;
        }
        try {
            work.callback(work.context);
        } catch (...) {
        }
        {
            std::lock_guard<std::mutex> lock(scheduler->mutex);
            --scheduler->active;
            if (scheduler->queue.empty() && scheduler->active == 0) {
                scheduler->idle.notify_all();
            }
        }
    }
}

extern "C" IDeckExecutionScheduler *ideck_scheduler_create(size_t workers, size_t queue_capacity) {
    if (!workers || workers > 16 || !queue_capacity || queue_capacity > 65536) return nullptr;
    auto *scheduler = new (std::nothrow) IDeckExecutionScheduler(queue_capacity);
    if (!scheduler) return nullptr;
    try {
        scheduler->workers.reserve(workers);
        for (size_t index = 0; index < workers; ++index) {
            scheduler->workers.emplace_back(ideck_scheduler_worker, scheduler);
        }
    } catch (...) {
        {
            std::lock_guard<std::mutex> lock(scheduler->mutex);
            scheduler->stopping = true;
        }
        scheduler->ready.notify_all();
        for (auto &thread : scheduler->workers) thread.join();
        delete scheduler;
        return nullptr;
    }
    return scheduler;
}

extern "C" bool ideck_scheduler_submit(IDeckExecutionScheduler *scheduler, IDeckNativeTask task, void *context) {
    if (!scheduler || !task) return false;
    {
        std::lock_guard<std::mutex> lock(scheduler->mutex);
        if (scheduler->stopping || scheduler->queue.size() >= scheduler->capacity) return false;
        try {
            scheduler->queue.push_back({task, context});
        } catch (...) {
            return false;
        }
    }
    scheduler->ready.notify_one();
    return true;
}

extern "C" void ideck_scheduler_wait_idle(IDeckExecutionScheduler *scheduler) {
    if (!scheduler) return;
    std::unique_lock<std::mutex> lock(scheduler->mutex);
    scheduler->idle.wait(lock, [scheduler] {
        return scheduler->queue.empty() && scheduler->active == 0;
    });
}

extern "C" size_t ideck_scheduler_pending(const IDeckExecutionScheduler *scheduler) {
    if (!scheduler) return 0;
    auto *state = const_cast<IDeckExecutionScheduler *>(scheduler);
    std::lock_guard<std::mutex> lock(state->mutex);
    return state->queue.size() + state->active;
}

extern "C" void ideck_scheduler_destroy(IDeckExecutionScheduler *scheduler) {
    if (!scheduler) return;
    {
        std::lock_guard<std::mutex> lock(scheduler->mutex);
        scheduler->stopping = true;
    }
    scheduler->ready.notify_all();
    for (auto &thread : scheduler->workers) thread.join();
    delete scheduler;
}
