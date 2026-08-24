using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Models;

/// <summary>One entry in a clip's ordered effect stack.</summary>
public sealed class Effect : IEquatable<Effect>
{
    public string Id { get; set; } = Uuid.NewString();
    public required string Type { get; set; }
    public bool Enabled { get; set; } = true;
    public Dictionary<string, EffectParam> Params { get; set; } = [];

    public static Effect Make(string type, IReadOnlyDictionary<string, double>? values = null)
    {
        var effect = new Effect { Type = type };
        if (values is not null)
        {
            foreach (var (key, value) in values)
            {
                effect.Params[key] = new EffectParam { Value = value };
            }
        }
        return effect;
    }

    public bool Equals(Effect? other)
        => other is not null
            && Id == other.Id
            && Type == other.Type
            && Enabled == other.Enabled
            && Params.Count == other.Params.Count
            && Params.All(kv => other.Params.TryGetValue(kv.Key, out var v) && kv.Value.Equals(v));

    public override bool Equals(object? obj) => Equals(obj as Effect);
    public override int GetHashCode() => HashCode.Combine(Id, Type, Enabled);
}

/// <summary>A single effect parameter.</summary>
public sealed class EffectParam : IEquatable<EffectParam>
{
    public double? Value { get; set; }
    public string? String { get; set; }
    public KeyframeTrack<double>? Track { get; set; }

    /// <summary>Effective numeric value at a clip-relative frame offset.</summary>
    public double Resolved(int offset, double defaultValue)
    {
        if (Track is { IsActive: true })
        {
            return Track.Sample(offset, Value ?? defaultValue);
        }
        return Value ?? defaultValue;
    }

    public bool Equals(EffectParam? other)
        => other is not null
            && Value == other.Value
            && String == other.String
            && Equals(Track, other.Track);

    public override bool Equals(object? obj) => Equals(obj as EffectParam);
    public override int GetHashCode() => HashCode.Combine(Value, String);
}
