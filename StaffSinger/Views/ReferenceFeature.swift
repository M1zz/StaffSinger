//
//  ReferenceFeature.swift
//  StaffSinger
//
//  "Photograph two measures and copy them onto this score" — the offline,
//  manual flavor. The user shoots (or picks) a photo, crops it down to the two
//  measures they care about, and the crop floats over the staff as a faint,
//  draggable reference while they tap the notes in by hand. No recognition,
//  no network — just a guide you can see while you transcribe.
//

import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

// MARK: - Shared state

/// Holds the cropped reference image and how it's shown. Kept out of `Score`
/// (which is Codable) because a UIImage is transient, per-session scaffolding.
@MainActor
final class ReferenceStore: ObservableObject {
    @Published var image: UIImage? = nil
    @Published var opacity: Double = 0.85
    @Published var visible: Bool = true

    func set(_ img: UIImage) {
        image = img
        opacity = 0.85
        visible = true
    }

    func clear() { image = nil }
}

/// Wrapper so a freshly picked image can drive a `.fullScreenCover(item:)`.
struct PickedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - Aperture camera

/// A live camera with a fixed "two-measure" cut-out: the user lines the staff up
/// inside the bright window and shoots, and the photo is cropped to exactly that
/// window — no separate crop step. Wide (≈3:1) to match a two-measure strip.
struct ApertureCameraView: UIViewControllerRepresentable {
    var aspect: CGFloat = 3.0
    /// 한 마디의 박 수. 두 마디를 읽는다.
    var measureBeats: Double = 4
    var onCapture: (UIImage) -> Void
    /// 비추는 동안 악보가 다 읽혔을 때 — 그 장면과 읽은 음표.
    var onRead: (UIImage, OMR.Reading) -> Void = { _, _ in }
    /// 음표 하나를 확정할 때마다 — 그 음.
    var onNote: (Pitch) -> Void = { _ in }
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> ApertureCameraController {
        let vc = ApertureCameraController()
        vc.aspect = aspect
        vc.measureBeats = measureBeats
        vc.onCapture = onCapture
        vc.onRead = onRead
        vc.onNote = onNote
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ vc: ApertureCameraController, context: Context) {}
}

final class ApertureCameraController: UIViewController, AVCapturePhotoCaptureDelegate,
                                     AVCaptureVideoDataOutputSampleBufferDelegate {
    var aspect: CGFloat = 3.0
    var measureBeats: Double = 4
    var onCapture: ((UIImage) -> Void)?
    var onRead: ((UIImage, OMR.Reading) -> Void)?
    var onNote: ((Pitch) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var preview: AVCaptureVideoPreviewLayer?
    private let dim = CAShapeLayer()
    private let frameLine = CAShapeLayer()
    private let staffGuide = CAShapeLayer()   // 지금 읽고 있는 오선 — 찾은 자리에 그린다
    private let shutter = UIButton(type: .system)
    private let hint = UILabel()
    private let grips = CAShapeLayer()        // 틀의 손잡이 — 가장자리와 모서리
    private var apertureRect: CGRect = .zero
    /// 틀의 크기. 악보마다 두 마디의 너비와 오선 위아래 높이가 달라서 끌어서 맞춘다.
    /// 0 이면 아직 정하지 않은 것 — 너비는 가득, 높이는 너비의 1/aspect 로 시작한다.
    private var apertureWidth = CGFloat(UserDefaults.standard.double(forKey: "camera.apertureWidth"))
    private var apertureHeight = CGFloat(UserDefaults.standard.double(forKey: "camera.apertureHeight"))
    private var sizeAtDragStart: CGSize = .zero
    private var drag: (x: CGFloat, y: CGFloat) = (0, 0)   // 끄는 방향이 틀을 키우는 쪽(±1), 0 이면 그 축은 그대로
    private var tooWide = 0                   // 두 마디보다 많이 보인 읽기가 연달아 몇 번인지

    // 비춰 읽기 — 들고 있는 동안 왼쪽 음표부터 하나씩 확정된다.
    private let videoOut = AVCaptureVideoDataOutput()
    private let readQueue = DispatchQueue(label: "staffsinger.live-read", qos: .userInitiated)
    private let ciContext = CIContext()
    private let marks = CAShapeLayer()          // 확정한 음표
    private let missedMarks = CAShapeLayer()    // 읽지 못해 포기한 음표
    private let pendingMarks = CAShapeLayer()   // 보이지만 아직 확정하지 않은 음표
    private let exposureLine = CAShapeLayer()   // 얼마나 읽었는지 — 틀을 따라 차오른다
    private var exposure = OMR.Exposure()

    // 확인 — 다 읽으면 멈춘 장면 위에서 맞는지 보고, 틀린 음표만 다시 읽는다.
    private let still = CALayer()               // 읽은 그 장면
    private let names = CALayer()               // 음표마다 읽은 음 이름
    private let reviewBar = UIStackView()
    private let retryButton = UIButton(type: .system)
    private var frames: [(reading: OMR.Reading, image: UIImage)] = []   // 최근 장면들
    private var flagged: Set<Int> = []          // 사용자가 틀렸다고 짚은 음표
    private var reviewed: UIImage?
    private var lastRead = Date.distantPast     // readQueue 에서만 쓴다
    private let geometryLock = NSLock()
    private var geometry: (aperture: CGRect, bounds: CGSize) = (.zero, .zero)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if configureSession() {
            setupOverlay()
            setupControls()
        } else {
            showUnavailable()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
        }
    }

    // MARK: Session

    private func configureSession() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else { return false }

        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        session.addOutput(output)
        if session.canAddOutput(videoOut) {
            videoOut.alwaysDiscardsLateVideoFrames = true
            videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOut.setSampleBufferDelegate(self, queue: readQueue)
            session.addOutput(videoOut)
        }
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0)
        preview = layer
        return true
    }

    private func startIfPossible() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            runSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async { ok ? self?.runSession() : self?.showUnavailable() }
            }
        default:
            showUnavailable()
        }
    }

    private func runSession() {
        guard preview != nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    // MARK: Overlay + controls

    private func setupOverlay() {
        dim.fillRule = .evenOdd
        dim.fillColor = UIColor.black.withAlphaComponent(0.6).cgColor
        view.layer.addSublayer(dim)
        still.contentsGravity = .resize
        still.isHidden = true
        view.layer.addSublayer(still)
        frameLine.fillColor = UIColor.clear.cgColor
        frameLine.strokeColor = UIColor.white.cgColor
        frameLine.lineWidth = 2
        view.layer.addSublayer(frameLine)

        staffGuide.fillColor = UIColor.clear.cgColor
        staffGuide.strokeColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
        staffGuide.lineWidth = 1.5
        view.layer.addSublayer(staffGuide)

        pendingMarks.fillColor = UIColor.clear.cgColor
        pendingMarks.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        pendingMarks.lineWidth = 1.5
        view.layer.addSublayer(pendingMarks)
        for (layer, color) in [(marks, UIColor.systemBlue), (missedMarks, UIColor.systemRed)] {
            layer.fillColor = color.withAlphaComponent(0.7).cgColor
            layer.strokeColor = UIColor.white.cgColor
            layer.lineWidth = 1.5
            view.layer.addSublayer(layer)
        }
        exposureLine.fillColor = UIColor.clear.cgColor
        exposureLine.strokeColor = UIColor.systemBlue.cgColor
        exposureLine.lineWidth = 4
        exposureLine.strokeEnd = 0
        view.layer.addSublayer(exposureLine)

        view.layer.addSublayer(names)
        grips.fillColor = UIColor.white.cgColor
        view.layer.addSublayer(grips)
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize)))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch)))
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(flag)))

        hint.text = Self.holdHint
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 15, weight: .semibold)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
    }

    private static let holdHint = String(localized: "이 칸에 두 마디를 맞추고 잠시 비춰 주세요", comment: "Camera hint when the score is read just by holding the camera over it")
    private static let missedHint = String(localized: "빨간 음표는 읽지 못했어요", comment: "Camera hint when a note could not be read and is marked in red")
    private static let closerHint = String(localized: "두 마디만 보이게 더 가까이 대 주세요", comment: "Camera hint when more than two measures are inside the frame")

    private static let reviewHint = String(localized: "맞게 읽었나요? 틀린 음표는 눌러 주세요", comment: "Camera hint after the score was read: confirm it, or tap the notes that are wrong")

    /// 틀을 끌어 크기를 바꾼다. 양옆 가장자리는 너비, 위아래는 높이, 모서리는 둘 다.
    /// 틀은 가운데에 머문다.
    @objc private func resize(_ pan: UIPanGestureRecognizer) {
        guard exposure.result == nil else { return }
        switch pan.state {
        case .began:
            let p = pan.location(in: view), r = apertureRect
            let dx = abs(p.x - r.midX) - r.width / 2, dy = abs(p.y - r.midY) - r.height / 2
            let sideways = dx > -44                       // 왼쪽·오른쪽 가장자리나 그 바깥
            let upDown = dy > -44 || !sideways            // 위·아래 가장자리, 아니면 한가운데도 높이
            drag = (sideways ? (p.x < r.midX ? -1 : 1) : 0, upDown ? (p.y < r.midY ? -1 : 1) : 0)
            sizeAtDragStart = r.size
        case .changed:
            let t = pan.translation(in: view)
            if drag.x != 0 { apertureWidth = max(1, sizeAtDragStart.width + 2 * drag.x * t.x) }
            if drag.y != 0 { apertureHeight = max(1, sizeAtDragStart.height + 2 * drag.y * t.y) }
            reframed()
        case .ended, .cancelled:
            keepFrame()
        default: break
        }
    }

    /// 두 손가락으로 벌리고 오므려 틀을 통째로 키우고 줄인다.
    @objc private func pinch(_ pinch: UIPinchGestureRecognizer) {
        guard exposure.result == nil else { return }
        switch pinch.state {
        case .began:
            sizeAtDragStart = apertureRect.size
        case .changed:
            apertureWidth = max(1, sizeAtDragStart.width * pinch.scale)
            apertureHeight = max(1, sizeAtDragStart.height * pinch.scale)
            reframed()
        case .ended, .cancelled:
            keepFrame()
        default: break
        }
    }

    private func reframed() {
        exposure = OMR.Exposure()   // 틀이 바뀌면 처음부터 다시 읽는다
        frames = []
        view.setNeedsLayout()
    }

    private func keepFrame() {
        (apertureWidth, apertureHeight) = (apertureRect.width, apertureRect.height)
        UserDefaults.standard.set(Double(apertureWidth), forKey: "camera.apertureWidth")
        UserDefaults.standard.set(Double(apertureHeight), forKey: "camera.apertureHeight")
    }

    private func setupControls() {
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 33
        shutter.layer.borderColor = UIColor.white.cgColor
        shutter.layer.borderWidth = 4
        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.addTarget(self, action: #selector(shoot), for: .touchUpInside)
        shutter.accessibilityLabel = String(localized: "촬영")
        view.addSubview(shutter)

        let cancel = UIButton(type: .system)
        cancel.setTitle(String(localized: "취소"), for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancel)

        func pill(_ title: String, filled: Bool, _ action: Selector, on button: UIButton = UIButton(type: .system)) -> UIButton {
            var look: UIButton.Configuration = filled ? .filled() : .gray()
            look.title = title
            look.cornerStyle = .capsule
            look.baseForegroundColor = .white
            look.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            button.configuration = look
            button.addTarget(self, action: action, for: .touchUpInside)
            return button
        }
        reviewBar.addArrangedSubview(pill(String(localized: "처음부터", comment: "Camera review: throw the reading away and read the score again from the start"), filled: false, #selector(startOver)))
        reviewBar.addArrangedSubview(pill(String(localized: "빨간 음표만 다시", comment: "Camera review: read only the notes marked red again"), filled: false, #selector(readAgain), on: retryButton))
        reviewBar.addArrangedSubview(pill(String(localized: "악보에 넣기"), filled: true, #selector(accept)))
        reviewBar.spacing = 12
        reviewBar.isHidden = true
        reviewBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reviewBar)

        NSLayoutConstraint.activate([
            reviewBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            reviewBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            shutter.widthAnchor.constraint(equalToConstant: 66),
            shutter.heightAnchor.constraint(equalToConstant: 66),
            shutter.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            shutter.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
    }

    private func showUnavailable() {
        let label = UILabel()
        label.text = String(localized: "카메라를 사용할 수 없습니다.\n사진 보관함에서 선택해 주세요.")
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        let close = UIButton(type: .system)
        close.setTitle(String(localized: "닫기"), for: .normal)
        close.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            close.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 20),
            close.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        orient(preview?.connection)

        // Wide aperture, as large as fits between the screen's left edge and the
        // shutter — the shutter must never sit on top of the notes.
        let left = max(view.safeAreaInsets.left, 8) + 16
        let right = (shutter.superview == nil ? view.bounds.maxX : shutter.frame.minX) - 16
        let widest = max(1, min(right - left, 900))
        let w = min(max(apertureWidth > 0 ? apertureWidth : widest, min(160, widest)), widest)
        let tallest = max(60, view.bounds.height - 180)
        let h = min(max(apertureHeight > 0 ? apertureHeight : w / aspect, 60), tallest)
        apertureRect = CGRect(x: (left + right) / 2 - w / 2,
                              y: view.bounds.midY - h / 2, width: w, height: h)

        let path = UIBezierPath(rect: view.bounds)
        path.append(UIBezierPath(roundedRect: apertureRect, cornerRadius: 6))
        dim.path = path.cgPath
        frameLine.path = UIBezierPath(roundedRect: apertureRect, cornerRadius: 6).cgPath
        exposureLine.path = frameLine.path
        still.frame = apertureRect
        // 손잡이 — 네 변의 가운데와 네 모서리.
        let grip = UIBezierPath()
        let r = apertureRect
        for y in [r.minY, r.maxY] {
            grip.append(UIBezierPath(roundedRect: CGRect(x: r.midX - 22, y: y - 3, width: 44, height: 6), cornerRadius: 3))
        }
        for x in [r.minX, r.maxX] {
            grip.append(UIBezierPath(roundedRect: CGRect(x: x - 3, y: r.midY - 22, width: 6, height: 44), cornerRadius: 3))
        }
        for (x, y) in [(r.minX, r.minY), (r.maxX, r.minY), (r.minX, r.maxY), (r.maxX, r.maxY)] {
            let (inX, inY): (CGFloat, CGFloat) = (x == r.minX ? 1 : -1, y == r.minY ? 1 : -1)
            grip.append(UIBezierPath(rect: CGRect(x: x - 3 * inX, y: y - 3 * inY, width: 24 * inX, height: 6 * inY).standardized))
            grip.append(UIBezierPath(rect: CGRect(x: x - 3 * inX, y: y - 3 * inY, width: 6 * inX, height: 24 * inY).standardized))
        }
        grips.path = grip.cgPath
        orient(videoOut.connection(with: .video))
        geometryLock.lock()
        geometry = (apertureRect, view.bounds.size)
        geometryLock.unlock()

    }

    // MARK: Capture

    @objc private func cancelTapped() { onCancel?() }

    @objc private func shoot() {
        guard session.isRunning, exposure.result == nil else { return }
        orient(output.connection(with: .video))
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        let result = cropToAperture(image) ?? image
        DispatchQueue.main.async { self.onCapture?(result) }
    }

    // MARK: Live reading

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 1초에 다섯 번쯤만 읽는다 — 그래야 '노출'에 시간이 걸리고 기기도 쉰다.
        guard Date().timeIntervalSince(lastRead) > 0.2,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastRead = Date()
        geometryLock.lock()
        let g = geometry
        geometryLock.unlock()
        guard let image = crop(buffer, aperture: g.aperture, bounds: g.bounds) else { return }
        let reading = OMR.transcribe(image, maxBeats: measureBeats * 2, measureBeats: measureBeats)
        DispatchQueue.main.async { self.expose(reading, from: image) }
    }

    /// 화면의 틀에 해당하는 부분을 영상 한 장에서 잘라 낸다. 영상은 화면을
    /// 가득 채우도록(aspect fill) 보이므로 그 배율과 밀림을 되돌린다.
    private func crop(_ buffer: CVPixelBuffer, aperture: CGRect, bounds: CGSize) -> UIImage? {
        let W = CGFloat(CVPixelBufferGetWidth(buffer)), H = CGFloat(CVPixelBufferGetHeight(buffer))
        guard aperture.width > 1, bounds.width > 1, W > 1, H > 1 else { return nil }
        let scale = max(bounds.width / W, bounds.height / H)
        let ox = (bounds.width - W * scale) / 2, oy = (bounds.height - H * scale) / 2
        let r = CGRect(x: (aperture.minX - ox) / scale, y: (aperture.minY - oy) / scale,
                       width: aperture.width / scale, height: aperture.height / scale)
        // Core Image 는 왼쪽 아래가 원점이다.
        let rect = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height).integral
        let frame = CIImage(cvPixelBuffer: buffer)
        guard frame.extent.contains(rect),
              let cg = ciContext.createCGImage(frame, from: rect) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 한 번 읽은 결과를 겹친다. 거듭 같게 읽힌 음표가 왼쪽부터 하나씩
    /// 확정되고, 끝까지 가면 그 장면을 멈춰 놓고 맞는지 묻는다.
    private func expose(_ reading: OMR.Reading, from image: UIImage) {
        guard exposure.result == nil else { return }
        frames.append((reading, image))
        if frames.count > 8 { frames.removeFirst() }
        // 두 마디보다 많이 보이면 찍지 않고 알려 준다. 한 번 잘못 읽은 것에
        // 글이 깜빡이지 않게, 연달아 두 번일 때부터.
        tooWide = reading.measures > 2 ? tooWide + 1 : 0
        let far = tooWide >= 2
        if far { exposure = OMR.Exposure() }
        let step = reading.measures <= 2 ? exposure.add(reading) : .waiting
        let missed = !exposure.failed.isEmpty
        hint.text = far ? Self.closerHint : missed ? Self.missedHint : Self.holdHint
        hint.textColor = far ? .systemYellow : missed ? .systemRed : .white
        frameLine.strokeColor = (far ? UIColor.systemYellow : .white).cgColor

        // 자리는 확정한 음표와 맞는 가장 새 장면에서 가져와, 손이 움직여도 따라간다.
        draw(exposure.view, staff: reading.staffLines, red: Set(exposure.failed), settled: exposure.settled)
        exposureLine.strokeEnd = exposure.progress

        switch step {
        case .waiting:
            break
        case .settled(let i, let pitch):   // 팅 — 그 음이 울린다
            ring(at: spot(i, in: exposure.view), radius: dotRadius(exposure.view), color: .systemBlue)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onNote?(pitch)
        case .failed(let i):
            ring(at: spot(i, in: exposure.view), radius: dotRadius(exposure.view), color: .systemRed)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .done:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            review()
        }
    }

    private func spot(_ i: Int, in reading: OMR.Reading) -> CGPoint {
        guard reading.marks.indices.contains(i) else { return CGPoint(x: apertureRect.midX, y: apertureRect.midY) }
        return CGPoint(x: apertureRect.minX + reading.marks[i].x * apertureRect.width,
                       y: apertureRect.minY + reading.marks[i].y * apertureRect.height)
    }

    /// 점의 크기는 읽은 오선의 한 칸에 맞춘다.
    private func dotRadius(_ reading: OMR.Reading) -> CGFloat {
        let lines = reading.staffLines
        return (lines.count == 5 ? (lines[4] - lines[0]) / 4 * apertureRect.height : apertureRect.height * 0.08) * 0.6
    }

    /// 읽은 것을 틀 위에 그린다 — 찾은 오선, 그리고 확정한 음표는 파랗게,
    /// 못 읽었거나 틀렸다고 짚은 음표는 빨갛게, 아직인 음표는 흐린 테두리로.
    private func draw(_ reading: OMR.Reading, staff: [Double], red: Set<Int>, settled: Int, named: Bool = false) {
        let found = UIBezierPath()
        for line in staff {
            let y = apertureRect.minY + line * apertureRect.height
            found.move(to: CGPoint(x: apertureRect.minX + 6, y: y))
            found.addLine(to: CGPoint(x: apertureRect.maxX - 6, y: y))
        }
        staffGuide.path = found.cgPath

        let radius = dotRadius(reading)
        let (sure, lost, waiting) = (UIBezierPath(), UIBezierPath(), UIBezierPath())
        names.sublayers = nil
        for i in reading.marks.indices {
            let c = spot(i, in: reading)
            let path = red.contains(i) ? lost : i < settled ? sure : waiting
            path.append(UIBezierPath(arcCenter: c, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true))
            guard named, reading.notes.indices.contains(i) else { continue }
            // 무엇으로 읽었는지 — 틀 바로 아래, 그 음표 밑에 적는다.
            let pitch = reading.notes[i].pitch
            let name = CATextLayer()
            name.string = ScoreTextFormat.usesKoreanNotation ? pitch.solfege : pitch.label
            name.fontSize = 13
            name.alignmentMode = .center
            name.contentsScale = traitCollection.displayScale
            name.foregroundColor = (red.contains(i) ? UIColor.systemRed : .white).cgColor
            name.frame = CGRect(x: c.x - 24, y: apertureRect.maxY + 6, width: 48, height: 18)
            names.addSublayer(name)
        }
        marks.path = sure.cgPath
        missedMarks.path = lost.cgPath
        pendingMarks.path = waiting.cgPath
    }

    // MARK: Review

    /// 다 읽었다 — 읽은 그 장면을 멈춰 보여 주고 맞는지 묻는다.
    private func review() {
        guard let whole = exposure.result else { return }
        // 음표 자리가 꼭 맞도록, 결과가 나온 바로 그 장면을 쓴다.
        let image = frames.last { $0.reading.notes.first?.id == whole.notes.first?.id }?.image ?? frames.last?.image
        reviewed = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.contents = image?.cgImage
        still.isHidden = false
        CATransaction.commit()
        setReviewing(true)
        redrawReview()
    }

    private func setReviewing(_ on: Bool) {
        reviewBar.isHidden = !on
        shutter.isHidden = on
        grips.isHidden = on
        exposureLine.isHidden = on
        if !on {
            still.isHidden = true
            names.sublayers = nil
            flagged = []
        }
    }

    private func redrawReview() {
        guard let whole = exposure.result else { return }
        let red = flagged.union(exposure.failed)
        draw(whole, staff: whole.staffLines, red: red, settled: whole.notes.count, named: true)
        hint.text = Self.reviewHint
        hint.textColor = .white
        retryButton.isEnabled = !red.isEmpty
    }

    /// 확인 중에 음표를 누르면 틀렸다고 짚는다. 다시 누르면 푼다.
    @objc private func flag(_ tap: UITapGestureRecognizer) {
        guard let whole = exposure.result else { return }
        let p = tap.location(in: view)
        func distance(_ i: Int) -> CGFloat { let c = spot(i, in: whole); return hypot(c.x - p.x, c.y - p.y) }
        guard let i = whole.marks.indices.min(by: { distance($0) < distance($1) }),
              distance(i) < max(32, dotRadius(whole) * 2.5), !exposure.failed.contains(i) else { return }
        flagged.formSymmetricDifference([i])
        UISelectionFeedbackGenerator().selectionChanged()
        redrawReview()
    }

    @objc private func startOver() {
        exposure = OMR.Exposure()
        frames = []
        setReviewing(false)
        draw(OMR.Reading(), staff: [], red: [], settled: 0)
    }

    /// 빨간 음표만 다시 읽는다 — 나머지는 그대로 둔다.
    @objc private func readAgain() {
        exposure.retry(Array(flagged))
        frames = []
        setReviewing(false)
    }

    @objc private func accept() {
        guard var whole = exposure.result, let image = reviewed else { return }
        for i in flagged { whole.unsure.insert(whole.notes[i].id) }   // 틀렸다고 짚은 채 넣으면 '확인 필요'로
        onRead?(image, whole)
    }


    /// 음표 하나가 정해지는 순간 — 그 자리에서 고리가 퍼졌다 사라진다.
    private func ring(at center: CGPoint, radius: CGFloat, color: UIColor) {
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ring.path = UIBezierPath(ovalIn: ring.bounds).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        view.layer.addSublayer(ring)
        let spread = CABasicAnimation(keyPath: "transform.scale")
        spread.fromValue = 1
        spread.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let pop = CAAnimationGroup()
        pop.animations = [spread, fade]
        pop.duration = 0.4
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(pop, forKey: nil)
        CATransaction.commit()
    }

    /// Map the on-screen aperture rect into the captured image and crop to it.
    private func cropToAperture(_ image: UIImage) -> UIImage? {
        guard let preview, let cg = uprightCGImage(image) else { return nil }
        let r = preview.metadataOutputRectConverted(fromLayerRect: apertureRect)
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        // metadataOutputRect is normalized with the image's natural (sensor)
        // orientation; once the image is drawn upright it maps directly.
        let px = CGRect(x: r.origin.x * W, y: r.origin.y * H,
                        width: r.size.width * W, height: r.size.height * H).integral
        guard px.width > 1, px.height > 1, let cropped = cg.cropping(to: px) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    private func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let r = UIGraphicsImageRenderer(size: image.size)
        return r.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }.cgImage
    }

    /// Turns the camera's picture to match how the screen is held.
    private func orient(_ connection: AVCaptureConnection?) {
        let angle: CGFloat = switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeRight: 0
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        default: 90
        }
        guard let connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}

// MARK: - Photo library (PHPicker — no permission prompt)

struct LibraryPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: LibraryPicker
        init(_ parent: LibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { self.parent.onImage(image) }
            }
        }
    }
}

// MARK: - Crop to two measures

/// A zoom/pan crop window with a wide (≈3:1) aperture that suits two measures.
/// Pinch to zoom, drag to position, then "사용" returns just the framed region.
struct ImageCropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onDone: (UIImage) -> Void

    private let aspect: CGFloat = 3.0

    @State private var scale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var gestureOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let apW = geo.size.width - 32
            let apH = apW / aspect

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 18) {
                    Text("두 마디가 칸에 꽉 차도록 손가락으로 확대·이동하세요")
                        .font(.subheadline).foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    // The aperture: image scaled to fill it, then pinched/panned,
                    // clipped to the window.
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: apW, height: apH)
                            .scaleEffect(scale * gestureScale)
                            .offset(x: offset.width + gestureOffset.width,
                                    y: offset.height + gestureOffset.height)
                    }
                    .frame(width: apW, height: apH)
                    .clipped()
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white, lineWidth: 2))
                    .gesture(
                        MagnificationGesture()
                            .updating($gestureScale) { v, s, _ in s = v }
                            .onEnded { v in scale = min(6, max(1, scale * v)) }
                            .simultaneously(with: DragGesture()
                                .updating($gestureOffset) { v, s, _ in s = v.translation }
                                .onEnded { v in
                                    offset.width += v.translation.width
                                    offset.height += v.translation.height
                                })
                    )

                    HStack(spacing: 16) {
                        Button("취소", role: .cancel) { onCancel() }
                            .buttonStyle(.bordered).tint(.white)
                        Button("사용") {
                            if let cropped = crop(apertureW: apW, apertureH: apH) {
                                onDone(cropped)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    /// Map the aperture window back into image pixels and return that crop.
    private func crop(apertureW apW: CGFloat, apertureH apH: CGFloat) -> UIImage? {
        guard let cg = image.cgImage else { return image }
        let iw = image.size.width, ih = image.size.height
        guard iw > 0, ih > 0 else { return image }

        let baseFill = max(apW / iw, apH / ih)        // matches scaledToFill
        let eff = baseFill * scale
        guard eff > 0 else { return image }

        let cropW = apW / eff
        let cropH = apH / eff
        var originX = iw / 2 - cropW / 2 - offset.width / eff
        var originY = ih / 2 - cropH / 2 - offset.height / eff
        originX = min(max(0, originX), max(0, iw - cropW))
        originY = min(max(0, originY), max(0, ih - cropH))

        // Points → pixels (cgImage is in pixels; image.size is in points).
        let pxPerPt = CGFloat(cg.width) / iw
        let rect = CGRect(x: originX * pxPerPt, y: originY * pxPerPt,
                          width: cropW * pxPerPt, height: cropH * pxPerPt)
            .integral
        guard let out = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }
}

// MARK: - Floating reference overlay

/// The cropped photo, floating over the staff. It is handled directly, like a
/// picture on a desk: drag it anywhere, pinch it or pull its corner to resize.
/// Pinning it down lets touches fall through, so notes under a see-through
/// photo can be placed on the staff; the bar still moves it.
struct ReferenceOverlay: View {
    @ObservedObject var store: ReferenceStore
    /// Run experimental auto-transcription on the current crop.
    var onTranscribe: () -> Void = {}

    @State private var pos: CGSize = .zero
    @GestureState private var dragPos: CGSize = .zero

    @State private var width: CGFloat = 520        // card width in points
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var pull: CGFloat = 0    // how far the corner has been pulled
    @State private var pinned = false              // when on, the photo ignores touches

    private let top: CGFloat = 64                  // where the card rests, below the top bar

    var body: some View {
        if let img = store.image {
            GeometryReader { geo in
                if store.visible {
                    card(img, in: geo.size)
                } else {
                    showButton
                }
            }
        }
    }

    /// The card can't grow past the screen.
    private func fit(_ w: CGFloat, in size: CGSize) -> CGFloat { max(220, min(w, size.width - 16)) }

    private func card(_ img: UIImage, in size: CGSize) -> some View {
        let liveWidth = fit(width * pinch + 2 * pull, in: size)
        let at = held(CGSize(width: pos.width + dragPos.width, height: pos.height + dragPos.height),
                      width: liveWidth, in: size)
        return VStack(spacing: 0) {
            controlBar
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .opacity(store.opacity)
                .accessibilityLabel("악보 사진")
                .overlay(alignment: .bottomTrailing) { if !pinned { corner(in: size) } }
                .allowsHitTesting(!pinned)         // pinned → taps fall through to the staff
        }
        .frame(width: liveWidth)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .contentShape(Rectangle())
        .gesture(move(width: liveWidth, in: size).simultaneously(with: MagnificationGesture()
            .updating($pinch) { v, s, _ in s = v }
            .onEnded { v in width = fit(width * v, in: size) }))
        .offset(at)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, top)
    }

    /// Keep enough of the card on screen to grab it again.
    private func held(_ p: CGSize, width w: CGFloat, in size: CGSize) -> CGSize {
        let side = max(0, (size.width + w) / 2 - 80)
        return CGSize(width: min(max(p.width, -side), side),
                      height: min(max(p.height, 8 - top), max(8 - top, size.height - top - 52)))
    }

    /// Drag the card. Measured against the screen, not against the card — the
    /// card moves under the finger, and a distance measured on it would shake.
    private func move(width w: CGFloat, in size: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .updating($dragPos) { v, s, _ in s = v.translation }
            .onEnded { v in
                pos = held(CGSize(width: pos.width + v.translation.width,
                                  height: pos.height + v.translation.height), width: w, in: size)
            }
    }

    /// The corner to pull: the card grows and shrinks about its middle, so the
    /// corner stays under the finger.
    private func corner(in size: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption.weight(.bold))
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .padding(6)
            .frame(width: 52, height: 52, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .global)
                .updating($pull) { v, s, _ in s = v.translation.width }
                .onEnded { v in width = fit(width + 2 * v.translation.width, in: size) })
            .accessibilityLabel("크기 조절")
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.subheadline).foregroundColor(.secondary)
                .accessibilityHidden(true)   // 끌 수 있다는 표시
            Image(systemName: "circle.lefthalf.filled").foregroundColor(.secondary)
                .accessibilityHidden(true)
            Slider(value: $store.opacity, in: 0.15...1).frame(width: 84)
                .accessibilityLabel("투명도")
            Spacer(minLength: 4)
            // Pin the photo down so the staff under it takes the touches.
            Button { pinned.toggle() } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundColor(pinned ? .accentColor : .secondary)
            }
            .accessibilityLabel("사진 고정")
            .accessibilityAddTraits(pinned ? .isSelected : [])
            // Experimental: read the photo into notes.
            Button(action: onTranscribe) {
                Label("채보", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.iconOnly)
            }
            Button { store.visible = false } label: {
                Image(systemName: "eye.slash")
            }
            .accessibilityLabel("숨기기")
            Button { store.clear() } label: {
                Image(systemName: "trash").foregroundColor(.red)
            }
            .accessibilityLabel("참고 사진 삭제")
        }
        .font(.body)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var showButton: some View {
        Button { store.visible = true } label: {
            Label("악보 사진", systemImage: "eye")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.black.opacity(0.08), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, top)
    }
}
