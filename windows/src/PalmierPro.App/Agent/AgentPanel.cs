using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.Agent;
using PalmierPro.Agent.Chat;

namespace PalmierPro.App.Agent;

/// <summary>Minimal agent chat panel — messages, draft, send/cancel.</summary>
public sealed class AgentPanel : UserControl
{
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None };
    private readonly TextBox _draft = new()
    {
        PlaceholderText = "Ask, or type @ to reference media",
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        MinHeight = 56,
        MaxHeight = 120,
    };
    private readonly TextBlock _status = new() { FontSize = 11, Opacity = 0.7 };
    private readonly Button _send = new() { Content = "Send", Padding = new Thickness(12, 6, 12, 6) };
    private readonly Button _cancel = new() { Content = "Stop", Padding = new Thickness(12, 6, 12, 6), Visibility = Visibility.Collapsed };
    private AgentService? _service;

    public AgentPanel()
    {
        var root = new Grid { RowSpacing = 8, Padding = new Thickness(10, 4, 10, 10) };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        _list.ItemTemplate = CreateTemplate();
        Grid.SetRow(_list, 0);
        root.Children.Add(_list);

        Grid.SetRow(_draft, 1);
        root.Children.Add(_draft);

        var bar = new Grid { ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_status, 0);
        bar.Children.Add(_status);
        Grid.SetColumn(_cancel, 1);
        bar.Children.Add(_cancel);
        Grid.SetColumn(_send, 2);
        bar.Children.Add(_send);
        Grid.SetRow(bar, 2);
        root.Children.Add(bar);

        _send.Click += async (_, _) =>
        {
            if (_service is null) return;
            _service.Draft = _draft.Text;
            _draft.Text = "";
            await _service.SendAsync();
        };
        _cancel.Click += (_, _) => _service?.Cancel();
        Content = root;
    }

    public void Bind(AgentService service)
    {
        if (_service is not null) _service.Changed -= OnChanged;
        _service = service;
        service.Changed += OnChanged;
        OnChanged();
    }

    private void OnChanged()
    {
        if (_service is null) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            _list.ItemsSource = null;
            _list.ItemsSource = _service.Messages.ToList();
            _status.Text = _service.StreamError
                ?? (_service.IsStreaming ? "Thinking…" :
                    _service.HasApiKey ? "Ready" : "Set ANTHROPIC_API_KEY");
            _send.IsEnabled = !_service.IsStreaming;
            _cancel.Visibility = _service.IsStreaming ? Visibility.Visible : Visibility.Collapsed;
            if (_service.Messages.Count > 0)
                _list.ScrollIntoView(_service.Messages[^1]);
        });
    }

    private static DataTemplate CreateTemplate()
    {
        // Code-built template: role label + text.
        var xaml = """
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
              <StackPanel Margin="0,0,0,10" Spacing="2">
                <TextBlock FontSize="10" Opacity="0.55"
                           Text="{Binding Role}" />
                <TextBlock TextWrapping="Wrap" FontSize="12"
                           Text="{Binding Text}" IsTextSelectionEnabled="True" />
              </StackPanel>
            </DataTemplate>
            """;
        return (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(xaml);
    }
}
