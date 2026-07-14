using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Theme;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Views;

public sealed partial class EditorPlaceholderView : UserControl
{
    public EditorPlaceholderView()
    {
        InitializeComponent();
        foreach (var panel in new[] { MediaPanel, PreviewPanel, InspectorPanel, TimelinePanel })
        {
            panel.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Md);
            panel.BorderBrush = AppTheme.Border.SubtleBrush;
            panel.BorderThickness = AppTheme.UniformThickness(AppThemeTokens.BorderWidth.Hairline);
        }
    }
}
