using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Agent;

namespace PalmierPro.App.Editor;

/// <summary>XAML-friendly host that owns the code-built AgentPanel.</summary>
public sealed class AgentPanelHost : UserControl
{
    public AgentPanel Panel { get; } = new();

    public AgentPanelHost() => Content = Panel;
}
