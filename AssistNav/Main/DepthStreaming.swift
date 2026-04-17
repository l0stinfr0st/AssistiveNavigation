import Foundation
import Network
import CoreVideo
import CoreImage
import simd
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class DepthStreamingSettings: ObservableObject {
    static let shared = DepthStreamingSettings()

    @Published var enabled: Bool { didSet { save() } }
    @Published var host: String { didSet { save() } }
    @Published var port: Int { didSet { save() } }
    @Published var rgbPort: Int { didSet { save() } }
    @Published var maxFPS: Double { didSet { save() } }
    @Published var includeRGB: Bool { didSet { save() } }
    @Published var jpegQuality: Double { didSet { save() } }

    private init() {
        let d = UserDefaults.standard
        let storedPort = d.integer(forKey: Keys.port)
        let storedMaxFPS = d.double(forKey: Keys.maxFPS)
        let storedJPEGQuality = d.double(forKey: Keys.jpegQuality)

        enabled = d.bool(forKey: Keys.enabled)
        host = d.string(forKey: Keys.host) ?? "192.168.1.2"
        port = storedPort == 0 ? 5050 : storedPort
        let storedRGBPort = d.integer(forKey: Keys.rgbPort)
        rgbPort = storedRGBPort == 0 ? 5051 : storedRGBPort
        maxFPS = storedMaxFPS == 0 ? 30 : storedMaxFPS
        includeRGB = d.bool(forKey: Keys.includeRGB)
        jpegQuality = storedJPEGQuality == 0 ? 0.55 : storedJPEGQuality
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: Keys.enabled)
        d.set(host, forKey: Keys.host)
        d.set(port, forKey: Keys.port)
        d.set(rgbPort, forKey: Keys.rgbPort)
        d.set(maxFPS, forKey: Keys.maxFPS)
        d.set(includeRGB, forKey: Keys.includeRGB)
        d.set(jpegQuality, forKey: Keys.jpegQuality)
    }

    private enum Keys {
        static let enabled = "depth_streaming.enabled"
        static let host = "depth_streaming.host"
        static let port = "depth_streaming.port"
        static let rgbPort = "depth_streaming.rgb_port"
        static let maxFPS = "depth_streaming.max_fps"
        static let includeRGB = "depth_streaming.include_rgb"
        static let jpegQuality = "depth_streaming.jpeg_quality"
    }
}

/// Streams frames over UDP to a laptop receiver.
///
/// Packet format (little-endian):
/// - magic: 4 bytes "ANDF"
/// - version: UInt16 (1)
/// - flags: UInt16 (bit0: hasConfidence, bit1: hasRGB)
/// - depthWidth: UInt16
/// - depthHeight: UInt16
/// - rgbWidth: UInt16
/// - rgbHeight: UInt16
/// - calibrationWidth: UInt16
/// - calibrationHeight: UInt16
/// - timestamp: Float64 (seconds)
/// - intrinsics: 9 Float32 (row-major)
/// - depthBytes: UInt32
/// - confBytes: UInt32
/// - rgbJpegBytes: UInt32
/// - payload: depth(Float32 meters) + confidence(UInt8) + jpeg bytes
///
/// Note: UDP has MTU limits; we chunk packets into datagrams with a small chunk header.
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
        rgb: CVPixelBuffer?,
        intrinsics: simd_float3x3?,
        referenceResolution: CGSize?,
        timestamp: TimeInterval,
        maxFPS: Double,
        includeRGB: Bool,
        jpegQuality: Double
    ) {
        guard let conn else { return }
        let minInterval = 1.0 / max(1.0, maxFPS)
        if timestamp - lastSentAt < minInterval { return }
        lastSentAt = timestamp

        let packet = DepthPacketBuilder.build(
            depth: depth,
            confidence: confidence,
            rgb: nil,
            intrinsics: intrinsics,
            referenceResolution: referenceResolution,
            timestamp: timestamp,
            jpegQuality: jpegQuality
        )
        guard !packet.isEmpty else { return }

        // Chunk to avoid MTU issues.
        let chunkSize = 1200 // safe-ish UDP payload
        let totalChunks = Int(ceil(Double(packet.count) / Double(chunkSize)))
        let frameId = UInt32.random(in: 1...UInt32.max)

        for idx in 0..<totalChunks {
            let start = idx * chunkSize
            let end = min(packet.count, start + chunkSize)
            let slice = packet.subdata(in: start..<end)
            var datagram = Data()
            datagram.append(contentsOf: "CHNK".utf8)              // 4
            datagram.appendLE(frameId)                             // 4
            datagram.appendLE(UInt16(totalChunks))                 // 2
            datagram.appendLE(UInt16(idx))                         // 2
            datagram.append(slice)
            conn.send(content: datagram, completion: .contentProcessed { _ in })
        }
    }
}

enum DepthPacketBuilder {
    static func build(
        depth: CVPixelBuffer,
        confidence: CVPixelBuffer?,
        rgb: CVPixelBuffer?,
        intrinsics: simd_float3x3?,
        referenceResolution: CGSize?,
        timestamp: TimeInterval,
        jpegQuality: Double
    ) -> Data {
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 else { return Data() }

        let dw = CVPixelBufferGetWidth(depth)
        let dh = CVPixelBufferGetHeight(depth)

        let hasConf = (confidence != nil)
        let hasRGB = (rgb != nil)
        var flags: UInt16 = 0
        if hasConf { flags |= 1 << 0 }
        if hasRGB { flags |= 1 << 1 }

        let rgbW = rgb.map(CVPixelBufferGetWidth) ?? 0
        let rgbH = rgb.map(CVPixelBufferGetHeight) ?? 0
        let calibrationW = UInt16(max(0, min(65535, Int(referenceResolution?.width ?? CGFloat(dw)))))
        let calibrationH = UInt16(max(0, min(65535, Int(referenceResolution?.height ?? CGFloat(dh)))))

        let depthBytes = depthToData(depth)
        let confBytes = confidence.flatMap(confidenceToData) ?? Data()
        let jpeg = rgb.flatMap { rgbToJPEG($0, quality: jpegQuality) } ?? Data()

        var out = Data()
        out.append(contentsOf: "ANDF".utf8)
        out.appendLE(UInt16(2)) // version
        out.appendLE(flags)
        out.appendLE(UInt16(dw))
        out.appendLE(UInt16(dh))
        out.appendLE(UInt16(rgbW))
        out.appendLE(UInt16(rgbH))
        out.appendLE(calibrationW)
        out.appendLE(calibrationH)
        out.appendLE(timestamp)

        let K = intrinsics ?? matrix_identity_float3x3
        for r in 0..<3 {
            for c in 0..<3 {
                out.appendLE(Float(K[r][c]))
            }
        }

        out.appendLE(UInt32(depthBytes.count))
        out.appendLE(UInt32(confBytes.count))
        out.appendLE(UInt32(jpeg.count))
        out.append(depthBytes)
        out.append(confBytes)
        out.append(jpeg)
        return out
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

    static func rgbToJPEG(_ pb: CVPixelBuffer, quality: Double) -> Data? {
        // capturedImage is typically kCVPixelFormatType_420YpCbCr8BiPlanarFullRange.
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: [.cacheIntermediates: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality as String: max(0.1, min(0.95, quality))] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

final class RGBFrameStreamer {
    private var conn: NWConnection?
    private var lastSentAt: TimeInterval = 0

    func setEnabled(_ enabled: Bool, host: String, port: Int) {
        if enabled {
            start(host: host, port: port)
        } else {
            stop()
        }
    }

    func maybeSend(
        rgb: CVPixelBuffer,
        timestamp: TimeInterval,
        maxFPS: Double,
        jpegQuality: Double
    ) {
        guard let conn else { return }
        let minInterval = 1.0 / max(1.0, maxFPS)
        if timestamp - lastSentAt < minInterval { return }
        lastSentAt = timestamp

        guard let jpeg = DepthPacketBuilder.rgbToJPEG(rgb, quality: jpegQuality) else { return }

        var packet = Data()
        packet.append(contentsOf: "ANRG".utf8)
        packet.appendLE(UInt16(1))
        packet.appendLE(UInt16(0))
        packet.appendLE(UInt16(CVPixelBufferGetWidth(rgb)))
        packet.appendLE(UInt16(CVPixelBufferGetHeight(rgb)))
        packet.appendLE(timestamp)
        packet.appendLE(UInt32(jpeg.count))
        packet.append(jpeg)

        let chunkSize = 1200
        let totalChunks = Int(ceil(Double(packet.count) / Double(chunkSize)))
        let frameId = UInt32.random(in: 1...UInt32.max)

        for idx in 0..<totalChunks {
            let start = idx * chunkSize
            let end = min(packet.count, start + chunkSize)
            let slice = packet.subdata(in: start..<end)
            var datagram = Data()
            datagram.append(contentsOf: "RCHK".utf8)
            datagram.appendLE(frameId)
            datagram.appendLE(UInt16(totalChunks))
            datagram.appendLE(UInt16(idx))
            datagram.append(slice)
            conn.send(content: datagram, completion: .contentProcessed { _ in })
        }
    }

    private func start(host: String, port: Int) {
        stop()
        guard let p = NWEndpoint.Port(rawValue: UInt16(max(1, min(65535, port)))) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
        c.stateUpdateHandler = { _ in }
        c.start(queue: .global(qos: .userInitiated))
        conn = c
    }

    private func stop() {
        conn?.cancel()
        conn = nil
        lastSentAt = 0
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
