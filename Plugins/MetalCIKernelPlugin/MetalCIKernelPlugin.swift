import Foundation
import PackagePlugin

/// Compiles Core Image Metal kernels (`Metal/*.metal`) into `.metallib` resources.
@main
struct MetalCIKernelPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let metalDir = context.package.directoryURL.appending(path: "Metal")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: metalDir.path()))?
            .filter { $0.hasSuffix(".metal") } ?? []

        return names.map { file in
            let stem = (file as NSString).deletingPathExtension
            let metal = metalDir.appending(path: file)
            let air = context.pluginWorkDirectoryURL.appending(path: "\(stem).air")
            let metallib = context.pluginWorkDirectoryURL.appending(path: "\(stem).metallib")
            return .buildCommand(
                displayName: "Compile CI kernel \(file)",
                executable: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "xcrun metal -c -fcikernel '\(metal.path())' -o '\(air.path())' && " +
                    "xcrun metallib -cikernel '\(air.path())' -o '\(metallib.path())'",
                ],
                inputFiles: [metal],
                outputFiles: [metallib])
        }
    }
}
