using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.Theme;
using PalmierPro.Core.Theme;
using Windows.System;
using Windows.UI.Core;

namespace PalmierPro.App.Controls;

/// Port of ScrubbableNumberField.swift. Drag horizontally past the threshold to scrub (Shift =
/// coarse, Alt = fine — see ScrubMath); a plain click opens text entry (Enter commits, Esc cancels
/// without committing, losing focus commits). ValueChanged fires per pixel while dragging or typing
/// (no undo entry); ValueCommitted fires exactly once per gesture end (one undo entry).
public sealed partial class ScrubbableNumberBox : UserControl
{
    private readonly ScrubGesture _gesture = new();
    private double? _value;
    private double _liveValue;
    private bool _isEditing;
    private bool _canScrub;
    private bool _gestureActive;
    private double _dragStartValue;

    public ScrubbableNumberBox()
    {
        InitializeComponent();
        RootStack.Spacing = AppThemeTokens.Spacing.Xs;
        ValueArea.Padding = AppTheme.ThicknessOf(
            AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs, AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs);
        RefreshDisplay();
    }

    public double Minimum { get; set; }
    public double Maximum { get; set; } = 1;
    public double DisplayMultiplier { get; set; } = 1;
    public string Format { get; set; } = "%.0f";
    public string ValueSuffix { get; set; } = "";
    public double DragSensitivity { get; set; } = 1;
    public Func<double, string?>? DisplayTextOverride { get; set; }

    public double FieldWidth
    {
        get => ValueArea.Width;
        set => ValueArea.Width = value;
    }

    public string? TrailingLabel
    {
        get => TrailingLabelText.Text;
        set
        {
            TrailingLabelText.Text = value ?? "";
            TrailingLabelText.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    /// Null = mixed selection ("—"). Assigning here mirrors ScrubbableNumberField's
    /// `.onChange(of: value)` — it resyncs the display but never fires ValueChanged/ValueCommitted.
    public double? Value
    {
        get => _value;
        set
        {
            _value = value;
            if (!_gesture.IsDragging && !_isEditing)
            {
                _liveValue = value ?? _liveValue;
                RefreshDisplay();
            }
        }
    }

    /// Live update during a drag or keystroke — never a single undo entry on its own.
    public event EventHandler<double>? ValueChanged;

    /// Fires exactly once per gesture end (drag release, Enter, or blur) — one undo entry.
    public event EventHandler<double>? ValueCommitted;

    private bool IsMixed => _value is null && !_gesture.IsDragging;

    private double SourceValue => _gesture.IsDragging ? _liveValue : (_value ?? _liveValue);

    private void RefreshDisplay()
    {
        if (IsMixed)
        {
            DisplayText.Text = "—";
            DisplayText.Foreground = AppTheme.Text.TertiaryBrush;
            return;
        }
        var raw = SourceValue;
        DisplayText.Text = DisplayTextOverride?.Invoke(raw) ?? ScrubMath.FormatDisplay(raw, DisplayMultiplier, Format, ValueSuffix);
        DisplayText.Foreground = AppTheme.Accent.PrimaryBrush;
    }

    // MARK: - Scrub gesture

    private void ValueArea_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_isEditing)
        {
            return;
        }
        ValueArea.CapturePointer(e.Pointer);
        _canScrub = _value.HasValue;
        _dragStartValue = _value ?? _liveValue;
        _gestureActive = true;
        _gesture.Begin(e.GetCurrentPoint(ValueArea).Position.X);
    }

    private void ValueArea_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        // Mixed selections can be clicked into edit mode but never scrubbed — matches the Mac's
        // ScrubArea, whose mouseDragged returns immediately (never sets isDragging) when !canScrub.
        if (_isEditing || !_canScrub)
        {
            return;
        }
        var x = e.GetCurrentPoint(ValueArea).Position.X;
        _gesture.Update(x, out var deltaX);
        if (!_gesture.IsDragging)
        {
            return;
        }
        var modifiers = CurrentModifiers();
        var next = ScrubMath.NextDragValue(_dragStartValue, deltaX, modifiers, DragSensitivity, DisplayMultiplier, Minimum, Maximum);
        if (next == _liveValue)
        {
            return;
        }
        _liveValue = next;
        RefreshDisplay();
        ValueChanged?.Invoke(this, next);
    }

    private void ValueArea_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_isEditing || !_gestureActive)
        {
            return;
        }
        _gestureActive = false;
        ValueArea.ReleasePointerCapture(e.Pointer);
        EndGesture();
    }

    // A normal release raises PointerReleased AND a subsequent PointerCaptureLost (the explicit
    // ReleasePointerCapture above raises it too) — _gestureActive ensures only whichever fires
    // first runs EndGesture. Also covers a capture lost mid-drag with no PointerReleased at all
    // (e.g. Alt+Tab): settle at the last known position instead of leaving the gesture stuck
    // (see PreviewView.xaml.cs's _isScrubbing for the identical pattern).
    private void ValueArea_PointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (_isEditing || !_gestureActive)
        {
            return;
        }
        _gestureActive = false;
        EndGesture();
    }

    private void EndGesture()
    {
        if (_gesture.End())
        {
            ValueCommitted?.Invoke(this, _liveValue);
        }
        else
        {
            BeginEdit();
        }
    }

    private void ValueArea_PointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (!_isEditing)
        {
            ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        }
    }

    private void ValueArea_PointerExited(object sender, PointerRoutedEventArgs e) =>
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Arrow);

    // MARK: - Text entry

    private void BeginEdit()
    {
        _isEditing = true;
        EditBox.Text = IsMixed ? "" : ScrubMath.FormatDisplay(SourceValue, DisplayMultiplier, Format, "");
        DisplayText.Visibility = Visibility.Collapsed;
        EditBox.Visibility = Visibility.Visible;
        EditBox.Focus(FocusState.Programmatic);
        EditBox.SelectAll();
    }

    private void EndEdit()
    {
        _isEditing = false;
        EditBox.Visibility = Visibility.Collapsed;
        DisplayText.Visibility = Visibility.Visible;
        RefreshDisplay();
    }

    private void CommitEdit()
    {
        if (ScrubMath.TryParseCommit(EditBox.Text, ValueSuffix, DisplayMultiplier, Minimum, Maximum, out var raw))
        {
            _liveValue = raw;
            ValueCommitted?.Invoke(this, raw);
        }
    }

    private void EditBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            CommitEdit();
            EndEdit();
        }
        else if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            EndEdit();
        }
    }

    // Catches click-away — Enter/Escape above already call EndEdit (which flips _isEditing off)
    // before this can fire, so a real blur is the only path left standing.
    private void EditBox_LostFocus(object sender, RoutedEventArgs e)
    {
        if (!_isEditing)
        {
            return;
        }
        CommitEdit();
        EndEdit();
    }

    private static ScrubModifiers CurrentModifiers()
    {
        var modifiers = ScrubModifiers.None;
        if (IsKeyDown(VirtualKey.Shift)) modifiers |= ScrubModifiers.Shift;
        if (IsKeyDown(VirtualKey.Menu)) modifiers |= ScrubModifiers.Alt;
        return modifiers;
    }

    private static bool IsKeyDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
}
