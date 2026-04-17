import Foundation
import CoreVideo
import simd

struct DepthExportedFile: Identifiable {
    let url: URL
    let frameCount: Int

    var id: String { url.path }
}

final class DepthFileRecorder {
    private let queue = DispatchQueue(label: "assistnav.depth-export", qos: .utility)

    private var fileHandle: FileHandle?
    private var outputURL: URL?
    private var frameCount = 0
    private var lastWrittenTimestamp: TimeInterval = 0
    private var maxFPS: Double = 15
    private var includeRGB = false
    private var jpegQuality = 0.55

    var isRecording: Bool {
        queue.sync { fileHandle != nil }
    }

    func start(maxFPS: Double = 15, includeRGB: Bool = false, jpegQuality: Double = 0.55) throws {
        try queue.sync {
            try stopLocked()

            let exportsDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AssistNavDepthExports", isDirectory: true)
            try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let fileURL = exportsDirectory.appendingPathComponent("DepthExport-\(timestamp).andepth")

            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: fileURL)

            self.fileHandle = handle
            self.outputURL = fileURL
            self.frameCount = 0
            self.lastWrittenTimestamp = 0
            self.maxFPS = maxFPS
            self.includeRGB = includeRGB
            self.jpegQuality = jpegQuality

            var header = Data()
            header.append(contentsOf: "ANPK".utf8)
            header.appendLE(UInt16(1))
            header.appendLE(UInt16(0))
            try handle.write(contentsOf: header)
        }
    }

    func appendFrame(
        depth: CVPixelBuffer,
        confidence: CVPixelBuffer?,
        rgb: CVPixelBuffer?,
        intrinsics: simd_float3x3?,
        referenceResolution: CGSize?,
        timestamp: TimeInterval
    ) {
        queue.async {
            guard let handle = self.fileHandle else { return }

            let minInterval = 1.0 / max(1.0, self.maxFPS)
            if timestamp - self.lastWrittenTimestamp < minInterval {
                return
            }

            let packet = DepthPacketBuilder.build(
                depth: depth,
                confidence: confidence,
                rgb: self.includeRGB ? rgb : nil,
                intrinsics: intrinsics,
                referenceResolution: referenceResolution,
                timestamp: timestamp,
                jpegQuality: self.jpegQuality
            )
            guard !packet.isEmpty else { return }

            self.lastWrittenTimestamp = timestamp
            self.frameCount += 1

            var record = Data()
            record.append(contentsOf: "FRAM".utf8)
            record.appendLE(UInt32(packet.count))
            record.append(packet)

            do {
                try handle.write(contentsOf: record)
            } catch {
                try? self.stopLocked()
            }
        }
    }

    func stop(completion: @escaping (DepthExportedFile?) -> Void) {
        queue.async {
            let exported = self.stopAndBuildResult()
            DispatchQueue.main.async {
                completion(exported)
            }
        }
    }

    private func stopAndBuildResult() -> DepthExportedFile? {
        let url = outputURL
        let frames = frameCount
        try? stopLocked()

        guard let url, frames > 0 else {
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }

        return DepthExportedFile(url: url, frameCount: frames)
    }

    private func stopLocked() throws {
        try fileHandle?.close()
        fileHandle = nil
        outputURL = nil
        frameCount = 0
        lastWrittenTimestamp = 0
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
