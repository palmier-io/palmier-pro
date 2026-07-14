using PalmierPro.Core.Interop;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests.Interop;

public class ClipRefDragFormatTests
{
    [Fact]
    public void Serialize_then_Deserialize_round_trips_the_asset_id_list()
    {
        string[] ids = ["asset-1", "asset-2", "asset-3"];

        var json = ClipRefDragFormat.Serialize(ids);
        var result = ClipRefDragFormat.Deserialize(json);

        result.ShouldBe(ids);
    }

    [Fact]
    public void Deserialize_returns_null_for_malformed_json()
    {
        ClipRefDragFormat.Deserialize("not json").ShouldBeNull();
    }

    [Fact]
    public void FormatId_is_the_documented_wire_constant()
    {
        ClipRefDragFormat.FormatId.ShouldBe("PalmierPro.ClipRef");
    }
}
