using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.ViewModels.MediaPanel;

namespace PalmierPro.App.Views.MediaPanel;

/// Picks FolderItemTemplate vs AssetItemTemplate for MediaTabView's mixed-item GridView.
public sealed class MediaItemTemplateSelector : DataTemplateSelector
{
    public DataTemplate? FolderTemplate { get; set; }
    public DataTemplate? AssetTemplate { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) => item switch
    {
        MediaFolderItemViewModel => FolderTemplate,
        MediaAssetItemViewModel => AssetTemplate,
        _ => base.SelectTemplateCore(item),
    };

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
