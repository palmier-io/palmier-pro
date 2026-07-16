namespace PalmierPro.App.Controls;

/// Precision modifiers during a scrub drag — mirrors ScrubbableNumberField.swift's
/// NSEvent.ModifierFlags handling (Shift = coarse/10x, ⌘ = fine/0.1x). Windows has no Command key;
/// Alt stands in for ⌘ here since nothing else in this port claims it for scrub precision.
[Flags]
public enum ScrubModifiers
{
    None = 0,
    Shift = 1 << 0,
    Alt = 1 << 1,
}
