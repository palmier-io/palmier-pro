#include "TimelineRegistry.h"

#include <mutex>
#include <unordered_set>

namespace
{
    std::mutex g_mutex;
    std::unordered_set<TimelineSession*> g_valid;
}

void TimelineRegistry::Register(TimelineSession* session)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_valid.insert(session);
}

void TimelineRegistry::Unregister(TimelineSession* session)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_valid.erase(session);
}

TimelineSession* TimelineRegistry::Resolve(TimelineSession* handleAsSession)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_valid.count(handleAsSession) ? handleAsSession : nullptr;
}
