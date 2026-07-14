using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// Synthesized Codable, no custom init: `id`/`name` are required on decode, `parentFolderId` is
/// Optional-lenient (missing/null -> null, wrong type -> throws).
public sealed class MediaFolder
{
    [JsonPropertyName("id")]
    [JsonRequired]
    public string Id { get; set; } = SwiftId.New();

    [JsonPropertyName("name")]
    [JsonRequired]
    public string Name { get; set; } = "";

    [JsonPropertyName("parentFolderId")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ParentFolderId { get; set; }

    public MediaFolder()
    {
    }

    public MediaFolder(string name, string? parentFolderId = null, string? id = null)
    {
        Id = id ?? SwiftId.New();
        Name = name;
        ParentFolderId = parentFolderId;
    }
}
