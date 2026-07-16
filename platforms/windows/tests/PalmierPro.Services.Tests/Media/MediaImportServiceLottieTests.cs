using PalmierPro.Core.Models;
using PalmierPro.Rendering;
using PalmierPro.Services.Media;
using PalmierPro.Services.Project;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Media;

/// docs/lottie-bake-v1.md's owning slice's "MediaImportService accepting .json/.lottie as lottie
/// assets" requirement — `ClipTypeExtensions.TryFromFileExtension` already routed `.json`/`.lottie`
/// to `ClipType.Lottie` before this document (extension-only, no content sniff on Windows, unlike
/// the Mac's `LottieVideoGenerator.isLottie`); what this document's `EngineMediaProbe.ProbeLottieAsync`
/// implementation closes is the metadata-probe half — a `.json` that fails to parse as a Lottie
/// composition now correctly surfaces as "unreadable", not a null-metadata success.
public sealed class MediaImportServiceLottieTests
{
    // A trivial one-shape Lottie composition (same shape as the checked-in native-tests fixture,
    // inlined here to keep this test self-contained — no cross-project fixture dependency).
    private const string ValidLottieJson = """
        {
          "v": "5.5.2", "fr": 30, "ip": 0, "op": 30, "w": 100, "h": 100, "nm": "test-shape", "ddd": 0,
          "assets": [],
          "layers": [
            {
              "ddd": 0, "ind": 1, "ty": 4, "nm": "square", "sr": 1,
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [50, 50, 0] }, "a": { "a": 0, "k": [0, 0, 0] }, "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ao": 0,
              "shapes": [
                { "ty": "rc", "p": { "a": 0, "k": [0, 0] }, "s": { "a": 0, "k": [40, 40] }, "r": { "a": 0, "k": 0 } },
                { "ty": "fl", "c": { "a": 0, "k": [1, 0, 0, 1] }, "o": { "a": 0, "k": 100 } }
              ],
              "ip": 0, "op": 30, "st": 0, "bm": 0
            }
          ]
        }
        """;

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_PlainJsonLottieFile_ImportsAsLottieAssetWithProbedMetadata()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Lottie");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        string lottiePath = Path.Combine(tmp.Path, "shape.json");
        File.WriteAllText(lottiePath, ValidLottieJson);

        MediaImportSummary summary = await importer.ImportAsync(doc, [lottiePath]);

        summary.Failed.ShouldBeEmpty();
        MediaImportItem item = summary.Imported.ShouldHaveSingleItem();
        item.Asset.Type.ShouldBe(ClipType.Lottie);
        item.Asset.Duration.ShouldBe(1.0, 0.01);
        item.Asset.SourceWidth.ShouldBe(100);
        item.Asset.SourceHeight.ShouldBe(100);
        item.Asset.SourceFPS!.Value.ShouldBe(30.0, 0.01);

        MediaManifestEntry entry = doc.Manifest.Entries.ShouldHaveSingleItem();
        entry.Type.ShouldBe(ClipType.Lottie);
        entry.SourceWidth.ShouldBe(100);
        entry.SourceHeight.ShouldBe(100);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_CorruptJsonNamedLottie_FailsWithAPerFileError_NotAnUnobservedException()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Corrupt Lottie");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        string corruptPath = Path.Combine(tmp.Path, "not-a-lottie.json");
        File.WriteAllText(corruptPath, "{ this is not valid lottie JSON at all }");

        MediaImportSummary summary = await importer.ImportAsync(doc, [corruptPath]);

        summary.Imported.ShouldBeEmpty();
        MediaImportFailure failure = summary.Failed.ShouldHaveSingleItem();
        failure.Path.ShouldBe(corruptPath);
        doc.Manifest.Entries.ShouldBeEmpty();
    }
}
