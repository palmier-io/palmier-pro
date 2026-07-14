using PalmierPro.Core.Undo;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Exercises UndoService against the Mac's actual NSUndoManager usage patterns —
/// see EditorViewModel+ClipMutations.swift (registerTimelineSwap / withTimelineSwap).
public class UndoServiceTests
{
    // MARK: Basic register / undo / redo

    [Fact]
    public void FreshServiceCannotUndoOrRedo()
    {
        var svc = new UndoService();
        svc.CanUndo.ShouldBeFalse();
        svc.CanRedo.ShouldBeFalse();
        svc.UndoActionName.ShouldBeNull();
        svc.RedoActionName.ShouldBeNull();
    }

    [Fact]
    public void RegisterUndoPushesOntoUndoStack()
    {
        var svc = new UndoService();
        svc.RegisterUndo("Do Thing", () => { });
        svc.CanUndo.ShouldBeTrue();
        svc.CanRedo.ShouldBeFalse();
        svc.UndoActionName.ShouldBe("Do Thing");
    }

    [Fact]
    public void UndoInvokesTheRegisteredHandler()
    {
        var svc = new UndoService();
        var invoked = false;
        svc.RegisterUndo("Do Thing", () => invoked = true);
        svc.Undo();
        invoked.ShouldBeTrue();
    }

    [Fact]
    public void UndoWithEmptyStackIsANoOp()
    {
        var svc = new UndoService();
        Should.NotThrow(() => svc.Undo());
        svc.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public void RedoWithEmptyStackIsANoOp()
    {
        var svc = new UndoService();
        Should.NotThrow(() => svc.Redo());
        svc.CanRedo.ShouldBeFalse();
    }

    // MARK: The swap pattern — a handler re-registers its own inverse

    /// Mirrors registerTimelineSwap: the undo handler flips the state back AND immediately
    /// re-registers the opposite swap, so undo/redo can alternate indefinitely.
    private static void RegisterSwap(UndoService svc, int[] state, int undoValue, int redoValue, string actionName)
    {
        svc.RegisterUndo(actionName, () =>
        {
            state[0] = undoValue;
            RegisterSwap(svc, state, redoValue, undoValue, actionName);
        });
        svc.SetActionName(actionName);
    }

    [Fact]
    public void SwapPatternSingleUndoRedoCycle()
    {
        var svc = new UndoService();
        var state = new[] { 0 };

        state[0] = 1;
        RegisterSwap(svc, state, undoValue: 0, redoValue: 1, actionName: "Set To 1");

        svc.Undo();
        state[0].ShouldBe(0);
        svc.CanUndo.ShouldBeFalse();
        svc.CanRedo.ShouldBeTrue();
        svc.RedoActionName.ShouldBe("Set To 1");

        svc.Redo();
        state[0].ShouldBe(1);
        svc.CanUndo.ShouldBeTrue();
        svc.CanRedo.ShouldBeFalse();
        svc.UndoActionName.ShouldBe("Set To 1");
    }

    [Fact]
    public void SwapPatternSurvivesManyUndoRedoCycles()
    {
        var svc = new UndoService();
        var state = new[] { 0 };
        state[0] = 1;
        RegisterSwap(svc, state, undoValue: 0, redoValue: 1, actionName: "Set To 1");

        for (var cycle = 0; cycle < 25; cycle++)
        {
            svc.Undo();
            state[0].ShouldBe(0);
            svc.Redo();
            state[0].ShouldBe(1);
        }

        svc.CanUndo.ShouldBeTrue();
        svc.CanRedo.ShouldBeFalse();
    }

    [Fact]
    public void SwapPatternCanUndoAgainAfterRedo()
    {
        var svc = new UndoService();
        var state = new[] { 0 };
        state[0] = 1;
        RegisterSwap(svc, state, undoValue: 0, redoValue: 1, actionName: "Set To 1");

        svc.Undo();
        svc.Redo();
        svc.Undo();

        state[0].ShouldBe(0);
        svc.CanUndo.ShouldBeFalse();
        svc.CanRedo.ShouldBeTrue();
    }

    // MARK: Grouping

    [Fact]
    public void GroupedRegistrationsCollapseToOneUndoStep()
    {
        var svc = new UndoService();
        var log = new List<string>();

        svc.BeginGrouping();
        svc.RegisterUndo("Split Clips", () => log.Add("undo-1"));
        svc.RegisterUndo("Split Clips", () => log.Add("undo-2"));
        svc.RegisterUndo("Split Clips", () => log.Add("undo-3"));
        svc.EndGrouping();
        svc.SetActionName("Split Clips");

        svc.CanUndo.ShouldBeTrue();
        svc.UndoActionName.ShouldBe("Split Clips");

        svc.Undo();
        svc.CanUndo.ShouldBeFalse(); // the whole group undid as a single step

        // Handlers run in reverse registration order (LIFO), matching NSUndoManager.
        log.ShouldBe(["undo-3", "undo-2", "undo-1"]);
    }

    [Fact]
    public void NestedGroupsCollapseToOneUndoStep()
    {
        var svc = new UndoService();
        var log = new List<string>();

        svc.BeginGrouping();
        svc.RegisterUndo("Outer", () => log.Add("a"));
        svc.BeginGrouping();
        svc.RegisterUndo("Outer", () => log.Add("b"));
        svc.RegisterUndo("Outer", () => log.Add("c"));
        svc.EndGrouping(); // inner end: must NOT push yet
        svc.CanUndo.ShouldBeFalse();
        svc.RegisterUndo("Outer", () => log.Add("d"));
        svc.EndGrouping(); // outer end: pushes the whole nested group as one step

        svc.CanUndo.ShouldBeTrue();
        svc.Undo();
        svc.CanUndo.ShouldBeFalse();
        log.ShouldBe(["d", "c", "b", "a"]);
    }

    [Fact]
    public void EmptyGroupPushesNothing()
    {
        var svc = new UndoService();
        svc.BeginGrouping();
        svc.EndGrouping();
        svc.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public void GroupActionNameDefaultsToFirstRegisteredName()
    {
        var svc = new UndoService();
        svc.BeginGrouping();
        svc.RegisterUndo("First Name", () => { });
        svc.RegisterUndo("Second Name", () => { });
        svc.EndGrouping();
        svc.UndoActionName.ShouldBe("First Name");
    }

    [Fact]
    public void ExplicitSetActionNameOverridesTheDefault()
    {
        var svc = new UndoService();
        svc.BeginGrouping();
        svc.RegisterUndo("First Name", () => { });
        svc.SetActionName("Explicit Name");
        svc.RegisterUndo("Third Name", () => { }); // must not clobber the explicit name
        svc.EndGrouping();
        svc.UndoActionName.ShouldBe("Explicit Name");
    }

    [Fact]
    public void EndGroupingWithoutBeginThrows()
    {
        var svc = new UndoService();
        Should.Throw<InvalidOperationException>(() => svc.EndGrouping());
    }

    [Fact]
    public void UndoWhileGroupIsOpenThrows()
    {
        var svc = new UndoService();
        svc.BeginGrouping();
        Should.Throw<InvalidOperationException>(() => svc.Undo());
    }

    [Fact]
    public void RedoWhileGroupIsOpenThrows()
    {
        var svc = new UndoService();
        svc.BeginGrouping();
        Should.Throw<InvalidOperationException>(() => svc.Redo());
    }

    /// A grouped multi-step edit must redo/undo as one unit too — mirrors splitClips being
    /// reversible and re-appliable any number of times via the same swap-inside-a-group pattern.
    /// The handlers are tag-free (fixed log entries) so the same assertion holds every cycle —
    /// each Undo()/Redo() re-registers a fresh two-handler group via the swap pattern.
    [Fact]
    public void GroupedSwapSurvivesMultipleUndoRedoCycles()
    {
        var svc = new UndoService();
        var log = new List<string>();

        void RegisterGroupedSwap()
        {
            svc.BeginGrouping();
            svc.RegisterUndo("Grouped", () =>
            {
                log.Add("h1");
                RegisterGroupedSwap();
            });
            svc.RegisterUndo("Grouped", () =>
            {
                log.Add("h2");
            });
            svc.EndGrouping();
            svc.SetActionName("Grouped");
        }

        RegisterGroupedSwap();

        for (var i = 0; i < 3; i++)
        {
            log.Clear();
            svc.Undo();
            // Reverse registration order within the group: h2 (registered second) runs first.
            log.ShouldBe(["h2", "h1"]);
            svc.CanUndo.ShouldBeFalse();
            svc.CanRedo.ShouldBeTrue();

            log.Clear();
            svc.Redo();
            log.ShouldBe(["h2", "h1"]);
            svc.CanUndo.ShouldBeTrue();
            svc.CanRedo.ShouldBeFalse();
        }
    }

    // MARK: GroupsByEvent / FlushEventGrouping

    [Fact]
    public void GroupsByEventDefaultsToFalse()
    {
        // No run loop exists to auto-close the ambient group, so every RegisterUndo call site
        // written before this property existed must keep committing immediately.
        new UndoService().GroupsByEvent.ShouldBeFalse();
    }

    [Fact]
    public void EventGroupingCoalescesMultipleBareRegistrations()
    {
        var svc = new UndoService { GroupsByEvent = true };
        var log = new List<string>();

        svc.RegisterUndo("A", () => log.Add("a"));
        svc.RegisterUndo("B", () => log.Add("b"));
        svc.CanUndo.ShouldBeFalse(); // still pending — not yet flushed

        svc.FlushEventGrouping();
        svc.CanUndo.ShouldBeTrue();

        svc.Undo();
        svc.CanUndo.ShouldBeFalse(); // one step undid both registrations
        log.ShouldBe(["b", "a"]); // LIFO, same as an explicit group
    }

    [Fact]
    public void EventGroupingCoalescesSeparateExplicitGroups()
    {
        // Mirrors splitAtPlayhead: a loop where each iteration opens/closes its own undo group.
        var svc = new UndoService { GroupsByEvent = true };
        var log = new List<string>();

        void RegisterOneSplit(string tag)
        {
            svc.BeginGrouping();
            svc.RegisterUndo("Split", () => log.Add(tag));
            svc.EndGrouping();
        }

        RegisterOneSplit("clip-1");
        RegisterOneSplit("clip-2");
        RegisterOneSplit("clip-3");
        svc.CanUndo.ShouldBeFalse(); // each EndGrouping pushed into the event group, not the stack

        svc.FlushEventGrouping();
        svc.CanUndo.ShouldBeTrue();

        svc.Undo();
        svc.CanUndo.ShouldBeFalse(); // a single Undo() reverses all three splits
        log.ShouldBe(["clip-3", "clip-2", "clip-1"]);
    }

    [Fact]
    public void FlushEventGroupingIsNoOpWhenNothingPending()
    {
        var svc = new UndoService { GroupsByEvent = true };
        Should.NotThrow(() => svc.FlushEventGrouping());
        svc.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public void DisablingGroupsByEventFlushesPendingRegistrations()
    {
        var svc = new UndoService { GroupsByEvent = true };
        svc.RegisterUndo("A", () => { });
        svc.CanUndo.ShouldBeFalse();

        svc.GroupsByEvent = false; // must not silently drop the pending registration
        svc.CanUndo.ShouldBeTrue();
    }

    [Fact]
    public void EventGroupActionNameDefaultsToFirstRegisteredAcrossMerges()
    {
        var svc = new UndoService { GroupsByEvent = true };
        svc.RegisterUndo("First", () => { });
        svc.RegisterUndo("Second", () => { });
        svc.FlushEventGrouping();
        svc.UndoActionName.ShouldBe("First");
    }

    [Fact]
    public void SetActionNameTargetsThePendingEventGroup()
    {
        var svc = new UndoService { GroupsByEvent = true };
        svc.RegisterUndo("Default", () => { });
        svc.SetActionName("Split Clips");
        svc.RegisterUndo("Ignored", () => { }); // must not clobber the explicit name
        svc.FlushEventGrouping();
        svc.UndoActionName.ShouldBe("Split Clips");
    }

    [Fact]
    public void EventGroupingClearsRedoStackAsSoonAsRegistrationStartsAccumulating()
    {
        var svc = new UndoService { GroupsByEvent = true };
        var state = new[] { 0 };
        state[0] = 1;
        RegisterSwap(svc, state, undoValue: 0, redoValue: 1, actionName: "A");
        svc.FlushEventGrouping();
        svc.Undo();
        svc.CanRedo.ShouldBeTrue();

        svc.RegisterUndo("B", () => { }); // new action still accumulating, not yet flushed
        svc.CanRedo.ShouldBeFalse();
    }

    [Fact]
    public void EventGroupingWithGroupsByEventFalseCommitsImmediately()
    {
        var svc = new UndoService();
        svc.RegisterUndo("A", () => { });
        svc.CanUndo.ShouldBeTrue(); // unchanged legacy behavior
    }

    // MARK: Disable / enable registration (nested)

    [Fact]
    public void DisabledRegistrationIsANoOp()
    {
        var svc = new UndoService();
        svc.DisableRegistration();
        svc.RegisterUndo("Ignored", () => { });
        svc.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public void IsRegistrationEnabledReflectsDisableState()
    {
        var svc = new UndoService();
        svc.IsRegistrationEnabled.ShouldBeTrue();
        svc.DisableRegistration();
        svc.IsRegistrationEnabled.ShouldBeFalse();
        svc.EnableRegistration();
        svc.IsRegistrationEnabled.ShouldBeTrue();
    }

    [Fact]
    public void NestedDisableRequiresMatchingEnableCount()
    {
        var svc = new UndoService();
        svc.DisableRegistration();
        svc.DisableRegistration();
        svc.EnableRegistration();
        svc.IsRegistrationEnabled.ShouldBeFalse(); // one disable still outstanding

        svc.RegisterUndo("Ignored", () => { });
        svc.CanUndo.ShouldBeFalse();

        svc.EnableRegistration();
        svc.IsRegistrationEnabled.ShouldBeTrue();
        svc.RegisterUndo("Allowed", () => { });
        svc.CanUndo.ShouldBeTrue();
    }

    /// Mirrors withTimelineSwap: an outer disable must keep registration off even after an
    /// inner call's own enable, so the inner call's mutation gets folded into the outer diff
    /// instead of registering its own (redundant, and wrong-grained) undo step.
    [Fact]
    public void NestedDisableEnableMatchesWithTimelineSwapPattern()
    {
        var svc = new UndoService();
        var registrations = 0;

        void InnerMutation()
        {
            svc.DisableRegistration();
            // ... inner work that would otherwise register its own undo ...
            svc.EnableRegistration();
            if (svc.IsRegistrationEnabled)
            {
                svc.RegisterUndo("Inner", () => { });
                registrations++;
            }
        }

        svc.DisableRegistration();
        InnerMutation();
        svc.EnableRegistration();

        registrations.ShouldBe(0);
        svc.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public void ExtraEnableRegistrationBeyondZeroDoesNotUnderflow()
    {
        var svc = new UndoService();
        svc.EnableRegistration(); // no matching disable
        svc.IsRegistrationEnabled.ShouldBeTrue();
        svc.RegisterUndo("Ok", () => { });
        svc.CanUndo.ShouldBeTrue();
    }

    // MARK: Redo-stack clearing

    [Fact]
    public void NewTopLevelRegistrationClearsRedoStack()
    {
        var svc = new UndoService();
        var state = new[] { 0 };
        state[0] = 1;
        RegisterSwap(svc, state, undoValue: 0, redoValue: 1, actionName: "A"); // handler re-registers, so Undo() leaves a redo entry
        svc.Undo();
        svc.CanRedo.ShouldBeTrue();

        svc.RegisterUndo("B", () => { });
        svc.CanRedo.ShouldBeFalse();
        svc.CanUndo.ShouldBeTrue();
        svc.UndoActionName.ShouldBe("B");
    }

    [Fact]
    public void NewGroupedRegistrationClearsRedoStack()
    {
        var svc = new UndoService();
        var state = new[] { 0 };
        state[0] = 1;
        RegisterSwap(svc, state, undoValue: 0, redoValue: 1, actionName: "A");
        svc.Undo();
        svc.CanRedo.ShouldBeTrue();

        svc.BeginGrouping();
        svc.RegisterUndo("B", () => { });
        svc.EndGrouping();
        svc.CanRedo.ShouldBeFalse();
    }

    [Fact]
    public void SwapPatternRegistrationDuringUndoDoesNotClearRedoStack()
    {
        // Two independent undoable actions; undoing the top one re-registers onto redo via the
        // swap pattern and must not wipe the *other* action still sitting on the undo stack.
        var svc = new UndoService();
        svc.RegisterUndo("First", () => { });

        var state = new[] { 0 };
        state[0] = 1;
        RegisterSwap(svc, state, undoValue: 0, redoValue: 1, actionName: "Second");

        svc.Undo(); // undoes "Second", registers its inverse onto the redo stack
        svc.CanRedo.ShouldBeTrue();
        svc.CanUndo.ShouldBeTrue();
        svc.UndoActionName.ShouldBe("First");
    }

    // MARK: Action names

    [Fact]
    public void SetActionNameOnEmptyStackIsANoOp()
    {
        var svc = new UndoService();
        Should.NotThrow(() => svc.SetActionName("Nothing To Name"));
        svc.UndoActionName.ShouldBeNull();
    }

    [Fact]
    public void SetActionNameRetargetsAfterAnUngroupedRegistration()
    {
        var svc = new UndoService();
        svc.RegisterUndo("Default Name", () => { });
        svc.SetActionName("Renamed");
        svc.UndoActionName.ShouldBe("Renamed");
    }

    [Fact]
    public void RedoActionNameReflectsTopOfRedoStack()
    {
        var svc = new UndoService();
        svc.RegisterUndo("Only Action", () => { });
        svc.Undo();
        svc.RedoActionName.ShouldBeNull(); // handler didn't re-register — nothing to redo
        svc.CanRedo.ShouldBeFalse();
    }

    // MARK: Changed event

    [Fact]
    public void ChangedFiresOnRegisterUndo()
    {
        var svc = new UndoService();
        var count = 0;
        svc.Changed += (_, _) => count++;
        svc.RegisterUndo("A", () => { });
        count.ShouldBe(1);
    }

    [Fact]
    public void ChangedDoesNotFireWhileGroupingIsOpen()
    {
        var svc = new UndoService();
        var count = 0;
        svc.Changed += (_, _) => count++;
        svc.BeginGrouping();
        svc.RegisterUndo("A", () => { });
        svc.RegisterUndo("B", () => { });
        count.ShouldBe(0);
        svc.EndGrouping();
        count.ShouldBe(1);
    }

    [Fact]
    public void ChangedFiresTwiceForASwapUndoCycle()
    {
        // Once for the pop off the undo stack, once for the re-registration landing on redo.
        var svc = new UndoService();
        var state = new[] { 0 };
        state[0] = 1;
        RegisterSwap(svc, state, undoValue: 0, redoValue: 1, actionName: "Set To 1");

        var count = 0;
        svc.Changed += (_, _) => count++;
        svc.Undo();
        count.ShouldBe(2);
    }

    [Fact]
    public void ChangedDoesNotFireWhenUndoStackIsEmpty()
    {
        var svc = new UndoService();
        var count = 0;
        svc.Changed += (_, _) => count++;
        svc.Undo();
        svc.Redo();
        count.ShouldBe(0);
    }

    [Fact]
    public void ChangedFiresOnSetActionNameWhenItMutatesTheTopGroup()
    {
        var svc = new UndoService();
        svc.RegisterUndo("A", () => { });
        var count = 0;
        svc.Changed += (_, _) => count++;
        svc.SetActionName("Renamed");
        count.ShouldBe(1);
    }

    [Fact]
    public void ChangedDoesNotFireOnDisableOrEnableRegistration()
    {
        var svc = new UndoService();
        var count = 0;
        svc.Changed += (_, _) => count++;
        svc.DisableRegistration();
        svc.EnableRegistration();
        count.ShouldBe(0);
    }

    // MARK: IsUndoing / IsRedoing

    [Fact]
    public void IsUndoingIsTrueOnlyDuringUndo()
    {
        var svc = new UndoService();
        var observed = false;
        svc.RegisterUndo("A", () => observed = svc.IsUndoing);

        svc.IsUndoing.ShouldBeFalse();
        svc.Undo();
        observed.ShouldBeTrue();
        svc.IsUndoing.ShouldBeFalse();
    }

    [Fact]
    public void IsRedoingIsTrueOnlyDuringRedo()
    {
        var svc = new UndoService();
        bool? observedDuringRedo = null;
        svc.RegisterUndo("A", () =>
        {
            // This is the undo handler; it re-registers the redo action, which observes IsRedoing.
            svc.RegisterUndo("A-redo", () => observedDuringRedo = svc.IsRedoing);
        });

        svc.Undo();
        svc.IsRedoing.ShouldBeFalse();

        svc.Redo();
        observedDuringRedo.ShouldBe(true);
        svc.IsRedoing.ShouldBeFalse();
    }
}
