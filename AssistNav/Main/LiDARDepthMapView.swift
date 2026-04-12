import SwiftUI
import CoreImage
import QuartzCore
import UIKit
import simd

struct LiDARDepthMapView: View {
    @StateObject private var model = LiDARDepthModel()
    let fillScreen: Bool
    @EnvironmentObject private var streaming: DepthStreamingSettings

    init(fillScreen: Bool = true) {
        self.fillScreen = fillScreen
    }

    var body: some View {
        ZStack {
            if let cg = model.depthCGImage {
                Image(decorative: cg, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
                    .modifier(IgnoresSafeAreaIfNeeded(enabled: fillScreen))
            } else {
                Color.black
                    .modifier(IgnoresSafeAreaIfNeeded(enabled: fillScreen))

                VStack(spacing: 10) {
                    Text("Waiting For LiDAR Depth")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text(model.statusLine)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))

                    Text(model.debugLine)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(16)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text(model.debugLine)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 6)
        }
        .safeAreaInset(edge: .bottom) {
            DepthRangeControls(
                maxDepth: $model.maxDepthMeters,
                isExporting: model.isExporting,
                exportStatusLine: model.exportStatusLine,
                onStartExport: { model.startExport() },
                onStopExport: { model.stopExport() }
            )
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, fillScreen ? 8 : 0)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .accessibilityHidden(true)
        .task {
            model.updateStreaming(settings: streaming, force: true)
        }
        .onChange(of: streaming.enabled) { _, _ in
            model.updateStreaming(settings: streaming, force: true)
        }
        .onChange(of: streaming.host) { _, _ in
            model.updateStreaming(settings: streaming, force: true)
        }
        .onChange(of: streaming.port) { _, _ in
            model.updateStreaming(settings: streaming, force: true)
        }
        .onChange(of: streaming.maxFPS) { _, _ in
            model.updateStreaming(settings: streaming, force: false)
        }
        .onChange(of: streaming.includeRGB) { _, _ in
            model.updateStreaming(settings: streaming, force: false)
        }
        .onChange(of: streaming.jpegQuality) { _, _ in
            model.updateStreaming(settings: streaming, force: false)
        }
        .sheet(item: $model.exportedFile) { exported in
            ShareSheet(activityItems: [exported.url])
        }
    }
}

private struct IgnoresSafeAreaIfNeeded: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}

private struct DepthRangeControls: View {
    @Binding var maxDepth: Double
    let isExporting: Bool
    let exportStatusLine: String
    let onStartExport: () -> Void
    let onStopExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Depth range")
                    .font(.headline)

                Spacer()

                Text("0.20–\(maxDepth, format: .number.precision(.fractionLength(1))) m")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Max distance")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Slider(value: $maxDepth, in: 0.5...8.0, step: 0.1)
                Text("\(maxDepth, format: .number.precision(.fractionLength(1))) m")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(isExporting ? "Stop Export" : "Start Export") {
                    if isExporting {
                        onStopExport()
                    } else {
                        onStartExport()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isExporting ? .red : .white)

                Text(exportStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
final class LiDARDepthModel: NSObject, ObservableObject {
    @Published var depthCGImage: CGImage?
    @Published var statusLine = "Starting LiDAR depth..."
    @Published var maxDepthMeters: Double = 6.0
    @Published var debugLine = "depth: -"
    @Published var isExporting = false
    @Published var exportStatusLine = "Export idle"
    @Published var exportedFile: DepthExportedFile?

    private let capture = LiDARDualCameraCapture()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let targetDisplaySize = CGSize(width: 720, height: 960)
    private let streamer = DepthFrameStreamer()
    private let rgbStreamer = RGBFrameStreamer()
    private let recorder = DepthFileRecorder()
    private let fixedMinDepthMeters: Float = 0.20

    private var running = false
    private var displayLink: CADisplayLink?

    private var latestDepth: CVPixelBuffer?
    private var latestConfidence: CVPixelBuffer?
    private var latestRGB: CVPixelBuffer?
    private var latestRGBTimestamp: TimeInterval?
    private var latestIntrinsics: simd_float3x3?
    private var latestImageResolution: CGSize?
    private var latestTimestamp: TimeInterval?
    private var rgbSourceLabel = "0.5x"

    private var streamingEnabled = false
    private var streamHost = ""
    private var streamPort = 0
    private var streamRGBPort = 0
    private var streamMaxFPS: Double = 30
    private var streamIncludeRGB = false
    private var streamJpegQuality: Double = 0.55

    func start() {
        guard !running else { return }
        running = true
        rgbSourceLabel = "0.5x"
        statusLine = "Starting LiDAR + ultra-wide capture..."

        capture.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self, self.running else { return }
                switch status {
                case "multicam-running":
                    self.statusLine = "LiDAR depth + ultra-wide RGB are running"
                case "camera-denied":
                    self.statusLine = "Camera access is required for LiDAR and RGB capture."
                case "multicam-unsupported":
                    self.statusLine = "This device does not support simultaneous LiDAR and ultra-wide capture."
                default:
                    self.statusLine = "Capture setup issue: \(status)"
                }
            }
        }

        capture.onDepthFrame = { [weak self] frame in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.latestDepth = frame.depthMap
                self.latestIntrinsics = frame.intrinsics
                self.latestImageResolution = frame.referenceResolution
                self.latestTimestamp = frame.timestamp
                if self.isExporting {
                    let exportRGB: CVPixelBuffer?
                    if let latestRGB = self.latestRGB,
                       let latestRGBTimestamp = self.latestRGBTimestamp,
                       abs(latestRGBTimestamp - frame.timestamp) <= 0.05 {
                        exportRGB = latestRGB
                    } else {
                        exportRGB = nil
                    }
                    self.recorder.appendFrame(
                        depth: frame.depthMap,
                        confidence: nil,
                        rgb: exportRGB,
                        intrinsics: frame.intrinsics,
                        referenceResolution: frame.referenceResolution,
                        timestamp: frame.timestamp
                    )
                }
            }
        }

        capture.onUltraWideFrame = { [weak self] pixelBuffer, timestamp in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.latestRGB = pixelBuffer
                self.latestRGBTimestamp = timestamp
            }
        }

        capture.start()

        let link = CADisplayLink(target: self, selector: #selector(renderTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        running = false
        displayLink?.invalidate()
        displayLink = nil

        latestDepth = nil
        latestConfidence = nil
        latestRGB = nil
        latestRGBTimestamp = nil
        latestIntrinsics = nil
        latestImageResolution = nil
        latestTimestamp = nil
        rgbSourceLabel = "0.5x"

        capture.stop()
        streamer.setEnabled(false, host: streamHost, port: streamPort)
        rgbStreamer.setEnabled(false, host: streamHost, port: streamRGBPort)
    }

    func updateStreaming(settings: DepthStreamingSettings, force: Bool) {
        let enabled = settings.enabled
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = settings.port
        let rgbPort = settings.rgbPort

        streamingEnabled = enabled
        streamHost = host
        streamPort = port
        streamRGBPort = rgbPort
        streamMaxFPS = settings.maxFPS
        streamIncludeRGB = settings.includeRGB
        streamJpegQuality = settings.jpegQuality

        streamer.setEnabled(enabled, host: host, port: port)
        rgbStreamer.setEnabled(enabled && streamIncludeRGB, host: host, port: rgbPort)
    }

    func latestFrameForStreaming() -> (
        depth: CVPixelBuffer,
        confidence: CVPixelBuffer?,
        rgb: CVPixelBuffer?,
        intrinsics: simd_float3x3?,
        resolution: CGSize?,
        timestamp: TimeInterval?
    )? {
        guard let latestDepth else { return nil }

        return (
            depth: latestDepth,
            confidence: latestConfidence,
            rgb: latestRGB,
            intrinsics: latestIntrinsics,
            resolution: latestImageResolution,
            timestamp: latestTimestamp
        )
    }

    @objc private func renderTick() {
        guard running, let latestDepth else { return }

        if let renderedImage = DepthMapRenderer.render(
            pixelBuffer: latestDepth,
            confidencePixelBuffer: latestConfidence,
            rgbPixelBuffer: latestRGB,
            targetSize: targetDisplaySize,
            minMeters: fixedMinDepthMeters,
            maxMeters: Float(maxDepthMeters),
            ciContext: ciContext
        ) {
            depthCGImage = renderedImage
        }

        let depthWidth = CVPixelBufferGetWidth(latestDepth)
        let depthHeight = CVPixelBufferGetHeight(latestDepth)
        let confidenceDescription = latestConfidence.map {
            "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))"
        } ?? "-"
        let rgbDescription = latestRGB.map {
            "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))"
        } ?? "-"

        debugLine = "depth: \(depthWidth)x\(depthHeight) | rgb: \(rgbDescription) \(rgbSourceLabel) | conf: \(confidenceDescription) | stream: \(streamingEnabled ? "on" : "off")"

        if streamingEnabled {
            streamer.maybeSend(
                depth: latestDepth,
                confidence: nil,
                rgb: nil,
                intrinsics: latestIntrinsics,
                referenceResolution: latestImageResolution,
                timestamp: latestTimestamp ?? CACurrentMediaTime(),
                maxFPS: streamMaxFPS,
                includeRGB: streamIncludeRGB,
                jpegQuality: streamJpegQuality
            )
            if streamIncludeRGB, let latestRGB {
                rgbStreamer.maybeSend(
                    rgb: latestRGB,
                    timestamp: latestTimestamp ?? CACurrentMediaTime(),
                    maxFPS: streamMaxFPS,
                    jpegQuality: streamJpegQuality
                )
            }
        }
    }

    func startExport() {
        guard !isExporting else { return }

        do {
            try recorder.start(maxFPS: 15, includeRGB: true, jpegQuality: 0.55)
            exportedFile = nil
            isExporting = true
            exportStatusLine = "Recording depth + RGB frames..."
        } catch {
            exportStatusLine = "Could not start export"
        }
    }

    func stopExport() {
        guard isExporting else { return }
        isExporting = false
        exportStatusLine = "Finalizing export..."

        recorder.stop { [weak self] exported in
            guard let self else { return }
            if let exported {
                self.exportedFile = exported
                self.exportStatusLine = "Saved \(exported.frameCount) frames"
            } else {
                self.exportStatusLine = "Export canceled"
            }
        }
    }
}

private enum DepthMapRenderer {
    static func render(
        pixelBuffer: CVPixelBuffer,
        confidencePixelBuffer: CVPixelBuffer?,
        rgbPixelBuffer: CVPixelBuffer?,
        targetSize: CGSize,
        minMeters: Float,
        maxMeters: Float,
        ciContext: CIContext
    ) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }
        guard let cgImage = makeDepthPreviewImage(
            pixelBuffer: pixelBuffer,
            confidencePixelBuffer: confidencePixelBuffer,
            minMeters: minMeters,
            maxMeters: maxMeters
        ) else {
            return nil
        }

        let scaled = scaleCoverAndCrop(CIImage(cgImage: cgImage).oriented(.right), to: targetSize)
            .applyingFilter(
                "CISharpenLuminance",
                parameters: [
                    kCIInputSharpnessKey: 0.22,
                ]
            )

        let translated = scaled.transformed(
            by: CGAffineTransform(
                translationX: -scaled.extent.origin.x,
                y: -scaled.extent.origin.y
            )
        )

        return ciContext.createCGImage(translated, from: CGRect(origin: .zero, size: targetSize))
    }

    private static func makeDepthPreviewImage(
        pixelBuffer: CVPixelBuffer,
        confidencePixelBuffer: CVPixelBuffer?,
        minMeters: Float,
        maxMeters: Float
    ) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if let confidencePixelBuffer {
            CVPixelBufferLockBaseAddress(confidencePixelBuffer, .readOnly)
        }
        defer {
            if let confidencePixelBuffer {
                CVPixelBufferUnlockBaseAddress(confidencePixelBuffer, .readOnly)
            }
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let depthStride = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<Float32>.stride

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let depthPointer = depthBaseAddress.assumingMemoryBound(to: Float32.self)

        let confidencePointer: UnsafePointer<UInt8>? = {
            guard let confidencePixelBuffer,
                  CVPixelBufferGetPixelFormatType(confidencePixelBuffer) == kCVPixelFormatType_OneComponent8,
                  let base = CVPixelBufferGetBaseAddress(confidencePixelBuffer) else {
                return Optional<UnsafePointer<UInt8>>.none
            }
            return UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
        }()
        let confidenceStride: Int = {
            guard let confidencePixelBuffer else { return 0 }
            return CVPixelBufferGetBytesPerRow(confidencePixelBuffer)
        }()

        let clampedMax = max(maxMeters, minMeters + 0.05)
        let clampedMin = min(minMeters, clampedMax - 0.05)
        let range = clampedMax - clampedMin

        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let outputIndex = (y * width + x) * 4
                let depthValue = depthPointer[y * depthStride + x]

                guard depthValue.isFinite, depthValue > 0 else {
                    rgba[outputIndex + 0] = 18
                    rgba[outputIndex + 1] = 18
                    rgba[outputIndex + 2] = 18
                    rgba[outputIndex + 3] = 255
                    continue
                }

                if let confidencePointer {
                    let confidence = confidencePointer[y * confidenceStride + x]
                    guard confidence > 0 else {
                        rgba[outputIndex + 0] = 18
                        rgba[outputIndex + 1] = 18
                        rgba[outputIndex + 2] = 18
                        rgba[outputIndex + 3] = 255
                        continue
                    }
                }

                let normalized = max(0, min(1, (clampedMax - depthValue) / range))
                let gray = UInt8(max(0, min(255, Int(pow(normalized, 0.9) * 255))))
                rgba[outputIndex + 0] = gray
                rgba[outputIndex + 1] = gray
                rgba[outputIndex + 2] = gray
                rgba[outputIndex + 3] = 255
            }
        }

        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func scaleCoverAndCrop(_ image: CIImage, to targetSize: CGSize) -> CIImage {
        let scaleX = targetSize.width / image.extent.width
        let scaleY = targetSize.height / image.extent.height
        let coverScale = max(scaleX, scaleY)

        let scaled = image.applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                "inputScale": coverScale,
                "inputAspectRatio": 1.0,
            ]
        )

        let cropRect = CGRect(
            x: scaled.extent.midX - targetSize.width / 2,
            y: scaled.extent.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )

        return scaled.cropped(to: cropRect)
    }

}
