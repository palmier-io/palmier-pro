using PalmierPro.Core.Export;
using PalmierPro.Services.Export;

namespace PalmierPro.App.Services;

/// Composition point for the FCPXML/XMEML exporters (`PalmierPro.Services.Export`) landed in
/// Stage C. Stage F's Export dialog wires `DisabledMenuCommands.Export` to
/// `FcpxmlExporter`/`XmemlExporter`, passing these. Lazy: both shims touch OS state (a process
/// launch, the system font collection) a menu registration step shouldn't pay for before Export
/// is actually used.
public static class ExportServices
{
    private static readonly Lazy<ISourceTimingReader> LazySourceTimingReader = new(() => new FfprobeSourceTimingReader());
    private static readonly Lazy<IFontTraitResolver> LazyFontTraitResolver = new(() => new DirectWriteFontTraitResolver());

    public static ISourceTimingReader SourceTimingReader => LazySourceTimingReader.Value;
    public static IFontTraitResolver FontTraitResolver => LazyFontTraitResolver.Value;
}
