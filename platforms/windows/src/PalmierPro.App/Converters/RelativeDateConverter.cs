using Microsoft.UI.Xaml.Data;

namespace PalmierPro.App.Converters;

/// Ports ProjectCard.relativeString(for:) (Swift's RelativeDateTimeFormatter, .full style) —
/// .NET has no built-in relative-time formatter, so this is a small hand-rolled equivalent
/// covering the same coarse buckets a "last opened" label needs.
public sealed class RelativeDateConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        if (value is not DateTimeOffset date)
        {
            return string.Empty;
        }
        var delta = DateTimeOffset.UtcNow - date;
        if (delta < TimeSpan.Zero)
        {
            return "just now";
        }
        return delta switch
        {
            { TotalSeconds: < 60 } => "just now",
            { TotalMinutes: < 2 } => "1 minute ago",
            { TotalMinutes: < 60 } d => $"{(int)d.TotalMinutes} minutes ago",
            { TotalHours: < 2 } => "1 hour ago",
            { TotalHours: < 24 } d => $"{(int)d.TotalHours} hours ago",
            { TotalDays: < 2 } => "1 day ago",
            { TotalDays: < 30 } d => $"{(int)d.TotalDays} days ago",
            { TotalDays: < 60 } => "1 month ago",
            { TotalDays: < 365 } d => $"{(int)(d.TotalDays / 30)} months ago",
            { TotalDays: < 730 } => "1 year ago",
            var d => $"{(int)(d.TotalDays / 365)} years ago",
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
