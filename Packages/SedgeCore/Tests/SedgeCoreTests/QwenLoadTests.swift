import Foundation
import MLX
import Testing
@testable import SedgeCore

// An MLX error while the weights load (on a phone, most likely running out of memory) must fail the
// load, not end the app. Opt-in like RealModel, since it reads the real weights from the Hugging Face cache:
//   TEST_RUNNER_SEDGE_REAL_MODEL=1 xcodebuild test -scheme SedgeCore -destination 'platform=macOS,arch=arm64' \
//     -derivedDataPath ../../build/dd-core -only-testing:SedgeCoreTests/QwenLoadErrors
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SEDGE_REAL_MODEL"] == "1"), .serialized)
struct QwenLoadErrors {
    /// The baseline: an MLX error on the calling task is caught by withError.
    @Test func anErrorOnTheCallingTaskThrows() async {
        await #expect(throws: (any Error).self) {
            try await withError { () async throws -> Void in
                let a = MLXArray([1, 2, 3]), b = MLXArray([1, 2, 3, 4])
                eval(a + b)
            }
        }
    }

    /// A weights file holding one tensor too big for any Metal buffer (a sparse file, so it takes no disk),
    /// so MLX's malloc fails while mlx-swift-lm reads the weights on its background threads, off the
    /// calling task: the same failure a phone short of memory gives ("[malloc] Unable to allocate").
    @Test func aFailedAllocationFailsTheLoad() async throws {
        let folder = try linkedWeights(except: "model.safetensors")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Twice the Mac's memory is always more than one buffer may hold. Two dimensions, since MLX's are 32-bit.
        let rows = ProcessInfo.processInfo.physicalMemory * 2 / 65_536, size = rows * 65_536
        let header = Data(#"{"huge": {"dtype": "U8", "shape": [\#(rows), 65536], "data_offsets": [0, \#(size)]}}"#.utf8)
        // A safetensors file starts with its header's length (8 bytes, little-endian), then the header.
        let length = withUnsafeBytes(of: UInt64(header.count).littleEndian) { Data($0) }
        let file = folder.appending(path: "model.safetensors")
        try (length + header).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(length.count + header.count) + size)
        try handle.close()
        await #expect(throws: (any Error).self) { try await QwenModel.load(from: folder) }
    }

    /// A temporary folder with links to the real weight files, all but `skipped`.
    private func linkedWeights(except skipped: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "qwen_load_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: cachedWeights.path) where name != skipped {
            try FileManager.default.createSymbolicLink(at: folder.appending(path: name),
                                                       withDestinationURL: cachedWeights.appending(path: name).resolvingSymlinksInPath())
        }
        return folder
    }
}
