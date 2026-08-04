namespace PalmierPro.App.Theme;

/// <summary>
/// Numeric design tokens ported from AppTheme.swift for use in code-behind and layout math.
/// Colors and brushes live in Theme/AppThemeResources.xaml.
/// </summary>
public static class AppTheme
{
    public static class Spacing
    {
        public const double Zero = 0;
        public const double Xxs = 2;
        public const double Xs = 4;
        public const double Sm = 6;
        public const double SmMd = 8;
        public const double Md = 10;
        public const double MdLg = 12;
        public const double Lg = 14;
        public const double LgXl = 16;
        public const double Xl = 20;
        public const double XlXxl = 24;
        public const double Xxl = 28;
    }

    public static class FontSize
    {
        public const double Micro = 8;
        public const double Xxs = 9;
        public const double Xs = 10;
        public const double Sm = 11;
        public const double SmMd = 12;
        public const double Md = 13;
        public const double MdLg = 14;
        public const double Lg = 15;
        public const double Xl = 18;
        public const double Title1 = 22;
        public const double Title2 = 28;
        public const double Display = 36;
    }

    public static class Radius
    {
        public const double Xs = 3;
        public const double XsSm = 4;
        public const double Sm = 6;
        public const double Md = 10;
        public const double MdLg = 12;
        public const double Lg = 14;
        public const double Xl = 20;
    }

    public static class BorderWidth
    {
        public const double Hairline = 0.5;
        public const double Thin = 1;
        public const double Medium = 1.5;
        public const double Thick = 2;
    }

    public static class Opacity
    {
        public const double Opaque = 1;
        public const double Subtle = 0.04;
        public const double Hint = 0.06;
        public const double Faint = 0.08;
        public const double Soft = 0.10;
        public const double Muted = 0.15;
        public const double Moderate = 0.25;
        public const double Medium = 0.35;
        public const double Strong = 0.55;
        public const double High = 0.70;
        public const double Prominent = 0.80;
    }

    public static class IconSize
    {
        public const double Xxs = 12;
        public const double Xs = 14;
        public const double Sm = 18;
        public const double SmMd = 20;
        public const double Md = 22;
        public const double MdLg = 24;
        public const double Lg = 26;
        public const double LgXl = 28;
        public const double Xl = 30;
    }

    public static class ComponentSize
    {
        public const double ProjectCardWidth = 150;
        public const double ProjectCardHeight = 120;
        public const double ProjectSearchWidth = 260;
    }

    public static class Settings
    {
        public const double SidebarWidth = 220;
    }

    public static class Window
    {
        public const double HomeDefaultWidth = 1200;
        public const double HomeDefaultHeight = 800;
        public const double HomeMinWidth = 760;
        public const double HomeMinHeight = 480;
        public const double EditorDefaultWidth = 1440;
        public const double EditorDefaultHeight = 900;
    }

    public static class Layout
    {
        public const double PanelGap = 5;
        public const double AgentDefaultWidth = 280;
        public const double MediaDefaultWidth = 500;
        public const double InspectorDefaultWidth = 340;
        public const double TimelineMinHeight = 160;
    }

    public static class Anim
    {
        public const double Hover = 0.15;
        public const double Transition = 0.2;
        public const double Pulse = 0.8;
    }
}
