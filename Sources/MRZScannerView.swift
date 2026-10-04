import SwiftUI
import AVFoundation
import Vision

/// The 3 values that unlock the chip.
struct MRZInfo: Hashable {
    let documentNumber: String
    let dateOfBirth: String   // YYMMDD
    let dateOfExpiry: String  // YYMMDD
}

/// Camera screen that reads the MRZ and returns the 3 values.
struct MRZScannerView: UIViewControllerRepresentable {
    let onResult: (MRZInfo) -> Void

    func makeUIViewController(context: Context) -> MRZScannerController {
        let vc = MRZScannerController()
        vc.onResult = onResult
        return vc
    }

    func updateUIViewController(_ uiViewController: MRZScannerController, context: Context) {}
}

/// Camera + text recognition. Reads live video, or a photo when the button is tapped.
final class MRZScannerController: UIViewController,
                                  AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCapturePhotoCaptureDelegate {
    var onResult: ((MRZInfo) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mrz.scanner")
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let statusLabel = UILabel()
    private let shutter = UIButton(type: .system)
    private var finished = false
    private var busy = false
    private var frameCounter = 0
    /// A value is accepted only after it is read the same way 3 times.
    private var votes: [MRZInfo: Int] = [:]
    private let requiredVotes = 3

    /// Sets up the camera preview, guide box, status text and photo button.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        // Yellow box shaped like the passport photo page.
        let guide = UIView()
        guide.layer.borderColor = UIColor.systemYellow.cgColor
        guide.layer.borderWidth = 2
        guide.layer.cornerRadius = 10
        guide.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(guide)

        statusLabel.text = "Fit the whole photo page in the box. Looking for the MRZ…"
        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        var cfg = UIButton.Configuration.filled()
        cfg.title = "Take photo"
        cfg.image = UIImage(systemName: "camera.fill")
        cfg.imagePadding = 8
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = .white
        cfg.baseForegroundColor = .black
        cfg.contentInsets = .init(top: 14, leading: 28, bottom: 14, trailing: 28)
        shutter.configuration = cfg
        shutter.addTarget(self, action: #selector(takePhoto), for: .touchUpInside)
        shutter.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shutter)

        NSLayoutConstraint.activate([
            guide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guide.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            guide.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.94),
            guide.heightAnchor.constraint(equalTo: guide.widthAnchor, multiplier: 0.70),
            statusLabel.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        queue.async { [session] in if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    /// Back camera with video frames and photo capture.
    private func configureSession() {
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        // Autofocus for close range.
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }

        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(video) { session.addOutput(video) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        // Frames stay landscape; Vision is told the orientation instead.
    }

    // MARK: Live frames

    /// Runs OCR on every 6th video frame.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, !busy, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCounter += 1
        if frameCounter % 6 != 0 { return }
        recognize(handler: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right), fromPhoto: false)
    }

    // MARK: Manual shutter

    /// Photo button: take a full photo and read it.
    @objc private func takePhoto() {
        guard !finished, !busy else { return }
        busy = true
        setStatus("Reading photo…")
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    /// Photo taken: run OCR on it.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let cg = UIImage(data: data)?.cgImage else {
            busy = false
            setStatus("Could not capture. Try again.")
            return
        }
        // Use the photo's own orientation.
        let orientation = CGImagePropertyOrientation(UIImage(data: data)?.imageOrientation ?? .up)
        queue.async {
            self.recognize(handler: VNImageRequestHandler(cgImage: cg, orientation: orientation), fromPhoto: true)
        }
    }

    // MARK: OCR

    /// Finds text in the image and tries to parse the MRZ.
    private func recognize(handler: VNImageRequestHandler, fromPhoto: Bool) {
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let self, !self.finished else { return }
            let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
            let lines = Self.assembleRows(observations)
            if let info = MRZParser.parse(lines: lines) {
                if fromPhoto {
                    // A photo is accepted right away; the user confirms on the next screen.
                    self.accept(info)
                } else {
                    self.votes[info, default: 0] += 1
                    let n = self.votes[info]!
                    self.setStatus("MRZ read \(n)/\(self.requiredVotes) — hold still…")
                    if n >= self.requiredVotes { self.accept(info) }
                }
            } else if fromPhoto {
                self.busy = false
                let mrzLike = lines.map(MRZParser.normalize).filter { $0.contains("<") || $0.count >= 28 }
                if mrzLike.isEmpty {
                    self.setStatus("No MRZ found. Make sure the two lines at the bottom of the page are sharp and in the box.")
                } else {
                    // Show what was read so the user can spot the mistake.
                    self.setStatus("Check digit failed. OCR read:\n" + mrzLike.suffix(3).joined(separator: "\n"))
                }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try? handler.perform([request])
    }

    /// Returns the result (only once).
    private func accept(_ info: MRZInfo) {
        guard !finished else { return }
        finished = true
        DispatchQueue.main.async { self.onResult?(info) }
    }

    /// Joins text pieces on the same line, then sorts lines top to bottom.
    private static func assembleRows(_ obs: [VNRecognizedTextObservation]) -> [String] {
        var rows: [(y: CGFloat, items: [(x: CGFloat, text: String)])] = []
        for o in obs {
            guard let text = o.topCandidates(1).first?.string else { continue }
            let y = o.boundingBox.midY, x = o.boundingBox.minX, h = o.boundingBox.height
            if let i = rows.firstIndex(where: { abs($0.y - y) < max(h * 0.6, 0.015) }) {
                rows[i].items.append((x, text))
            } else {
                rows.append((y, [(x, text)]))
            }
        }
        // In Vision, the top of the image has the higher Y.
        return rows.sorted { $0.y > $1.y }
            .map { $0.items.sorted { $0.x < $1.x }.map(\.text).joined() }
    }

    /// Updates the text under the box.
    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.text = text }
    }
}

/// UIImage orientation to Vision orientation.
private extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Finds MRZ line 2 in the OCR text and checks its check digits.
enum MRZParser {
    // Number, check, country, birth date, check, sex, expiry, check.
    // Letters that look like digits are allowed here and fixed later.
    private static let line2 = try! NSRegularExpression(
        // Country also allows digits: OCR sometimes reads KOR as K0R.
        pattern: "([A-Z0-9<]{9})([0-9OILSBZ])([A-Z0-9<]{3})([0-9OILSBZ]{6})([0-9OILSBZ])([MFX<])([0-9OILSBZ]{6})([0-9OILSBZ])")

    /// Returns the 3 values if all check digits pass.
    static func parse(lines raw: [String]) -> MRZInfo? {
        let candidates = raw.map(normalize) + [raw.map(normalize).joined()]
        for text in candidates where text.count >= 28 {
            let ns = text as NSString
            for m in line2.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let g = (1...8).map { ns.substring(with: m.range(at: $0)) }
                let dob = fixDigits(g[3]), expiry = fixDigits(g[6])
                guard check(dob) == fixDigits(g[4]), check(expiry) == fixDigits(g[7]) else { continue }
                // The passport number mixes letters and digits, so try look-alike swaps until the check digit fits.
                guard let numberField = resolveNumber(g[0], expectedCheck: fixDigits(g[1])) else { continue }
                let number = numberField.replacingOccurrences(of: "<", with: "")
                guard !number.isEmpty else { continue }
                return MRZInfo(documentNumber: number, dateOfBirth: dob, dateOfExpiry: expiry)
            }
        }
        return nil
    }

    /// Characters OCR often mixes up.
    private static let confusable: [Character: Character] = [
        "O": "0", "0": "O", "I": "1", "1": "I", "L": "1", "S": "5", "5": "S",
        "B": "8", "8": "B", "Z": "2", "2": "Z", "D": "0", "Q": "0", "G": "6", "6": "G",
    ]

    /// Tries look-alike swaps until the check digit matches.
    static func resolveNumber(_ field: String, expectedCheck: String) -> String? {
        if check(field) == expectedCheck { return field }
        let chars = Array(field)
        let slots = chars.indices.filter { confusable[chars[$0]] != nil }
        guard !slots.isEmpty, slots.count <= 9 else { return nil }
        for mask in 1..<(1 << slots.count) {
            var v = chars
            for (bit, idx) in slots.enumerated() where mask & (1 << bit) != 0 {
                v[idx] = confusable[chars[idx]]!
            }
            let candidate = String(v)
            if check(candidate) == expectedCheck { return candidate }
        }
        return nil
    }

    /// Uppercase, remove spaces, fix look-alikes of '<'.
    static func normalize(_ s: String) -> String {
        var t = s.uppercased()
        for (from, to) in [(" ", ""), ("«", "<<"), ("‹", "<"), ("〈", "<"), ("く", "<")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return t.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "<") }
    }

    /// For number-only fields: O to 0, I/L to 1, S to 5, B to 8, Z to 2.
    static func fixDigits(_ s: String) -> String {
        String(s.map { c -> Character in
            switch c { case "O": "0"; case "I", "L": "1"; case "S": "5"; case "B": "8"; case "Z": "2"; default: c }
        })
    }

    /// Check digit as text.
    private static func check(_ s: String) -> String {
        String(PassportUtils.calcCheckSum(s))
    }
}
