using PalmierPro.Agent.Tools;
using Xunit;

namespace PalmierPro.Agent.Tests;

public class ToolDefinitionsTests
{
    [Fact]
    public void AllToolsHaveStableApiNamesAndSchemas()
    {
        Assert.True(ToolDefinitions.All.Count >= 40);
        var names = ToolDefinitions.All.Select(t => t.Name.ApiName()).ToHashSet();
        Assert.Contains("get_timeline", names);
        Assert.Contains("export_project", names);
        Assert.Contains("remove_clips", names);
        Assert.All(ToolDefinitions.All, t =>
        {
            Assert.False(string.IsNullOrWhiteSpace(t.Description));
            Assert.Equal("object", t.InputSchema["type"]?.GetValue<string>());
            Assert.NotNull(t.InputSchema["properties"]);
        });
    }

    [Fact]
    public void McpServerIncludesManageProject()
    {
        Assert.Contains(ToolDefinitions.McpServer, t => t.Name == ToolName.ManageProject);
        Assert.Equal(ToolDefinitions.All.Count + 1, ToolDefinitions.McpServer.Count);
    }

    [Fact]
    public void ToolNameRoundTrips()
    {
        foreach (ToolName name in Enum.GetValues<ToolName>())
        {
            Assert.True(ToolNameExtensions.TryParse(name.ApiName(), out var parsed));
            Assert.Equal(name, parsed);
        }
    }
}
