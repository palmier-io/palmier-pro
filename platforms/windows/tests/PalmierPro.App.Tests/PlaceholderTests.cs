// ViewModel/logic tests only. Plain `dotnet test` has no WinUI host — never instantiate
// WinUI types (Window, Control, anything from Microsoft.UI.Xaml) in this project.

using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests;

public class PlaceholderTests
{
    [Fact]
    public void Placeholder_test_passes()
    {
        true.ShouldBeTrue();
    }
}
