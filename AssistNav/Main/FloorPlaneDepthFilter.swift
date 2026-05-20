import CoreVideo
import Foundation
import QuartzCore
import simd

final class FloorPlaneDepthFilter {
    struct Result {
        let depthMap: CVPixelBuffer
        let confidenceMap: CVPixelBuffer?
        let floorPlaneFound: Bool
        let stableFloorPlaneFound: Bool
        let removedPixelCount: Int
    }

    private struct Candidate {
        let anchor: ARLiDARFrameCapture.PlaneAnchorSnapshot
        let area: Float
        let worldY: Float
    }

    private struct StableFloorPlane {
        var anchor: ARLiDARFrameCapture.PlaneAnchorSnapshot
        var lastUpdatedAt: TimeInterval
        var seenFrames: Int
    }

    private let floorClutterBandAbovePlane: Float = 0.16
    private let floorBandBelowPlane: Float = 0.04
    private let planeExtentPadding: Float = 0.55
    private let minimumFloorBelowCamera: Float = 0.35
    private let replacementAreaMultiplier: Float = 1.35
    private let maxStablePlaneAge: TimeInterval = 2.0

    private var stablePlane: StableFloorPlane?

    func reset() {
        stablePlane = nil
    }

    func apply(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        intrinsics: simd_float3x3,
        referenceResolution: CGSize,
        cameraTransform: simd_float4x4,
        planeAnchors: [ARLiDARFrameCapture.PlaneAnchorSnapshot]
    ) -> Result {
        let candidatePlane = selectFloorPlane(from: planeAnchors, cameraTransform: cameraTransform)
        let floorPlane = updateStablePlane(with: candidatePlane, timestamp: CACurrentMediaTime())

        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              let floorPlane,
              let filteredDepth = makeDepthCopy(depthMap) else {
            return Result(
                depthMap: depthMap,
                confidenceMap: confidenceMap,
                floorPlaneFound: candidatePlane != nil,
                stableFloorPlaneFound: floorPlane != nil,
                removedPixelCount: 0
            )
        }

        let filteredConfidence = confidenceMap.flatMap(makeConfidenceCopy)
        let removed = removeFloorPixels(
            depthMap: filteredDepth,
            confidenceMap: filteredConfidence,
            intrinsics: intrinsics,
            referenceResolution: referenceResolution,
            cameraTransform: cameraTransform,
            floorPlane: floorPlane
        )

        return Result(
            depthMap: filteredDepth,
            confidenceMap: filteredConfidence ?? confidenceMap,
            floorPlaneFound: candidatePlane != nil,
            stableFloorPlaneFound: true,
            removedPixelCount: removed
        )
    }

    private func updateStablePlane(
        with candidate: ARLiDARFrameCapture.PlaneAnchorSnapshot?,
        timestamp: TimeInterval
    ) -> ARLiDARFrameCapture.PlaneAnchorSnapshot? {
        if let stablePlane, timestamp - stablePlane.lastUpdatedAt > maxStablePlaneAge {
            self.stablePlane = nil
        }

        guard let candidate else {
            return stablePlane?.anchor
        }

        guard var current = stablePlane else {
            stablePlane = StableFloorPlane(anchor: candidate, lastUpdatedAt: timestamp, seenFrames: 1)
            return candidate
        }

        let currentArea = planeArea(current.anchor)
        let candidateArea = planeArea(candidate)
        let sameAnchor = candidate.identifier == current.anchor.identifier
        let isClassifiedFloor = candidate.classification == "floor" && current.anchor.classification != "floor"
        let isMuchLarger = candidateArea > currentArea * replacementAreaMultiplier

        if sameAnchor || isClassifiedFloor || isMuchLarger {
            current.anchor = candidate
            current.lastUpdatedAt = timestamp
            current.seenFrames += 1
            stablePlane = current
        }

        return stablePlane?.anchor
    }

    private func selectFloorPlane(
        from anchors: [ARLiDARFrameCapture.PlaneAnchorSnapshot],
        cameraTransform: simd_float4x4
    ) -> ARLiDARFrameCapture.PlaneAnchorSnapshot? {
        let cameraY = cameraTransform.columns.3.y
        let candidates = anchors.compactMap { anchor -> Candidate? in
            guard anchor.alignment == "horizontal" else { return nil }
            let area = planeArea(anchor)
            guard area > 0.05 else { return nil }
            let centerWorld = anchor.transform * simd_float4(anchor.center.x, anchor.center.y, anchor.center.z, 1)
            return Candidate(anchor: anchor, area: area, worldY: centerWorld.y)
        }

        if let classifiedFloor = candidates
            .filter({ $0.anchor.classification == "floor" })
            .max(by: { $0.area < $1.area }) {
            return classifiedFloor.anchor
        }

        return candidates
            .filter { $0.worldY < cameraY - minimumFloorBelowCamera }
            .max(by: { $0.area < $1.area })?
            .anchor
    }

    private func planeArea(_ anchor: ARLiDARFrameCapture.PlaneAnchorSnapshot) -> Float {
        max(0, anchor.extent.x) * max(0, anchor.extent.z)
    }

    private func removeFloorPixels(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        intrinsics: simd_float3x3,
        referenceResolution: CGSize,
        cameraTransform: simd_float4x4,
        floorPlane: ARLiDARFrameCapture.PlaneAnchorSnapshot
    ) -> Int {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return 0 }

        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]
        guard fx != 0, fy != 0 else { return 0 }

        let refWidth = Float(referenceResolution.width)
        let refHeight = Float(referenceResolution.height)
        let scaleX = refWidth / Float(width)
        let scaleY = refHeight / Float(height)

        let inversePlane = floorPlane.transform.inverse
        let halfWidth = max(0, floorPlane.extent.x * 0.5) + planeExtentPadding
        let halfHeight = max(0, floorPlane.extent.z * 0.5) + planeExtentPadding
        let centerX = floorPlane.center.x
        let centerZ = floorPlane.center.z
        let rotation = -floorPlane.extentRotationOnYAxis
        let cosRotation = cos(rotation)
        let sinRotation = sin(rotation)

        CVPixelBufferLockBaseAddress(depthMap, [])
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, [])
        }
        defer {
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, [])
            }
            CVPixelBufferUnlockBaseAddress(depthMap, [])
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return 0 }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let depthPointer = depthBase.assumingMemoryBound(to: Float32.self)

        let confidencePointer: UnsafeMutablePointer<UInt8>? = {
            guard let confidenceMap,
                  CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8,
                  let base = CVPixelBufferGetBaseAddress(confidenceMap) else {
                return nil
            }
            return base.assumingMemoryBound(to: UInt8.self)
        }()
        let confidenceStride = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0

        var removed = 0
        for y in 0..<height {
            for x in 0..<width {
                let depthIndex = y * depthStride + x
                let depth = depthPointer[depthIndex]
                guard depth.isFinite, depth > 0 else { continue }

                let imageX = (Float(x) + 0.5) * scaleX
                let imageY = (Float(y) + 0.5) * scaleY
                let cameraPoint = simd_float4(
                    (imageX - cx) * depth / fx,
                    -(imageY - cy) * depth / fy,
                    -depth,
                    1
                )
                let worldPoint = cameraTransform * cameraPoint
                let planePoint = inversePlane * worldPoint
                guard planePoint.y >= -floorBandBelowPlane,
                      planePoint.y <= floorClutterBandAbovePlane else { continue }

                let dx = planePoint.x - centerX
                let dz = planePoint.z - centerZ
                let alignedX = dx * cosRotation - dz * sinRotation
                let alignedZ = dx * sinRotation + dz * cosRotation
                guard abs(alignedX) <= halfWidth, abs(alignedZ) <= halfHeight else { continue }

                depthPointer[depthIndex] = 0
                if let confidencePointer {
                    confidencePointer[y * confidenceStride + x] = 0
                }
                removed += 1
            }
        }

        return removed
    }

    private func makeDepthCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        makeCopy(source, pixelFormat: kCVPixelFormatType_DepthFloat32)
    }

    private func makeConfidenceCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_OneComponent8 else { return nil }
        return makeCopy(source, pixelFormat: kCVPixelFormatType_OneComponent8)
    }

    private func makeCopy(_ source: CVPixelBuffer, pixelFormat: OSType) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        var copy: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attrs, &copy) == kCVReturnSuccess,
              let copy else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let copyBase = CVPixelBufferGetBaseAddress(copy) else {
            return nil
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let copyBytesPerRow = CVPixelBufferGetBytesPerRow(copy)
        let bytesToCopy = min(sourceBytesPerRow, copyBytesPerRow)
        for row in 0..<height {
            memcpy(
                copyBase.advanced(by: row * copyBytesPerRow),
                sourceBase.advanced(by: row * sourceBytesPerRow),
                bytesToCopy
            )
        }

        return copy
    }
}
