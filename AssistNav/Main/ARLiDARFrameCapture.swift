import ARKit
import AVFoundation
import CoreVideo
import Foundation
import simd

final class ARLiDARFrameCapture: NSObject {
    struct PlaneAnchorSnapshot {
        let identifier: UUID
        let transform: simd_float4x4
        let alignment: String
        let classification: String
        let center: simd_float3
        let extent: simd_float3
        let extentRotationOnYAxis: Float
    }

    struct DepthFrame {
        let depthMap: CVPixelBuffer
        let confidenceMap: CVPixelBuffer?
        let intrinsics: simd_float3x3
        let referenceResolution: CGSize
        let cameraTransform: simd_float4x4
        let timestamp: TimeInterval
        let trackingState: String
        let planeAnchors: [PlaneAnchorSnapshot]
        let floorPlaneFound: Bool
        let floorRemovedPixelCount: Int
    }

    var onDepthFrame: ((DepthFrame) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private let session = ARSession()
    private let captureQueue = DispatchQueue(label: "assistnav.arkit.capture", qos: .userInitiated)
    private let floorFilter = FloorPlaneDepthFilter()

    private var running = false

    func start() {
        captureQueue.async {
            self.startLocked()
        }
    }

    func stop() {
        captureQueue.async {
            guard self.running else { return }
            self.running = false
            self.floorFilter.reset()
            self.session.pause()
        }
    }

    private func startLocked() {
        guard !running else { return }

        guard ARWorldTrackingConfiguration.isSupported else {
            onStatusChange?("arkit-world-tracking-unsupported")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            guard granted else {
                onStatusChange?("camera-denied")
                return
            }
        default:
            onStatusChange?("camera-denied")
            return
        }

        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            onStatusChange?("arkit-scene-depth-unsupported")
            return
        }

        running = true
        floorFilter.reset()
        session.delegate = self
        session.delegateQueue = captureQueue
        runConfiguration(resetTracking: true)
    }

    private func runConfiguration(resetTracking: Bool) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        configuration.planeDetection = [.horizontal]
        configuration.isLightEstimationEnabled = false
        configuration.videoFormat = fastestSupportedVideoFormat() ?? configuration.videoFormat

        let options: ARSession.RunOptions = resetTracking ? [.resetTracking, .removeExistingAnchors] : []
        session.run(configuration, options: options)

        onStatusChange?("arkit-running-lidar")
    }

    private func fastestSupportedVideoFormat() -> ARConfiguration.VideoFormat? {
        ARWorldTrackingConfiguration.supportedVideoFormats.max { lhs, rhs in
            if lhs.framesPerSecond == rhs.framesPerSecond {
                return lhs.imageResolution.width * lhs.imageResolution.height < rhs.imageResolution.width * rhs.imageResolution.height
            }
            return lhs.framesPerSecond < rhs.framesPerSecond
        }
    }

    private func trackingDescription(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "not-available"
        case .limited(let reason):
            return "limited-\(trackingReasonDescription(reason))"
        }
    }

    private func trackingReasonDescription(_ reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .initializing:
            return "initializing"
        case .excessiveMotion:
            return "excessive-motion"
        case .insufficientFeatures:
            return "insufficient-features"
        case .relocalizing:
            return "relocalizing"
        @unknown default:
            return "unknown"
        }
    }

    private func snapshot(for anchor: ARPlaneAnchor) -> PlaneAnchorSnapshot {
        let alignment: String
        switch anchor.alignment {
        case .horizontal:
            alignment = "horizontal"
        case .vertical:
            alignment = "vertical"
        @unknown default:
            alignment = "unknown"
        }

        return PlaneAnchorSnapshot(
            identifier: anchor.identifier,
            transform: anchor.transform,
            alignment: alignment,
            classification: classificationDescription(anchor.classification),
            center: anchor.center,
            extent: simd_float3(anchor.planeExtent.width, 0, anchor.planeExtent.height),
            extentRotationOnYAxis: anchor.planeExtent.rotationOnYAxis
        )
    }

    private func classificationDescription(_ classification: ARPlaneAnchor.Classification) -> String {
        switch classification {
        case .floor:
            return "floor"
        case .table:
            return "table"
        case .seat:
            return "seat"
        case .ceiling:
            return "ceiling"
        case .wall:
            return "wall"
        case .door:
            return "door"
        case .window:
            return "window"
        case .none:
            return "none"
        @unknown default:
            return "unknown"
        }
    }
}

extension ARLiDARFrameCapture: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running else { return }

        guard let sceneDepth = frame.sceneDepth else { return }

        let planeSnapshots = frame.anchors.compactMap { anchor in
            (anchor as? ARPlaneAnchor).map(snapshot(for:))
        }
        let floorRemoval = floorFilter.apply(
            depthMap: sceneDepth.depthMap,
            confidenceMap: sceneDepth.confidenceMap,
            intrinsics: frame.camera.intrinsics,
            referenceResolution: frame.camera.imageResolution,
            cameraTransform: frame.camera.transform,
            planeAnchors: planeSnapshots
        )

        onDepthFrame?(
            DepthFrame(
                depthMap: floorRemoval.depthMap,
                confidenceMap: floorRemoval.confidenceMap,
                intrinsics: frame.camera.intrinsics,
                referenceResolution: frame.camera.imageResolution,
                cameraTransform: frame.camera.transform,
                timestamp: frame.timestamp,
                trackingState: trackingDescription(frame.camera.trackingState),
                planeAnchors: planeSnapshots,
                floorPlaneFound: floorRemoval.stableFloorPlaneFound,
                floorRemovedPixelCount: floorRemoval.removedPixelCount
            )
        )
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        onStatusChange?("arkit-tracking-\(trackingDescription(camera.trackingState))")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onStatusChange?("arkit-interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard running else { return }
        onStatusChange?("arkit-interruption-ended")
        runConfiguration(resetTracking: true)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onStatusChange?("arkit-failed")
    }
}
