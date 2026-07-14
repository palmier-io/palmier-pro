#include "TimelineSnapshotParser.h"
#include "third_party/simdjson/simdjson.h"

#include <cmath>

using namespace simdjson;

namespace
{
    // All Get*Or helpers are templated on the field-container type so they accept both
    // a plain dom::element (e.g. the "root" document, or a range-for-yielded array
    // element) and a simdjson_result<dom::element> (the type chaining operator[]
    // naturally produces, e.g. `el["transform"]`) — both support operator[], so a
    // missing parent object (e.g. no "transform" key at all) safely propagates as
    // "field not found" all the way down to the leaf accessor instead of needing a
    // null-check at every level — this is simdjson's documented chaining idiom.
    template <typename Container>
    double GetDoubleOr(Container&& field, const char* key, double def)
    {
        auto v = field[key];
        double d;
        if (v.get(d) == SUCCESS) return d;
        int64_t i;
        if (v.get(i) == SUCCESS) return static_cast<double>(i);
        uint64_t u;
        if (v.get(u) == SUCCESS) return static_cast<double>(u);
        return def;
    }

    template <typename Container>
    int64_t GetInt64Or(Container&& field, const char* key, int64_t def)
    {
        auto v = field[key];
        int64_t i;
        if (v.get(i) == SUCCESS) return i;
        uint64_t u;
        if (v.get(u) == SUCCESS) return static_cast<int64_t>(u);
        double d;
        if (v.get(d) == SUCCESS) return static_cast<int64_t>(std::llround(d));
        return def;
    }

    template <typename Container>
    bool GetBoolOr(Container&& field, const char* key, bool def)
    {
        auto v = field[key];
        bool b;
        if (v.get(b) == SUCCESS) return b;
        return def;
    }

    template <typename Container>
    std::string GetStringOr(Container&& field, const char* key, const std::string& def)
    {
        auto v = field[key];
        std::string_view s;
        if (v.get(s) == SUCCESS) return std::string(s);
        return def;
    }

    // JSON `null` fails .get(bool&)/.get(string_view&) with INCORRECT_TYPE, same as a
    // missing key — both collapse to nullopt here, matching the schema's "null means
    // unset" convention (docs/timeline-snapshot-v1.md §5).
    template <typename Container>
    std::optional<bool> GetOptionalBool(Container&& field, const char* key)
    {
        auto v = field[key];
        bool b;
        if (v.get(b) == SUCCESS) return b;
        return std::nullopt;
    }

    template <typename Container>
    std::optional<std::string> GetOptionalString(Container&& field, const char* key)
    {
        auto v = field[key];
        std::string_view s;
        if (v.get(s) == SUCCESS) return std::string(s);
        return std::nullopt;
    }

    SnapshotClipType ParseClipType(const std::string& s)
    {
        if (s == "audio") return SnapshotClipType::Audio;
        if (s == "image") return SnapshotClipType::Image;
        return SnapshotClipType::Video;
    }

    SnapshotTrackType ParseTrackType(const std::string& s)
    {
        return s == "audio" ? SnapshotTrackType::Audio : SnapshotTrackType::Video;
    }

    // envelope is the `{ "value": ..., "keyframes": null }` wrapper described in §5 —
    // v1 is static-only, so "keyframes" (always null in this schema version) is
    // intentionally never read here.
    void ParseTransform(simdjson_result<dom::element> envelope, SnapshotTransform& out)
    {
        auto value = envelope["value"];
        out.centerX = GetDoubleOr(value, "centerX", 0.5);
        out.centerY = GetDoubleOr(value, "centerY", 0.5);
        out.width = GetDoubleOr(value, "width", 1.0);
        out.height = GetDoubleOr(value, "height", 1.0);
        out.rotationDegrees = GetDoubleOr(value, "rotation", 0.0);
        out.flipHorizontal = GetBoolOr(value, "flipHorizontal", false);
        out.flipVertical = GetBoolOr(value, "flipVertical", false);
    }

    void ParseCrop(simdjson_result<dom::element> envelope, SnapshotCrop& out)
    {
        auto value = envelope["value"];
        out.left = GetDoubleOr(value, "left", 0.0);
        out.top = GetDoubleOr(value, "top", 0.0);
        out.right = GetDoubleOr(value, "right", 0.0);
        out.bottom = GetDoubleOr(value, "bottom", 0.0);
    }

    bool ParseClip(dom::element el, SnapshotClip& out, std::string& outError)
    {
        out.id = GetStringOr(el, "id", "");
        out.type = ParseClipType(GetStringOr(el, "type", "video"));
        out.startFrame = GetInt64Or(el, "startFrame", 0);
        out.durationFrames = GetInt64Or(el, "durationFrames", 0);
        out.trimStartFrame = GetInt64Or(el, "trimStartFrame", 0);
        out.speed = GetDoubleOr(el, "speed", 1.0);
        out.mediaPath = GetStringOr(el, "mediaPath", "");
        out.hasAlphaHint = GetOptionalBool(el, "hasAlphaHint");
        out.blendMode = GetOptionalString(el, "blendMode");
        out.opacity = GetDoubleOr(el["opacity"], "value", 1.0);
        ParseTransform(el["transform"], out.transform);
        ParseCrop(el["crop"], out.crop);
        out.volumeGain = GetDoubleOr(el["volume"], "gain", 1.0);

        if (out.mediaPath.empty())
        {
            outError = "clip '" + out.id + "' has an empty mediaPath";
            return false;
        }
        return true;
    }

    bool ParseTrack(dom::element el, SnapshotTrack& out, std::string& outError)
    {
        out.id = GetStringOr(el, "id", "");
        out.type = ParseTrackType(GetStringOr(el, "type", "video"));
        out.muted = GetBoolOr(el, "muted", false);

        dom::array clipsArr;
        if (el["clips"].get(clipsArr) != SUCCESS)
        {
            outError = "track '" + out.id + "' has no clips array";
            return false;
        }
        for (dom::element clipEl : clipsArr)
        {
            SnapshotClip clip;
            if (!ParseClip(clipEl, clip, outError))
            {
                return false;
            }
            out.clips.push_back(std::move(clip));
        }
        return true;
    }
}

bool TimelineSnapshotParser::Parse(const std::string& utf8Json, TimelineSnapshot& outSnapshot, std::string& outError)
{
    try
    {
        dom::parser parser;
        padded_string padded(utf8Json);

        dom::element root;
        auto parseError = parser.parse(padded).get(root);
        if (parseError != SUCCESS)
        {
            outError = std::string("simdjson parse error: ") + error_message(parseError);
            return false;
        }

        int64_t version = GetInt64Or(root, "version", 0);
        if (version != 1)
        {
            outError = "unrecognized timeline snapshot version " + std::to_string(version) + " (expected 1)";
            return false;
        }

        TimelineSnapshot snapshot;
        snapshot.version = static_cast<int32_t>(version);

        auto fps = root["fps"];
        snapshot.fpsNumerator = static_cast<int32_t>(GetInt64Or(fps, "numerator", 30));
        snapshot.fpsDenominator = static_cast<int32_t>(GetInt64Or(fps, "denominator", 1));
        snapshot.outputWidth = static_cast<int32_t>(GetInt64Or(root, "outputWidth", 1920));
        snapshot.outputHeight = static_cast<int32_t>(GetInt64Or(root, "outputHeight", 1080));

        dom::array tracksArr;
        if (root["tracks"].get(tracksArr) != SUCCESS)
        {
            outError = "snapshot is missing a top-level 'tracks' array";
            return false;
        }
        for (dom::element trackEl : tracksArr)
        {
            SnapshotTrack track;
            if (!ParseTrack(trackEl, track, outError))
            {
                return false;
            }
            snapshot.tracks.push_back(std::move(track));
        }

        outSnapshot = std::move(snapshot);
        return true;
    }
    catch (const simdjson_error& ex)
    {
        outError = std::string("simdjson exception: ") + ex.what();
        return false;
    }
    catch (const std::exception& ex)
    {
        outError = std::string("timeline snapshot parse failed: ") + ex.what();
        return false;
    }
}
