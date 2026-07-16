using System.Text.Json;
using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Covers TextViewModel — the Text tab's read-side shared-value resolution plus every edit's
/// routing through TimelineEditorViewModel's ApplyClipProperties/CommitClipProperties/
/// ApplyTextStyles/CommitTextStyles/RevertClipProperty. Each commit's dedicated
/// Document.UndoService.SetActionName(...) call (this class's own contract, distinct from
/// CommitClipProperties' generic "Change Clip Property" default that TransformViewModel relies on)
/// is the thing under test for every mutator below.
public class TextViewModelTests
{
    private static Clip TextClip(string id, string? content = null, TextStyle? style = null)
    {
        var c = EditorFixtures.Clip(id: id, mediaRef: "text", mediaType: ClipType.Text, start: 0, duration: 30);
        c.TextContent = content;
        c.TextStyle = JsonSerializer.SerializeToElement(style ?? new TextStyle());
        return c;
    }

    [Fact]
    public async Task IsBatchAndClipIdsReflectTheSelectionSize()
    {
        var a = TextClip("a", "one");
        var b = TextClip("b", "two");
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [a, b])]);
        using var _ = temp;

        var single = new TextViewModel(e, [e.ClipFor("a")!]);
        single.IsBatch.ShouldBeFalse();
        single.ClipIds.ShouldBe(["a"]);

        var batch = new TextViewModel(e, [e.ClipFor("a")!, e.ClipFor("b")!]);
        batch.IsBatch.ShouldBeTrue();
        batch.ClipIds.ShouldBe(["a", "b"]);
    }

    [Fact]
    public async Task ContentIsEmptyForABatchSelectionButReadableForASingleClip()
    {
        var a = TextClip("a", "hello");
        var b = TextClip("b", "world");
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [a, b])]);
        using var _ = temp;

        new TextViewModel(e, [e.ClipFor("a")!]).Content.ShouldBe("hello");
        new TextViewModel(e, [e.ClipFor("a")!, e.ClipFor("b")!]).Content.ShouldBe("");
    }

    [Fact]
    public async Task SharedFontPropertiesAreNullWhenTheSelectionDisagrees()
    {
        var a = TextClip("a", "one", new TextStyle { FontName = "Arial", FontSize = 48 });
        var b = TextClip("b", "two", new TextStyle { FontName = "Georgia", FontSize = 48 });
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [a, b])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("a")!, e.ClipFor("b")!]);

        vm.FontName.ShouldBeNull(); // disagree
        vm.FontSize.ShouldBe(48);   // agree
    }

    [Fact]
    public async Task ApplyAndCommitContentAreNoOpsForABatchSelection()
    {
        var a = TextClip("a", "one");
        var b = TextClip("b", "two");
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [a, b])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("a")!, e.ClipFor("b")!]);

        vm.ApplyContent("changed");
        vm.CommitContent("changed");

        e.ClipFor("a")!.TextContent.ShouldBe("one");
        e.ClipFor("b")!.TextContent.ShouldBe("two");
        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public async Task CommitContentUpdatesTheClipAndNamesTheUndoEditText()
    {
        var clip = TextClip("c1", "before");
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.CommitContent("after");

        e.ClipFor("c1")!.TextContent.ShouldBe("after");
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Edit Text");
    }

    [Fact]
    public async Task PreviewFontIsLiveAndCancelFontRevertsToTheOriginal()
    {
        var clip = TextClip("c1", "text", new TextStyle { FontName = "Helvetica-Bold" });
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);

        vm.PreviewFont("Georgia");
        vm.FontName.ShouldBe("Georgia");
        e.Document.UndoService.CanUndo.ShouldBeFalse();

        vm.CancelFont();

        // RevertClipProperty swaps in a fresh clone rather than mutating the live clip this vm
        // still holds (see TextViewModel's class doc on why it takes a Clip snapshot, not an id) —
        // production only sees the reverted value once InspectorView rebuilds the tab off a fresh
        // TextViewModel, which a re-resolved read here stands in for.
        new TextViewModel(e, [e.ClipFor("c1")!]).FontName.ShouldBe("Helvetica-Bold");
        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public async Task ChangeFontRegistersOneUndoNamedChangeFont()
    {
        var clip = TextClip("c1", "text", new TextStyle { FontName = "Helvetica-Bold" });
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ChangeFont("Georgia");

        vm.FontName.ShouldBe("Georgia");
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Font");
    }

    [Fact]
    public async Task SetBoldAndSetItalicBothRegisterChangeStyleUndo()
    {
        var clip = TextClip("c1", "text", new TextStyle { IsBold = false, IsItalic = false });
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);

        vm.SetBold(true);
        vm.IsBold.ShouldBe(true);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Style");

        vm.SetItalic(true);
        vm.IsItalic.ShouldBe(true);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Style");
    }

    [Fact]
    public async Task ApplySizeIsLiveAndCommitSizeRegistersOneUndoNamedChangeSize()
    {
        var clip = TextClip("c1", "text", new TextStyle { FontSize = 96 });
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ApplySize(60);
        vm.ApplySize(72);
        e.Document.UndoService.CanUndo.ShouldBeFalse();

        vm.CommitSize(80);

        vm.FontSize.ShouldBe(80);
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Size");
    }

    [Fact]
    public async Task ApplyOpacityAndCommitOpacityRegisterOneUndoNamedChangeOpacity()
    {
        var clip = TextClip("c1", "text");
        clip.Opacity = 1.0;
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);

        vm.ApplyOpacity(0.5);
        vm.CommitOpacity(0.4);

        vm.Opacity.ShouldBe(0.4);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Opacity");
    }

    [Fact]
    public async Task ApplyColorAndCommitColorRegisterOneUndoNamedChangeColor()
    {
        var clip = TextClip("c1", "text", new TextStyle { Color = new TextStyleRgba(1, 1, 1, 1) });
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);

        vm.ApplyColor(new TextStyleRgba(1, 0, 0, 1));
        vm.CommitColor(new TextStyleRgba(0, 1, 0, 1));

        vm.Color.G.ShouldBe(1);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Color");
    }

    [Fact]
    public async Task BackgroundBorderAndShadowTogglesEachUseTheirOwnActionName()
    {
        var clip = TextClip("c1", "text");
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);

        vm.SetBackgroundEnabled(true);
        vm.BackgroundEnabled.ShouldBeTrue();
        e.Document.UndoService.UndoActionName.ShouldBe("Change Background");

        vm.SetBorderEnabled(true);
        vm.BorderEnabled.ShouldBeTrue();
        e.Document.UndoService.UndoActionName.ShouldBe("Change Outline");

        vm.SetShadowEnabled(false);
        vm.ShadowEnabled.ShouldBeFalse();
        e.Document.UndoService.UndoActionName.ShouldBe("Change Shadow");
    }

    [Fact]
    public async Task SetAlignmentRegistersOneUndoNamedChangeAlignment()
    {
        var clip = TextClip("c1", "text", new TextStyle { Alignment = TextStyleAlignment.Center });
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);

        vm.SetAlignment(TextStyleAlignment.Right);

        vm.Alignment.ShouldBe(TextStyleAlignment.Right);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Alignment");
    }

    [Fact]
    public async Task ChangedFiresOnAnExternalStructuralChangeAndDisposeUnhooksIt()
    {
        var clip = TextClip("c1", "text");
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TextViewModel(e, [e.ClipFor("c1")!]);
        var fired = 0;
        vm.Changed += (_, _) => fired++;

        e.NotifyTimelineChanged();
        fired.ShouldBe(1);

        vm.Dispose();
        e.NotifyTimelineChanged();
        fired.ShouldBe(1); // unhooked — no further notifications
    }
}
