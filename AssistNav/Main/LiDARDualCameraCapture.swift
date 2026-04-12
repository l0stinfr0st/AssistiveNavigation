import AVFoundation
import CoreVideo
import Foundation
import simd

final class LiDARDualCameraCapture: NSObject {
    struct DepthFrame {
        let depthMap: CVPixelBuffer
        let lidarVideo: CVPixelBuffer?
        let intrinsics: simd_float3x3?
        let referenceResolution: CGSize?
        let timestamp: TimeInterval
    }

    var onDepthFrame: ((DepthFrame) -> Void)?
    var onUltraWideFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "assistnav.multicam.session", qos: .userInitiated)
    private let lidarSyncQueue = DispatchQueue(label: "assistnav.multicam.lidar-sync", qos: .userInitiated)
    private let ultraWideQueue = DispatchQueue(label: "assistnav.multicam.ultrawide", qos: .userInitiated)

    private let lidarVideoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let ultraWideOutput = AVCaptureVideoDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var configured = false

    func start() {
        sessionQueue.async {
            self.startLocked()
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func startLocked() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            onStatusChange?("multicam-unsupported")
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

        if !configured {
            configured = configureSession()
        }

        guard configured else { return }
        guard !session.isRunning else { return }

        session.startRunning()
        onStatusChange?("multicam-running")
    }

    private func configureSession() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let lidarDevice = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            onStatusChange?("no-lidar-camera")
            return false
        }
        guard let ultraWideDevice = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
            onStatusChange?("no-0.5x-camera")
            return false
        }

        do {
            let lidarInput = try AVCaptureDeviceInput(device: lidarDevice)
            let ultraWideInput = try AVCaptureDeviceInput(device: ultraWideDevice)

            guard session.canAddInput(lidarInput), session.canAddInput(ultraWideInput) else {
                onStatusChange?("multicam-input-failed")
                return false
            }
            session.addInputWithNoConnections(lidarInput)
            session.addInputWithNoConnections(ultraWideInput)

            lidarVideoOutput.alwaysDiscardsLateVideoFrames = true
            lidarVideoOutput.setSampleBufferDelegate(nil, queue: nil)
            lidarVideoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]

            depthOutput.isFilteringEnabled = true
            depthOutput.alwaysDiscardsLateDepthData = true

            ultraWideOutput.alwaysDiscardsLateVideoFrames = true
            ultraWideOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            ultraWideOutput.setSampleBufferDelegate(self, queue: ultraWideQueue)

            guard session.canAddOutput(lidarVideoOutput),
                  session.canAddOutput(depthOutput),
                  session.canAddOutput(ultraWideOutput) else {
                onStatusChange?("multicam-output-failed")
                return false
            }

            session.addOutputWithNoConnections(lidarVideoOutput)
            session.addOutputWithNoConnections(depthOutput)
            session.addOutputWithNoConnections(ultraWideOutput)

            guard let lidarVideoPort = lidarInput.ports.first(where: { $0.mediaType == .video }),
                  let lidarDepthPort = lidarInput.ports.first(where: { $0.mediaType == .depthData }),
                  let ultraWideVideoPort = ultraWideInput.ports.first(where: { $0.mediaType == .video }) else {
                onStatusChange?("multicam-ports-failed")
                return false
            }

            let lidarVideoConnection = AVCaptureConnection(inputPorts: [lidarVideoPort], output: lidarVideoOutput)
            let lidarDepthConnection = AVCaptureConnection(inputPorts: [lidarDepthPort], output: depthOutput)
            let ultraWideConnection = AVCaptureConnection(inputPorts: [ultraWideVideoPort], output: ultraWideOutput)

            guard session.canAddConnection(lidarVideoConnection),
                  session.canAddConnection(lidarDepthConnection),
                  session.canAddConnection(ultraWideConnection) else {
                onStatusChange?("multicam-connection-failed")
                return false
            }

            session.addConnection(lidarVideoConnection)
            session.addConnection(lidarDepthConnection)
            session.addConnection(ultraWideConnection)

            synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [lidarVideoOutput, depthOutput])
            synchronizer?.setDelegate(self, queue: lidarSyncQueue)
            return true
        } catch {
            onStatusChange?("multicam-config-error")
            return false
        }
    }
}

extension LiDARDualCameraCapture: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        guard let syncedDepth = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !syncedDepth.depthDataWasDropped else {
            return
        }

        let converted = syncedDepth.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = converted.depthDataMap
        let calibration = converted.cameraCalibrationData
        let intrinsics = calibration?.intrinsicMatrix
        let referenceResolution = calibration.map {
            CGSize(width: CGFloat($0.intrinsicMatrixReferenceDimensions.width),
                   height: CGFloat($0.intrinsicMatrixReferenceDimensions.height))
        }

        var lidarVideoPixelBuffer: CVPixelBuffer?
        if let syncedVideo = synchronizedDataCollection.synchronizedData(for: lidarVideoOutput) as? AVCaptureSynchronizedSampleBufferData,
           !syncedVideo.sampleBufferWasDropped,
           let imageBuffer = CMSampleBufferGetImageBuffer(syncedVideo.sampleBuffer) {
            lidarVideoPixelBuffer = imageBuffer
        }

        let timestamp = CMTimeGetSeconds(syncedDepth.timestamp)
        onDepthFrame?(
            DepthFrame(
                depthMap: depthMap,
                lidarVideo: lidarVideoPixelBuffer,
                intrinsics: intrinsics,
                referenceResolution: referenceResolution,
                timestamp: timestamp
            )
        )
    }
}

extension LiDARDualCameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === ultraWideOutput,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        onUltraWideFrame?(pixelBuffer, timestamp)
    }
}
