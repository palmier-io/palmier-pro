#!/usr/bin/env python3
"""Compile the Malay-wedding reference dataset into the bundled domain pack the app ships.

Reads AI-reference/references_malay_wedding.jsonl + taxonomy_malay_wedding.json and
derives, per moment type: importance, audio policy, preferred/avoid shot qualities, a
short classification cue, typical clip length, and per-ceremony ordered moment slots.

The vision-verified records carry audioImportance, momentSequenceHint and timecodes;
those drive audio policy, ordering, and typical duration directly. Category heuristics
are only a fallback for moments without that data. Re-runnable and deterministic.

    python scripts/build_domain_pack.py
"""
from __future__ import annotations

import json
import statistics
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "AI-reference"
OUT = ROOT / "Sources/PalmierPro/Resources/DomainPacks/malay_wedding.json"

# Editorial arc order. Earlier categories are cut earlier in a wedding film.
CATEGORY_ORDER = ["scene", "preparation", "ceremony", "family", "celebration"]

# Audio policy default per category. feature-original = the clip's own audio is the
# point (vows, speech, greetings); music-bed-ok = safe to lay music over; ambient =
# light room tone, neither featured nor important.
CATEGORY_AUDIO = {
    "ceremony": "feature-original",
    "family": "feature-original",
    "preparation": "ambient",
    "celebration": "music-bed-ok",
    "scene": "music-bed-ok",
}
# Vision-verified audioImportance (in the rich records) -> our audioPolicy vocabulary.
# This is preferred over the category heuristic below whenever the data has it.
AUDIO_IMPORTANCE_TO_POLICY = {
    "crucial": "feature-original",
    "replaceable": "music-bed-ok",
    "ambient": "ambient",
}

# Per-moment overrides where the category default is wrong.
MOMENT_AUDIO = {
    "family_portrait": "ambient",   # posed photo, no crucial speech
    "guest_reaction": "ambient",
    "couple_portrait": "music-bed-ok",
    "decor_detail": "music-bed-ok",
    "venue_establishing": "music-bed-ok",
}
# Keywords in culturalNotes that force feature-original (speech/audio is crucial).
AUDIO_KEYWORDS = ("vow", "speech", "interview", "silent", "reverent", "doa", "audio", "recit")

# Drop low-confidence moment labels so the pack is built from trustworthy data only.
CONFIDENCE_MIN = 0.8

# Importance thresholds as a fraction of the kept dataset, so they scale with its size.
CORE_FRAC = 0.15
OPTIONAL_FRAC = 0.04

# Per-ceremony category whitelist (which moments belong to each ceremony's arc).
CEREMONY_CATEGORIES = {
    "nikah": ["scene", "preparation", "ceremony", "family"],
    "tunang": ["scene", "preparation", "ceremony", "family"],
    "reception": ["scene", "celebration", "family"],
}
# Tunang (engagement) excludes the solemnization itself.
TUNANG_EXCLUDE = {"akad_nikah"}


def load_records() -> tuple[list[dict], int]:
    """Returns (kept records at/above CONFIDENCE_MIN, total records read)."""
    path = SRC_DIR / "references_malay_wedding.jsonl"
    kept, total = [], 0
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        total += 1
        rec = json.loads(line)
        conf = rec.get("labelConfidence")
        if conf is None or conf >= CONFIDENCE_MIN:
            kept.append(rec)
    return kept, total


def category_of(moment: str, categories: dict[str, list[str]]) -> str:
    for cat, moments in categories.items():
        if moment in moments:
            return cat
    return "scene"


def importance_of(count: int, total: int) -> str:
    frac = count / total if total else 0
    if frac >= CORE_FRAC:
        return "core"
    if frac >= OPTIONAL_FRAC:
        return "optional"
    return "filler"


def audio_policy_of(moment: str, category: str, notes: str) -> str:
    if any(k in notes.lower() for k in AUDIO_KEYWORDS):
        return "feature-original"
    if moment in MOMENT_AUDIO:
        return MOMENT_AUDIO[moment]
    return CATEGORY_AUDIO.get(category, "music-bed-ok")


def humanize(moment: str) -> str:
    return moment.replace("_", " ")


def top_values(counter: Counter, n: int) -> list[str]:
    return [v for v, _ in counter.most_common(n)]


def learned_sequences(records: list[dict]) -> dict | None:
    """Reconstruct each video's real edit order (sort segments by sequence hint, dedupe
    consecutive repeats) and learn how editors open and transition between moments."""
    byvid: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        pm = r.get("primaryMoment")
        pos = r.get("timecodeStart", r.get("momentSequenceHint"))
        if pm and pos is not None and r.get("sourceVideoId"):
            byvid[r["sourceVideoId"]].append(r)

    timelines: list[list[str]] = []
    for segs in byvid.values():
        # Order by actual timecode (precise) and fall back to the coarse sequence hint.
        segs.sort(key=lambda s: s.get("timecodeStart", s.get("momentSequenceHint", 0)))
        seq: list[str] = []
        for s in segs:
            m = s["primaryMoment"]
            if not seq or seq[-1] != m:   # collapse consecutive repeats from frame sampling
                seq.append(m)
        if len(seq) >= 2:
            timelines.append(seq)

    if len(timelines) < 10:
        return None   # too little data to be meaningful

    opens: Counter = Counter(t[0] for t in timelines)
    trans: dict[str, Counter] = defaultdict(Counter)
    for t in timelines:
        for a, b in zip(t, t[1:]):
            trans[a][b] += 1

    def frac_list(counter: Counter, n: int) -> list[dict]:
        tot = sum(counter.values())
        return [{"moment": m, "fraction": round(c / tot, 2)} for m, c in counter.most_common(n)]

    return {
        "videosAnalyzed": len(timelines),
        "openingMoments": frac_list(opens, 5),
        "commonNext": {m: frac_list(c, 3) for m, c in sorted(trans.items())},
        "note": "How real editors actually sequence shots (deduped per-video timelines). A market-trend guide — the canonical ceremony order is still the safe default.",
    }


def build() -> dict:
    taxonomy = json.loads((SRC_DIR / "taxonomy_malay_wedding.json").read_text(encoding="utf-8"))
    records, total_read = load_records()

    # Moment frequencies come from the kept (high-confidence) records, not the taxonomy,
    # so importance stays consistent with whatever data we actually built from.
    moment_counts: Counter = Counter(m for r in records for m in r.get("momentTypes", []))
    kept_total = len(records)
    categories: dict[str, list[str]] = taxonomy.get("momentCategories", {})
    preferred_composition = taxonomy.get("preferredComposition", "")

    # Vision-verified per-segment records (have a primaryMoment + audioImportance +
    # momentSequenceHint + timecodes). Attribute those signals to the primaryMoment.
    rich_by_moment: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        pm = r.get("primaryMoment")
        if pm and "audioImportance" in r:
            rich_by_moment[pm].append(r)

    def data_audio_policy(moment: str) -> str | None:
        vals = [x["audioImportance"] for x in rich_by_moment.get(moment, []) if x.get("audioImportance")]
        if not vals:
            return None
        return AUDIO_IMPORTANCE_TO_POLICY.get(Counter(vals).most_common(1)[0][0])

    def data_seq_hint(moment: str) -> float | None:
        seqs = [x["momentSequenceHint"] for x in rich_by_moment.get(moment, []) if x.get("momentSequenceHint") is not None]
        return statistics.mean(seqs) if seqs else None

    def data_duration(moment: str) -> int | None:
        spans = [
            x["timecodeEnd"] - x["timecodeStart"]
            for x in rich_by_moment.get(moment, [])
            if x.get("timecodeStart") is not None and x.get("timecodeEnd") is not None
        ]
        return round(statistics.median(spans)) if spans else None

    # Aggregate shot qualities + a representative cultural note per moment from the records.
    preferred: dict[str, Counter] = {}
    avoid: dict[str, Counter] = {}
    notes: dict[str, Counter] = {}
    for rec in records:
        note = (rec.get("culturalNotes") or "").strip()
        for moment in rec.get("momentTypes", []):
            preferred.setdefault(moment, Counter()).update(rec.get("preferredShotQualities", []))
            avoid.setdefault(moment, Counter()).update(rec.get("avoidQualities", []))
            if note:
                notes.setdefault(moment, Counter()).update([note])

    moments: dict[str, dict] = {}
    for moment, count in moment_counts.items():
        category = category_of(moment, categories)
        note_counter = notes.get(moment, Counter())
        rep_note = note_counter.most_common(1)[0][0] if note_counter else ""
        cue_bits = [humanize(moment)]
        if preferred_composition:
            cue_bits.append(preferred_composition)
        if rep_note:
            cue_bits.append(rep_note)
        entry = {
            "category": category,
            "importance": importance_of(count, kept_total),
            # Prefer the vision-verified audioImportance; fall back to the category heuristic.
            "audioPolicy": data_audio_policy(moment) or audio_policy_of(moment, category, rep_note),
            "preferredShots": top_values(preferred.get(moment, Counter()), 3),
            "avoidQualities": top_values(avoid.get(moment, Counter()), 3) or ["blurry", "shaky"],
            "classificationCues": " — ".join(cue_bits),
            "referenceCount": count,
        }
        duration = data_duration(moment)
        if duration is not None:
            entry["typicalDurationSec"] = duration
        moments[moment] = entry

    def ordered_for(allowed_cats: list[str], exclude: set[str]) -> list[str]:
        slots = [m for m in moments if moments[m]["category"] in allowed_cats and m not in exclude]
        # Macro arc by category, then the vision-verified average sequence position within it
        # (falling back to frequency when a moment has no sequence data).
        def key(m: str):
            seq = data_seq_hint(m)
            return (CATEGORY_ORDER.index(moments[m]["category"]),
                    seq if seq is not None else 999,
                    -moment_counts[m])
        slots.sort(key=key)
        return slots

    ceremonies = {
        "nikah": ordered_for(CEREMONY_CATEGORIES["nikah"], set()),
        "tunang": ordered_for(CEREMONY_CATEGORIES["tunang"], TUNANG_EXCLUDE),
        "reception": ordered_for(CEREMONY_CATEGORIES["reception"], set()),
    }

    # Open-taxonomy guard: surface any moment types not yet placed in momentCategories so
    # new scenes (outdoor_shoot, sarung_cincin, ...) get a real category instead of "scene".
    known = {m for ms in categories.values() for m in ms}
    uncategorized = sorted(m for m in moments if m not in known)
    if uncategorized:
        print("  WARNING uncategorized moments (defaulted to 'scene' — add to taxonomy "
              f"momentCategories): {', '.join(uncategorized)}")

    return {
        "_note": "Derived from AI-reference by scripts/build_domain_pack.py. Audio/order/duration come from vision-verified records where available, else category heuristics. Editable by hand.",
        "domain": taxonomy.get("domain", "malay_wedding"),
        "culture": taxonomy.get("culture", ""),
        "audioPatterns": taxonomy.get("audioPatterns", ""),
        "typicalPacing": taxonomy.get("typicalPacing", ""),
        "confidenceMin": CONFIDENCE_MIN,
        "recordsKept": kept_total,
        "recordsTotal": total_read,
        "moments": moments,
        "ceremonies": ceremonies,
        "learnedSequences": learned_sequences(records),
    }


def main() -> None:
    pack = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(pack, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {OUT.relative_to(ROOT)} — {len(pack['moments'])} moments, "
          f"{len(pack['ceremonies'])} ceremonies "
          f"(kept {pack['recordsKept']}/{pack['recordsTotal']} records at confidence >= {CONFIDENCE_MIN}).")


if __name__ == "__main__":
    main()
