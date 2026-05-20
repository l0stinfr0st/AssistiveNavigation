import Foundation
import Network
import CoreVideo
import simd

@MainActor
final class DepthStreamingSettings: ObservableObject {
    static let shared = DepthStreamingSettings()

    @Published var enabled: Bool { didSet { save() } }
    @Published var host: String { didSet { save() } }
    @Published var port: Int { didSet { save() } }
    @Published var maxFPS: Double { didSet { save() } }

    private init() {
        let d = UserDefaults.standard
        let storedPort = d.integer(forKey: Keys.port)
        let storedMaxFPS = d.double(forKey: Keys.maxFPS)

        enabled = d.bool(forKey: Keys.enabled)
        host = d.string(forKey: Keys.host) ?? "192.168.1.2"
        port = storedPort == 0 ? 5050 : storedPort
        if !d.bool(forKey: Keys.migratedDefaultMaxFPS), storedMaxFPS == 30 {
            maxFPS = 60
            d.set(true, forKey: Keys.migratedDefaultMaxFPS)
            d.set(maxFPS, forKey: Keys.maxFPS)
        } else {
            maxFPS = storedMaxFPS == 0 ? 60 : storedMaxFPS
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: Keys.enabled)
        d.set(host, forKey: Keys.host)
        d.set(port, forKey: Keys.port)
        d.set(maxFPS, forKey: Keys.maxFPS)
    }

    private enum Keys {
        static let enabled = "depth_streaming.enabled"
        static let host = "depth_streaming.host"
        static let port = "depth_streaming.port"
        static let maxFPS = "depth_streaming.max_fps"
        static let migratedDefaultMaxFPS = "depth_streaming.max_fps_default_migrated_v2"
    }
}

/// Streams frames over UDP to a laptop receiver.
///
/// Packet format (little-endian):
/// - magic: 4 bytes "ANDF"
/// - version: UInt16 (3)
/// - flags: UInt16 (bit0: hasConfidence, bit2: hasCameraPose)
/// - depthWidth: UInt16
/// - depthHeight: UInt16
/// - reservedWidth: UInt16 (0)
/// - reservedHeight: UInt16 (0)
/// - calibrationWidth: UInt16
/// - calibrationHeight: UInt16
/// - timestamp: Float64 (seconds)
/// - intrinsics: 9 Float32 (row-major)
/// - cameraTransform: 16 Float32 (row-major ARKit camera-to-world, v3+)
/// - depthBytes: UInt32
/// - confBytes: UInt32
/// - reservedBytes: UInt32 (0)
/// - payload: depth(Float32 meters) + confidence(UInt8)
///
final class DepthFrameStreamer {
    private var conn: NWConnection?
    private var lastSentAt: TimeInterval = 0

    func setEnabled(_ enabled: Bool, host: String, port: Int) {
        if enabled {
            start(host: host, port: port)
        } else {
            stop()
        }
    }

    private func start(host: String, port: Int) {
        stop()
        guard let p = NWEndpoint.Port(rawValue: UInt16(max(1, min(65535, port)))) else { return }
        let h = NWEndpoint.Host(host)
        let c = NWConnection(host: h, port: p, using: .udp)
        c.stateUpdateHandler = { _ in }
        c.start(queue: .global(qos: .userInitiated))
        conn = c
    }

    private func stop() {
        conn?.cancel()
        conn = nil
        lastSentAt = 0
    }

    func maybeSend(
        depth: CVPixelBuffer,
        confidence: CVPixelBuffer?,
        intrinsics: simd_float3x3?,
        referenceResolution: CGSize?,
        cameraTransform: simd_float4x4?,
        timestamp: TimeInterval,
        maxFPS: Double
    ) {
        guard let conn else { return }
        let minInterval = 1.0 / max(1.0, maxFPS)
        if timestamp - lastSentAt < minInterval { return }
        lastSentAt = timestamp

        let packet = DepthPacketBuilder.build(
            depth: depth,
            confidence: confidence,
            intrinsics: intrinsics,
            referenceResolution: referenceResolution,
            cameraTransform: cameraTransform,
            timestamp: timestamp
        )
        guard !packet.isEmpty else { return }

        let chunkSize = 1200
        let totalChunks = Int(ceil(Double(packet.count) / Double(chunkSize)))
        let frameId = UInt32.random(in: 1...UInt32.max)

        for idx in 0..<totalChunks {
            let start = idx * chunkSize
            let end = min(packet.count, start + chunkSize)
            let slice = packet.subdata(in: start..<end)
            var datagram = Data()
            datagram.append(contentsOf: "CHNK".utf8)
            datagram.appendLE(frameId)
            datagram.appendLE(UInt16(totalChunks))
            datagram.appendLE(UInt16(idx))
            datagram.append(slice)
            conn.send(content: datagram, completion: .contentProcessed { _ in })
        }
    }
}

enum DepthPacketBuilder {
    static func build(
        depth: CVPixelBuffer,
        confidence: CVPixelBuffer?,
        intrinsics: simd_float3x3?,
        referenceResolution: CGSize?,
        cameraTransform: simd_float4x4?,
        timestamp: TimeInterval
    ) -> Data {
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 else { return Data() }

        let dw = CVPixelBufferGetWidth(depth)
        let dh = CVPixelBufferGetHeight(depth)

        let hasConf = (confidence != nil)
        var flags: UInt16 = 0
        if hasConf { flags |= 1 << 0 }
        if cameraTransform != nil { flags |= 1 << 2 }

        let calibrationW = UInt16(max(0, min(65535, Int(referenceResolution?.width ?? CGFloat(dw)))))
        let calibrationH = UInt16(max(0, min(65535, Int(referenceResolution?.height ?? CGFloat(dh)))))

        let depthBytes = depthToData(depth)
        let confBytes = confidence.flatMap(confidenceToData) ?? Data()

        var out = Data()
        out.append(contentsOf: "ANDF".utf8)
        out.appendLE(UInt16(3)) // version
        out.appendLE(flags)
        out.appendLE(UInt16(dw))
        out.appendLE(UInt16(dh))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(calibrationW)
        out.appendLE(calibrationH)
        out.appendLE(timestamp)

        let K = intrinsics ?? matrix_identity_float3x3
        appendMatrix3x3RowMajor(K, to: &out)
        appendMatrix4x4RowMajor(cameraTransform ?? matrix_identity_float4x4, to: &out)

        out.appendLE(UInt32(depthBytes.count))
        out.appendLE(UInt32(confBytes.count))
        out.appendLE(UInt32(0))
        out.append(depthBytes)
        out.append(confBytes)
        return out
    }

    private static func appendMatrix3x3RowMajor(_ matrix: simd_float3x3, to data: inout Data) {
        for row in 0..<3 {
            for column in 0..<3 {
                data.appendLE(Float(matrix[column][row]))
            }
        }
    }

    private static func appendMatrix4x4RowMajor(_ matrix: simd_float4x4, to data: inout Data) {
        for row in 0..<4 {
            for column in 0..<4 {
                data.appendLE(Float(matrix[column][row]))
            }
        }
    }

    private static func depthToData(_ pb: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let height = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return Data() }
        return Data(bytes: base, count: bytesPerRow * height)
    }

    private static func confidenceToData(_ pb: CVPixelBuffer) -> Data? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let height = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        return Data(bytes: base, count: bytesPerRow * height)
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

    mutating func appendLE(_ value: Float) {
        var v = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Double) {
        var v = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
