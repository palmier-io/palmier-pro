#pragma once

#include "TimelineSnapshot.h"

#include <string>

// Parses the timeline-snapshot-v1 JSON contract (docs/timeline-snapshot-v1.md) with
// simdjson. Rejects (returns false) any `version` other than 1 rather than guessing at
// an unrecognized shape — see the doc's §1.
namespace TimelineSnapshotParser
{
    bool Parse(const std::string& utf8Json, TimelineSnapshot& outSnapshot, std::string& outError);
}
