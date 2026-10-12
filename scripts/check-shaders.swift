// Syntax-checks Strays' Metal shaders without the Metal toolchain.
//
//   swift scripts/check-shaders.swift
//
// The offline compiler (`xcrun metal`) is a separate download since
// Xcode 26, but macOS can always compile shader source at run time. This
// feeds the source through that compiler, with SwiftUI's small header
// inlined, to catch mistakes before a release build does.

import Foundation
import Metal

let swiftUIHeader = """
namespace SwiftUI {
struct Layer {
  metal::texture2d<half> tex;
  float2 info[5];
  half4 sample(float2 p) const {
    p = metal::fma(p.x, info[0], metal::fma(p.y, info[1], info[2]));
    p = metal::clamp(p, info[3], info[4]);
    return tex.sample(metal::sampler(metal::filter::linear), p);
  }
};
}
"""

guard let device = MTLCreateSystemDefaultDevice() else {
    print("No Metal device; cannot check shaders here.")
    exit(0)
}

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Strays/Shaders")
let shaders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension == "metal" } ?? []
guard !shaders.isEmpty else {
    print("No .metal files in \(directory.path)")
    exit(1)
}

var failed = false
for shader in shaders.sorted(by: { $0.path < $1.path }) {
    let source = try String(contentsOf: shader, encoding: .utf8)
        .replacingOccurrences(of: "#include <SwiftUI/SwiftUI_Metal.h>", with: swiftUIHeader)
    let options = MTLCompileOptions()
    options.languageVersion = .version3_1
    do {
        let library = try device.makeLibrary(source: source, options: options)
        print("ok      \(shader.lastPathComponent): \(library.functionNames.sorted().joined(separator: ", "))")
    } catch {
        failed = true
        print("FAILED  \(shader.lastPathComponent)\n\(error.localizedDescription)")
    }
}
exit(failed ? 1 : 0)
