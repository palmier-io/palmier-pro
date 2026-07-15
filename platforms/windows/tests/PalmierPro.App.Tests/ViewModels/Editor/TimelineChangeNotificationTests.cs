using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Exercises `TimelineEditorViewModel`'s structural-vs-param notify split
/// (`StructuralChangeRequested` vs `RefreshVisualsRequested`) and the ~120ms debounce/
/// immediate-cancel behavior around `NotifyTimelineChangedDebounced` — previously uncovered
/// despite being a named Stage-C deliverable (see `NotifyTimelineChanged`/
/// `NotifyTimelineChangedDebounced` doc comments in TimelineEditorViewModel.cs).
public class TimelineChangeNotificationTests
{
    [Fact]
    public async Task NotifyTimelineChangedFiresBothEventsByDefault()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var structural = 0;
        var refreshVisuals = 0;
        e.StructuralChangeRequested += (_, _) => structural++;
        e.RefreshVisualsRequested += (_, _) => refreshVisuals++;

        e.NotifyTimelineChanged();

        structural.ShouldBe(1);
        refreshVisuals.ShouldBe(1);
    }

    [Fact]
    public async Task NotifyTimelineChangedWithRefreshVisualsFalseOnlyFiresStructural()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var structural = 0;
        var refreshVisuals = 0;
        e.StructuralChangeRequested += (_, _) => structural++;
        e.RefreshVisualsRequested += (_, _) => refreshVisuals++;

        e.NotifyTimelineChanged(refreshVisuals: false);

        structural.ShouldBe(1);
        refreshVisuals.ShouldBe(0);
    }

    [Fact]
    public async Task NotifyTimelineChangedIsNoOpWhileRegistrationDisabled()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var structural = 0;
        e.StructuralChangeRequested += (_, _) => structural++;

        e.Document.UndoService.DisableRegistration();
        e.NotifyTimelineChanged();

        structural.ShouldBe(0);
    }

    [Fact]
    public async Task DebouncedNotifyFiresOnlyStructuralAfterTheDelay()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var structural = 0;
        var refreshVisuals = 0;
        e.StructuralChangeRequested += (_, _) => structural++;
        e.RefreshVisualsRequested += (_, _) => refreshVisuals++;

        e.NotifyTimelineChangedDebounced(TimeSpan.FromMilliseconds(20));
        structural.ShouldBe(0); // not yet — still pending

        await Task.Delay(TimeSpan.FromMilliseconds(200));

        structural.ShouldBe(1);
        refreshVisuals.ShouldBe(0); // the debounced path never touches RefreshVisualsRequested
    }

    [Fact]
    public async Task RapidDebouncedCallsCoalesceIntoOneFire()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var structural = 0;
        e.StructuralChangeRequested += (_, _) => structural++;

        e.NotifyTimelineChangedDebounced(TimeSpan.FromMilliseconds(50));
        e.NotifyTimelineChangedDebounced(TimeSpan.FromMilliseconds(50));
        e.NotifyTimelineChangedDebounced(TimeSpan.FromMilliseconds(50));

        await Task.Delay(TimeSpan.FromMilliseconds(250));

        structural.ShouldBe(1);
    }

    [Fact]
    public async Task ImmediateNotifyCancelsAPendingDebounce()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;

        var structural = 0;
        e.StructuralChangeRequested += (_, _) => structural++;

        e.NotifyTimelineChangedDebounced(TimeSpan.FromMilliseconds(200));
        e.NotifyTimelineChanged(); // fires immediately and must cancel the pending debounce
        structural.ShouldBe(1);

        await Task.Delay(TimeSpan.FromMilliseconds(300));

        structural.ShouldBe(1); // the cancelled debounce must not fire a second time
    }
}
