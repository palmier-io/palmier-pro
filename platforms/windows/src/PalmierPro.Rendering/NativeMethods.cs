using System.Runtime.InteropServices;

namespace PalmierPro.Rendering;

// Flat C ABI surface for PalmierEngine.dll (built via native/PalmierEngine.vcxproj, not the dotnet CLI).
internal static partial class NativeMethods
{
    private const string EngineLibrary = "PalmierEngine.dll";

    [LibraryImport(EngineLibrary)]
    internal static partial uint PalmierEngine_GetVersion();
}
