using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests;

public sealed class AutomationModeTests
{
    [Fact]
    public void Enabled_IsFalseByDefault_SoCallersFallThroughToARealPicker()
    {
        using var _ = Scoped(_ => null);
        AutomationMode.Enabled.ShouldBeFalse();
    }

    [Theory]
    [InlineData("0")]
    [InlineData("true")]
    [InlineData("")]
    public void Enabled_IsFalseForAnythingOtherThanOne(string value)
    {
        using var _ = Scoped(v => v == AutomationMode.EnabledVariable ? value : null);
        AutomationMode.Enabled.ShouldBeFalse();
    }

    [Fact]
    public void Enabled_IsTrueWhenSetToOne()
    {
        using var _ = Scoped(v => v == AutomationMode.EnabledVariable ? "1" : null);
        AutomationMode.Enabled.ShouldBeTrue();
    }

    [Fact]
    public void NextOpenProjectPath_ConsumesQueueInOrder_ThenAnswersCancelOnExhaustion()
    {
        using var _ = Scoped(v => v == AutomationMode.OpenProjectVariable ? "A.palmier;B.palmier" : null);

        AutomationMode.NextOpenProjectPath().ShouldBe("A.palmier");
        AutomationMode.NextOpenProjectPath().ShouldBe("B.palmier");
        AutomationMode.NextOpenProjectPath().ShouldBeNull();
        AutomationMode.NextOpenProjectPath().ShouldBeNull();
    }

    [Fact]
    public void NextSavePath_AnswersCancel_WhenVariableIsUnset()
    {
        using var _ = Scoped(_ => null);
        AutomationMode.NextSavePath().ShouldBeNull();
    }

    [Fact]
    public void NextPickFolder_ConsumesQueueInOrder_ThenAnswersCancelOnExhaustion()
    {
        using var _ = Scoped(v => v == AutomationMode.PickFolderVariable ? @"C:\a;C:\b" : null);

        AutomationMode.NextPickFolder().ShouldBe(@"C:\a");
        AutomationMode.NextPickFolder().ShouldBe(@"C:\b");
        AutomationMode.NextPickFolder().ShouldBeNull();
    }

    [Fact]
    public void NextImportFiles_SplitsCommaGroupsAndConsumesGroupsInOrder()
    {
        using var _ = Scoped(v => v == AutomationMode.ImportFilesVariable ? "a.mp4,b.wav;c.png" : null);

        AutomationMode.NextImportFiles().ShouldBe(["a.mp4", "b.wav"]);
        AutomationMode.NextImportFiles().ShouldBe(["c.png"]);
        AutomationMode.NextImportFiles().ShouldBeNull();
    }

    [Fact]
    public void NextImportFiles_NeverReturnsAnEmptyList_ExhaustionMeansNull()
    {
        using var _ = Scoped(_ => null);
        AutomationMode.NextImportFiles().ShouldBeNull();
    }

    [Fact]
    public void DifferentVariables_EachKeepTheirOwnQueue()
    {
        using var _ = Scoped(v => v switch
        {
            AutomationMode.OpenProjectVariable => "Open.palmier",
            AutomationMode.SavePathVariable => @"C:\Projects\New",
            _ => null,
        });

        AutomationMode.NextSavePath().ShouldBe(@"C:\Projects\New");
        AutomationMode.NextOpenProjectPath().ShouldBe("Open.palmier");
        AutomationMode.NextPickFolder().ShouldBeNull();
    }

    /// Swaps in a scripted reader for the test's duration; disposing restores the real process
    /// environment and drops the queue cache so it doesn't leak into the next test.
    private static IDisposable Scoped(Func<string, string?> reader)
    {
        AutomationMode.EnvironmentReader = reader;
        AutomationMode.Reset();
        return new Restorer();
    }

    private sealed class Restorer : IDisposable
    {
        public void Dispose()
        {
            AutomationMode.EnvironmentReader = Environment.GetEnvironmentVariable;
            AutomationMode.Reset();
        }
    }
}
