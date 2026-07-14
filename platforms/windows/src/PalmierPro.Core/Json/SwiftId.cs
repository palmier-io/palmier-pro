namespace PalmierPro.Core.Json;

/// Mimics Swift's `UUID().uuidString` (uppercase, hyphenated) so generated ids look the same on both platforms.
public static class SwiftId
{
    public static string New() => Guid.NewGuid().ToString().ToUpperInvariant();
}
