import AppKit
import Vision

final class ScrollCapturer {
    private struct ImageFormat {
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let bitmapInfo: CGBitmapInfo
        let colorSpace: CGColorSpace
    }

    private struct CapturedFrame {
        let image: NSImage
        let bitmap: BitmapData
    }

    /// Result of a single capture attempt, used by auto-scroll to decide
    /// whether the page kept producing fresh content or has bottomed out.
    enum FrameOutcome {
        /// A new frame with fresh content was stitched in.
        case appended
        /// The frame was a duplicate, too similar, or failed — no progress.
        case noNewContent
        /// The frame budget is exhausted; capturing should stop.
        case atFrameLimit
    }

    var onPreviewUpdated: ((NSImage) -> Void)?

    private let captureRect: CGRect
    private let screen: NSScreen
    /// capcap's own scroll-capture chrome (e.g. the hint toast) — excluded
    /// from every captured frame so it never appears in the stitched image.
    private let excludedWindowNumbers: [CGWindowID]
    private let captureQueue = DispatchQueue(label: "capcap.scroll-capture", qos: .userInitiated)
    private let maxFrames = 100

    private var frames: [CapturedFrame] = []
    private var overlaps: [Int] = []

    // Incremental preview state
    private var previewBitmap: BitmapData?
    private var previewHeightPixels: Int = 0
    private var previewScale: CGFloat = 1
    private var previewPointWidth: CGFloat = 0

    init(rect: CGRect, screen: NSScreen, excludingWindowNumbers: [CGWindowID] = []) {
        self.captureRect = rect
        self.screen = screen
        self.excludedWindowNumbers = excludingWindowNumbers

        if
            let image = ScreenCapturer.capture(rect: rect, screen: screen, excludingWindowNumbers: excludingWindowNumbers),
            let bitmap = bitmapData(from: image)
        {
            let firstFrame = CapturedFrame(image: image, bitmap: bitmap)
            frames.append(firstFrame)
            initPreview(from: firstFrame)
        }
    }

    func stopAndStitch() -> NSImage? {
        var result: NSImage?

        captureQueue.sync {
            // One last frame so the final scrolled state is never missed.
            captureFrame(expectedShiftPoints: 0)

            guard !frames.isEmpty else {
                result = nil
                return
            }

            if frames.count == 1 {
                result = frames[0].image
                return
            }

            result = stitchAcceptedFrames()
        }

        return result
    }

    /// Captures a frame synchronously and reports the outcome. Used by the
    /// auto-scroll loop: it scrolls a fixed step, then calls this to learn
    /// whether the step revealed new content (keep going) or not (page end).
    func captureSynchronously(expectedShiftPoints: CGFloat) -> FrameOutcome {
        var outcome: FrameOutcome = .noNewContent
        captureQueue.sync {
            outcome = captureFrame(expectedShiftPoints: expectedShiftPoints)
        }
        return outcome
    }

    /// Captures a frame, polling until two consecutive captures produce
    /// byte-identical TIFF data (the page has stopped re-rendering) or a
    /// timeout elapses. This guards the Vision-based overlap detector
    /// against measuring an in-progress smooth-scroll animation — without
    /// it, fast synthetic scrolls catch the page mid-render and Vision
    /// reports partial offsets that defeat the stitching loop.
    ///
    /// Returns the settled image, or the most-recent capture if settlement
    /// times out (so the loop still progresses rather than failing hard).
    private func captureSettledFrame() -> NSImage? {
        var previousData: Data? = nil
        var lastImage: NSImage? = nil
        var waitNs: UInt64 = 12_000_000   // start polling at 12ms

        // ~20 iterations × 12–80ms backoff ≈ up to ~1s total wait, which is
        // more than enough for typical smooth-scroll animations (150–300ms).
        for _ in 0..<20 {
            guard let image = ScreenCapturer.capture(
                rect: captureRect,
                screen: screen,
                excludingWindowNumbers: excludedWindowNumbers
            ) else {
                Thread.sleep(forTimeInterval: 0.03)
                continue
            }

            // TIFF byte representation: a deterministic per-pixel signature.
            // Two consecutive identical TIFFs = the compositor isn't drawing
            // anything new, so the page is settled.
            guard let signature = image.tiffRepresentation else {
                Thread.sleep(forTimeInterval: Double(waitNs) / 1_000_000_000)
                continue
            }

            if let prev = previousData, prev == signature {
                return image
            }

            previousData = signature
            lastImage = image
            Thread.sleep(forTimeInterval: Double(waitNs) / 1_000_000_000)
            // Geometric backoff so we don't busy-poll for long animations.
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        // Timeout — return whatever we have. The caller's dedup check
        // (imagesAreNearlyIdentical) will still catch the no-progress case
        // and report .noNewContent appropriately.
        return lastImage
    }

    @discardableResult
    private func captureFrame(expectedShiftPoints: CGFloat) -> FrameOutcome {
        guard frames.count < maxFrames else { return .atFrameLimit }
        guard
            let image = captureSettledFrame(),
            let bitmap = bitmapData(from: image)
        else {
            return .noNewContent
        }

        let candidateFrame = CapturedFrame(image: image, bitmap: bitmap)

        if let previousFrame = frames.last,
           imagesAreNearlyIdentical(previousFrame.bitmap, candidateFrame.bitmap) {
            return .noNewContent
        }

        guard let previousFrame = frames.last else {
            frames.append(candidateFrame)
            initPreview(from: candidateFrame)
            return .appended
        }

        let scale = CGFloat(candidateFrame.bitmap.height) / max(candidateFrame.image.size.height, 1)
        let expectedShiftPixels: Int?
        if expectedShiftPoints > 0 {
            expectedShiftPixels = Int((expectedShiftPoints * scale).rounded())
        } else {
            expectedShiftPixels = nil
        }

        let overlap = findOverlap(
            previous: previousFrame.bitmap,
            current: candidateFrame.bitmap,
            expectedNewContentPixels: expectedShiftPixels
        )

        let minimumNewRows = max(8, candidateFrame.bitmap.height / 200)
        let newRows = candidateFrame.bitmap.height - overlap
        guard newRows >= minimumNewRows else { return .noNewContent }

        frames.append(candidateFrame)
        overlaps.append(overlap)
        appendToPreview(candidateFrame.bitmap, overlapPixels: overlap)
        return .appended
    }

    // MARK: - Incremental Preview

    private func initPreview(from frame: CapturedFrame) {
        previewScale = CGFloat(frame.bitmap.height) / max(frame.image.size.height, 1)
        previewPointWidth = frame.image.size.width

        let initialCapacity = frame.bitmap.height * 10
        guard let output = makeOutputBitmap(from: frame.bitmap, totalHeightPixels: initialCapacity) else { return }

        copyRows(
            from: frame.bitmap,
            sourceStartRow: 0,
            rowCount: frame.bitmap.height,
            to: output,
            destinationStartRow: 0
        )

        previewBitmap = output
        previewHeightPixels = frame.bitmap.height
        emitPreviewImage()
    }

    private func appendToPreview(_ bitmap: BitmapData, overlapPixels: Int) {
        guard var previewBitmap else { return }

        let newRows = bitmap.height - overlapPixels
        guard newRows > 0 else { return }

        let neededHeight = previewHeightPixels + newRows
        if neededHeight > previewBitmap.height {
            let newCapacity = neededHeight + bitmap.height * 5
            guard let grown = makeOutputBitmap(from: bitmap, totalHeightPixels: newCapacity) else { return }
            copyRows(
                from: previewBitmap,
                sourceStartRow: 0,
                rowCount: previewHeightPixels,
                to: grown,
                destinationStartRow: 0
            )
            self.previewBitmap = grown
            previewBitmap = grown
        }

        copyRows(
            from: bitmap,
            sourceStartRow: overlapPixels,
            rowCount: newRows,
            to: previewBitmap,
            destinationStartRow: previewHeightPixels
        )

        previewHeightPixels += newRows
        emitPreviewImage()
    }

    private func emitPreviewImage() {
        guard let previewBitmap, previewHeightPixels > 0 else { return }

        let totalHeightPoints = CGFloat(previewHeightPixels) / previewScale
        guard let image = previewBitmap.makeImage(
            pointSize: NSSize(width: previewPointWidth, height: totalHeightPoints),
            pixelHeight: previewHeightPixels
        ) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            self?.onPreviewUpdated?(image)
        }
    }

    // MARK: - Final Stitch

    private func stitchAcceptedFrames() -> NSImage? {
        guard let firstFrame = frames.first else { return nil }

        let bitmapHeight = firstFrame.bitmap.height
        let scale = CGFloat(bitmapHeight) / max(firstFrame.image.size.height, 1)

        let totalHeightPixels = overlaps.reduce(bitmapHeight) { partialResult, overlap in
            partialResult + (bitmapHeight - overlap)
        }
        let totalHeightPoints = CGFloat(totalHeightPixels) / scale

        guard let stitchedBitmap = makeOutputBitmap(from: firstFrame.bitmap, totalHeightPixels: totalHeightPixels) else {
            return firstFrame.image
        }

        var destinationRow = 0

        for index in frames.indices {
            let sourceStartRow = index == 0 ? 0 : overlaps[index - 1]
            let rowsToCopy = bitmapHeight - sourceStartRow

            copyRows(
                from: frames[index].bitmap,
                sourceStartRow: sourceStartRow,
                rowCount: rowsToCopy,
                to: stitchedBitmap,
                destinationStartRow: destinationRow
            )

            destinationRow += rowsToCopy
        }

        return stitchedBitmap.makeImage(
            pointSize: NSSize(width: firstFrame.image.size.width, height: totalHeightPoints),
            pixelHeight: totalHeightPixels
        )
    }

    // MARK: - Overlap Detection

    /// Computes how many rows at the top of `current` overlap with the bottom of
    /// `previous`, using Apple Vision's translational image registration. Vision
    /// is significantly more accurate than per-row pixel matching on content
    /// where neighbouring rows look nearly identical (text, code, chat logs):
    /// it considers the whole image as a 2D signal rather than scoring rows
    /// independently, so it doesn't snap to wrong-but-locally-plausible offsets.
    ///
    /// The returned value is in pixels and lies in `0...min(previous.height, current.height)`.
    /// `expectedNewContentPixels` is retained in the signature for source
    /// compatibility with the caller but is no longer consulted — Vision needs
    /// no hint.
    private func findOverlap(
        previous: BitmapData,
        current: BitmapData,
        expectedNewContentPixels: Int?
    ) -> Int {
        let height = min(previous.height, current.height)
        guard height > 0 else { return 0 }

        guard let previousCG = previous.makeCGImage(pixelHeight: previous.height),
              let currentCG = current.makeCGImage(pixelHeight: current.height) else {
            return height
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previousCG)
        let handler = VNImageRequestHandler(cgImage: currentCG, options: [:])

        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNImageTranslationAlignmentObservation
        else {
            return height
        }

        // alignmentTransform.ty is the pixel distance the source (current frame)
        // must be shifted to align with the target (previous frame). For a page
        // that scrolled DOWN between frames, this comes out positive and equals
        // the height of newly-revealed content at the bottom of `current`.
        let newContentPx = Int(observation.alignmentTransform.ty.rounded())
        guard newContentPx > 0 else { return height }  // upward scroll or no shift

        let overlap = height - newContentPx
        return max(0, min(height, overlap))
    }

    // MARK: - Image Helpers

    private func imagesAreNearlyIdentical(_ lhs: BitmapData, _ rhs: BitmapData) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return false
        }

        let numCols = min(32, max(16, lhs.width / 20))
        let numRows = min(32, max(16, lhs.height / 20))
        let sampleCols = sampledColumns(width: lhs.width, count: numCols)
        let sampleRows = sampledRows(height: lhs.height, count: numRows)

        var diff = 0
        var comparisons = 0

        for row in sampleRows {
            for col in sampleCols {
                diff += pixelDiff(lhs.pixel(x: col, y: row), rhs.pixel(x: col, y: row))
                comparisons += 1
            }
        }

        guard comparisons > 0 else { return false }
        return diff / comparisons < 3
    }

    private func sampledColumns(width: Int, count: Int) -> [Int] {
        guard width > 0, count > 0 else { return [] }

        let inset = min(max(4, width / 12), max(4, width / 4))
        let lowerBound = min(width - 1, inset)
        let upperBound = max(lowerBound, width - inset - 1)
        let span = max(1, upperBound - lowerBound + 1)

        var result: [Int] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let column = lowerBound + min(span - 1, span * (index * 2 + 1) / max(1, count * 2))
            if result.last != column {
                result.append(column)
            }
        }

        return result
    }

    private func sampledRows(height: Int, count: Int) -> [Int] {
        guard height > 0, count > 0 else { return [] }

        var rows: [Int] = []
        rows.reserveCapacity(count)

        for index in 0..<count {
            let row = min(height - 1, height * (index * 2 + 1) / max(1, count * 2))
            if rows.last != row {
                rows.append(row)
            }
        }

        return rows
    }

    private func pixelDiff(_ lhs: (r: UInt8, g: UInt8, b: UInt8), _ rhs: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
        abs(Int(lhs.r) - Int(rhs.r)) +
        abs(Int(lhs.g) - Int(rhs.g)) +
        abs(Int(lhs.b) - Int(rhs.b))
    }

    private func bitmapData(from image: NSImage) -> BitmapData? {
        guard let rep = image.bitmapImageRepPreservingBacking() else { return nil }
        return BitmapData(rep: rep)
    }

    private func makeOutputBitmap(from source: BitmapData, totalHeightPixels: Int) -> BitmapData? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.width,
            pixelsHigh: totalHeightPixels,
            bitsPerSample: source.rep.bitsPerSample,
            samplesPerPixel: source.rep.samplesPerPixel,
            hasAlpha: source.rep.hasAlpha,
            isPlanar: false,
            colorSpaceName: source.rep.colorSpaceName,
            bitmapFormat: source.rep.bitmapFormat,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        return BitmapData(rep: rep, format: source.imageFormat)
    }

    private func copyRows(
        from source: BitmapData,
        sourceStartRow: Int,
        rowCount: Int,
        to destination: BitmapData,
        destinationStartRow: Int
    ) {
        guard rowCount > 0 else { return }

        let bytesPerRow = min(source.width * source.bytesPerPixelValue, min(source.bytesPerRow, destination.bytesPerRow))

        for rowOffset in 0..<rowCount {
            let sourceOffset = (sourceStartRow + rowOffset) * source.bytesPerRow
            let destinationOffset = (destinationStartRow + rowOffset) * destination.bytesPerRow
            memcpy(
                destination.data.advanced(by: destinationOffset),
                source.data.advanced(by: sourceOffset),
                bytesPerRow
            )
        }
    }

    private final class BitmapData {
        let rep: NSBitmapImageRep
        let data: UnsafeMutablePointer<UInt8>
        let bytesPerRow: Int
        let width: Int
        let height: Int
        let imageFormat: ImageFormat
        private let bytesPerPixel: Int

        init?(rep: NSBitmapImageRep, format: ImageFormat? = nil) {
            guard let data = rep.bitmapData else { return nil }

            let resolvedFormat: ImageFormat
            if let format {
                resolvedFormat = format
            } else {
                let cgImage = rep.cgImage
                guard
                    let cgImage,
                    let colorSpace = cgImage.colorSpace
                else {
                    return nil
                }

                resolvedFormat = ImageFormat(
                    bitsPerComponent: cgImage.bitsPerComponent,
                    bitsPerPixel: cgImage.bitsPerPixel,
                    bitmapInfo: cgImage.bitmapInfo,
                    colorSpace: colorSpace
                )
            }

            self.rep = rep
            self.data = data
            self.bytesPerRow = rep.bytesPerRow
            self.width = rep.pixelsWide
            self.height = rep.pixelsHigh
            self.imageFormat = resolvedFormat
            self.bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        }

        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else {
                return (0, 0, 0)
            }

            let offset = y * bytesPerRow + x * bytesPerPixel
            return (data[offset], data[offset + 1], data[offset + 2])
        }

        func makeImage(pointSize: NSSize, pixelHeight: Int) -> NSImage? {
            guard let cgImage = makeCGImage(pixelHeight: pixelHeight) else { return nil }
            return NSImage(cgImage: cgImage, size: pointSize)
        }

        /// Builds a CGImage covering the top `pixelHeight` rows of this bitmap.
        /// Shared by `makeImage(pointSize:pixelHeight:)` (the preview/output
        /// pipeline) and by `findOverlap` (Apple Vision input).
        func makeCGImage(pixelHeight: Int) -> CGImage? {
            guard pixelHeight > 0, pixelHeight <= height else { return nil }

            let byteCount = pixelHeight * bytesPerRow
            let buffer = UnsafeBufferPointer(start: data, count: byteCount)
            let imageData = Data(buffer: buffer)

            guard let provider = CGDataProvider(data: imageData as CFData) else { return nil }
            return CGImage(
                width: width,
                height: pixelHeight,
                bitsPerComponent: imageFormat.bitsPerComponent,
                bitsPerPixel: imageFormat.bitsPerPixel,
                bytesPerRow: bytesPerRow,
                space: imageFormat.colorSpace,
                bitmapInfo: imageFormat.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }

        var bytesPerPixelValue: Int { bytesPerPixel }
    }
}
