#pragma once

class TimelineSession;

// Process-wide validity set for PE_TimelineHandle values (reinterpret_cast'd
// TimelineSession pointers). Most timeline ABI entry points (PE_UpdateTimeline,
// PE_TimelineSeek, PE_TimelineAttachSwapChain/Resize/Detach, PE_TimelineRenderFrameToFile,
// PE_TimelineSetPlayheadCallback, PE_TimelineGetUnprocessableMediaRefsJson) take only a
// timeline handle, no session — this registry is how they reject a stale/closed/forged
// handle instead of blindly dereferencing it, mirroring the "handles are opaque; callers
// must not dereference them" contract in include/palmier_engine.h. Registration is RAII:
// TimelineSession registers itself in its constructor and unregisters in its destructor,
// so it's correct regardless of *how* a TimelineSession is destroyed (explicit
// PE_CloseTimeline, per-session LRU eviction, or the owning EngineSession tearing down).
namespace TimelineRegistry
{
    void Register(TimelineSession* session);
    void Unregister(TimelineSession* session);

    // Returns handle back if it's a currently-registered TimelineSession*, else nullptr.
    TimelineSession* Resolve(TimelineSession* handleAsSession);
}
