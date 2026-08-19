using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Models;

public sealed class MediaFolder
{
    public string Id { get; set; } = Uuid.NewString();
    public required string Name { get; set; }
    public string? ParentFolderId { get; set; }
}
