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

    // envelope is the `{ "value": ..., "keyframes": [...]|null }` wrapper described in §5/§11.
    void ParseTransformValue(simdjson_result<dom::element> value, SnapshotTransform& out)
    {
        out.centerX = GetDoubleOr(value, "centerX", 0.5);
        out.centerY = GetDoubleOr(value, "centerY", 0.5);
        out.width = GetDoubleOr(value, "width", 1.0);
        out.height = GetDoubleOr(value, "height", 1.0);
        out.rotationDegrees = GetDoubleOr(value, "rotation", 0.0);
        out.flipHorizontal = GetBoolOr(value, "flipHorizontal", false);
        out.flipVertical = GetBoolOr(value, "flipVertical", false);
    }

    void ParseTransform(simdjson_result<dom::element> envelope, SnapshotTransform& out)
    {
        ParseTransformValue(envelope["value"], out);
    }

    void ParseCropValue(simdjson_result<dom::element> value, SnapshotCrop& out)
    {
        out.left = GetDoubleOr(value, "left", 0.0);
        out.top = GetDoubleOr(value, "top", 0.0);
        out.right = GetDoubleOr(value, "right", 0.0);
        out.bottom = GetDoubleOr(value, "bottom", 0.0);
    }

    void ParseCrop(simdjson_result<dom::element> envelope, SnapshotCrop& out)
    {
        ParseCropValue(envelope["value"], out);
    }

    // v1.1: `keyframes` is either JSON null (v1 shape, or a v1.1 producer with no
    // animation on this property) or an array of `{ frame, value, interpolation }` — both
    // collapse to an empty `out` vector, matching "keyframes empty" == "static value" per
    // SnapshotClip::OpacityAt/CropAt/TransformAt.
    template <typename Container, typename ParseValue, typename T>
    void ParseKeyframesArray(Container&& envelope, ParseValue parseValue, std::vector<SnapshotKeyframe<T>>& out)
    {
        out.clear();
        dom::array arr;
        if (envelope["keyframes"].get(arr) != SUCCESS)
        {
            return; // null or missing -> no keyframes (v1 shape)
        }
        for (dom::element kfEl : arr)
        {
            SnapshotKeyframe<T> kf;
            kf.frame = GetInt64Or(kfEl, "frame", 0);
            kf.interpolation = ParseInterpolation(GetStringOr(kfEl, "interpolation", "linear"));
            parseValue(kfEl["value"], kf.value);
            out.push_back(kf);
        }
    }

    void ParseDoubleKeyframeValue(simdjson_result<dom::element> value, double& out)
    {
        double d;
        if (value.get(d) == SUCCESS) { out = d; return; }
        int64_t i;
        if (value.get(i) == SUCCESS) { out = static_cast<double>(i); return; }
        out = 0.0;
    }

    void ParseEffectParam(dom::element el, SnapshotEffectParam& out)
    {
        double v;
        if (el["value"].get(v) == SUCCESS)
        {
            out.value = v;
        }
        else
        {
            int64_t iv;
            if (el["value"].get(iv) == SUCCESS)
            {
                out.value = static_cast<double>(iv);
            }
        }
        out.stringValue = GetOptionalString(el, "string");
        ParseKeyframesArray(el, ParseDoubleKeyframeValue, out.keyframes);
    }

    void ParseEffect(dom::element el, SnapshotEffect& out)
    {
        out.type = GetStringOr(el, "type", "");
        out.enabled = GetBoolOr(el, "enabled", true);
        dom::object paramsObj;
        if (el["params"].get(paramsObj) == SUCCESS)
        {
            for (auto field : paramsObj)
            {
                SnapshotEffectParam param;
                dom::element paramEl = field.value;
                ParseEffectParam(paramEl, param);
                out.params.emplace(std::string(field.key), std::move(param));
            }
        }
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
        out.fadeInFrames = GetInt64Or(el["volume"], "fadeInFrames", 0);
        out.fadeOutFrames = GetInt64Or(el["volume"], "fadeOutFrames", 0);
        out.fadeInInterpolation = ParseInterpolation(GetStringOr(el["volume"], "fadeInInterpolation", "linear"));
        out.fadeOutInterpolation = ParseInterpolation(GetStringOr(el["volume"], "fadeOutInterpolation", "linear"));

        ParseKeyframesArray(el["opacity"], ParseDoubleKeyframeValue, out.opacityKeyframes);
        ParseKeyframesArray(el["crop"], ParseCropValue, out.cropKeyframes);
        ParseKeyframesArray(el["transform"], ParseTransformValue, out.transformKeyframes);
        ParseKeyframesArray(el["volume"], ParseDoubleKeyframeValue, out.volumeKeyframes);

        dom::array effectsArr;
        if (el["effects"].get(effectsArr) == SUCCESS)
        {
            for (dom::element effectEl : effectsArr)
            {
                SnapshotEffect effect;
                ParseEffect(effectEl, effect);
                out.effects.push_back(std::move(effect));
            }
        }

        if (out.mediaPath.empty())
        {
            outError = "clip '" + out.id + "' has an empty mediaPath";
            return false;
        }
        return true;
    }

    // --- v1.2 text clips (docs/timeline-snapshot-v1.md §12) ------------------------------

    template <typename Container>
    void ParseRgba(Container&& obj, SnapshotRgba& out)
    {
        out.r = GetDoubleOr(obj, "r", 1.0);
        out.g = GetDoubleOr(obj, "g", 1.0);
        out.b = GetDoubleOr(obj, "b", 1.0);
        out.a = GetDoubleOr(obj, "a", 1.0);
    }

    template <typename Container>
    std::optional<SnapshotRgba> ParseOptionalRgba(Container&& parent, const char* key)
    {
        dom::object obj;
        if (parent[key].get(obj) != SUCCESS)
        {
            return std::nullopt; // null or missing
        }
        SnapshotRgba rgba;
        ParseRgba(parent[key], rgba);
        return rgba;
    }

    // Mirrors WriteTextStyle (TimelineSnapshotBuilder.cs) key-for-key; every field is missing-
    // tolerant, matching Models/TextStyle.swift's lenient decoder (TextStyle.swift:55).
    void ParseTextStyle(simdjson_result<dom::element> style, SnapshotTextStyle& out)
    {
        out.fontName = GetStringOr(style, "fontName", "Helvetica-Bold");
        out.fontSize = GetDoubleOr(style, "fontSize", 96.0);
        out.fontScale = GetDoubleOr(style, "fontScale", 1.0);
        out.isBold = GetBoolOr(style, "isBold", true);
        out.isItalic = GetBoolOr(style, "isItalic", false);
        ParseRgba(style["color"], out.color);
        out.alignment = GetStringOr(style, "alignment", "center");

        auto shadow = style["shadow"];
        out.shadowEnabled = GetBoolOr(shadow, "enabled", true);
        ParseRgba(shadow["color"], out.shadowColor);
        out.shadowOffsetX = GetDoubleOr(shadow, "offsetX", 0.0);
        out.shadowOffsetY = GetDoubleOr(shadow, "offsetY", -2.0);
        out.shadowBlur = GetDoubleOr(shadow, "blur", 6.0);

        auto background = style["background"];
        out.backgroundEnabled = GetBoolOr(background, "enabled", false);
        ParseRgba(background["color"], out.backgroundColor);

        auto border = style["border"];
        out.borderEnabled = GetBoolOr(border, "enabled", false);
        ParseRgba(border["color"], out.borderColor);
    }

    void ParseTextAnimation(simdjson_result<dom::element> anim, SnapshotTextAnimation& out)
    {
        out.preset = GetStringOr(anim, "preset", "none");
        out.perWordFrames = GetInt64Or(anim, "perWordFrames", 6);
        out.highlight = ParseOptionalRgba(anim, "highlight");
    }

    bool ParseTextClip(dom::element el, SnapshotTextClip& out)
    {
        out.id = GetStringOr(el, "id", "");
        out.startFrame = GetInt64Or(el, "startFrame", 0);
        out.durationFrames = GetInt64Or(el, "durationFrames", 0);
        out.content = GetStringOr(el, "content", "");
        // The builder drops empty-content text clips before serializing (§12.3); mirror that
        // defensively so a malformed snapshot can't smuggle an empty raster into the paint list.
        if (out.content.empty())
        {
            return false;
        }

        out.opacity = GetDoubleOr(el["opacity"], "value", 1.0);
        ParseKeyframesArray(el["opacity"], ParseDoubleKeyframeValue, out.opacityKeyframes);
        out.blendMode = GetOptionalString(el, "blendMode");
        // Flat transform, NOT a {value, keyframes} envelope (§12.3) — always static.
        ParseTransformValue(el["transform"], out.transform);
        ParseTextStyle(el["style"], out.style);
        ParseTextAnimation(el["animation"], out.animation);

        dom::array wordTimingsArr;
        if (el["wordTimings"].get(wordTimingsArr) == SUCCESS)
        {
            for (dom::element wtEl : wordTimingsArr)
            {
                SnapshotWordTiming wt;
                wt.text = GetStringOr(wtEl, "text", "");
                wt.startFrame = GetInt64Or(wtEl, "startFrame", 0);
                wt.endFrame = GetInt64Or(wtEl, "endFrame", 0);
                out.wordTimings.push_back(std::move(wt));
            }
        }

        dom::array effectsArr;
        if (el["effects"].get(effectsArr) == SUCCESS)
        {
            for (dom::element effectEl : effectsArr)
            {
                SnapshotEffect effect;
                ParseEffect(effectEl, effect);
                out.effects.push_back(std::move(effect));
            }
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

        // v1.2: `textClips` is omitted-when-empty (§12.2). Only visited when present — an
        // un-requested key never triggers a parse error (§12.6), so v1/v1.1 snapshots are
        // unaffected.
        dom::array textClipsArr;
        if (el["textClips"].get(textClipsArr) == SUCCESS)
        {
            for (dom::element textEl : textClipsArr)
            {
                SnapshotTextClip textClip;
                if (ParseTextClip(textEl, textClip))
                {
                    out.textClips.push_back(std::move(textClip));
                }
            }
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
        // Absent minorVersion -> 0 (v1) — never rejected; see TimelineSnapshot.h's comment.
        snapshot.minorVersion = static_cast<int32_t>(GetInt64Or(root, "minorVersion", 0));

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
