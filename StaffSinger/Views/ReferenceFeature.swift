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
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> ApertureCameraController {
        let vc = ApertureCameraController()
        vc.aspect = aspect
        vc.onCapture = onCapture
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ vc: ApertureCameraController, context: Context) {}
}

final class ApertureCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    var aspect: CGFloat = 3.0
    var onCapture: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var preview: AVCaptureVideoPreviewLayer?
    private let dim = CAShapeLayer()
    private let frameLine = CAShapeLayer()
    private let staffGuide = CAShapeLayer()   // faint 5-line guide inside the window
    private var apertureRect: CGRect = .zero

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
        frameLine.fillColor = UIColor.clear.cgColor
        frameLine.strokeColor = UIColor.white.cgColor
        frameLine.lineWidth = 2
        view.layer.addSublayer(frameLine)

        staffGuide.fillColor = UIColor.clear.cgColor
        staffGuide.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        staffGuide.lineWidth = 1
        view.layer.addSublayer(staffGuide)

        let hint = UILabel()
        hint.text = "이 칸에 두 마디를 맞추고 촬영하세요"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 15, weight: .semibold)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.tag = 99
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
    }

    private func setupControls() {
        let shutter = UIButton(type: .system)
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 33
        shutter.layer.borderColor = UIColor.white.cgColor
        shutter.layer.borderWidth = 4
        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.addTarget(self, action: #selector(shoot), for: .touchUpInside)
        view.addSubview(shutter)

        let cancel = UIButton(type: .system)
        cancel.setTitle("취소", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
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
        label.text = "카메라를 사용할 수 없습니다.\n사진 보관함에서 선택해 주세요."
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        let close = UIButton(type: .system)
        close.setTitle("닫기", for: .normal)
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
        preview?.connection?.videoOrientation = currentVideoOrientation()

        // Centered wide aperture.
        let margin: CGFloat = 90
        let w = min(view.bounds.width - margin * 2, 900)
        let h = w / aspect
        apertureRect = CGRect(x: view.bounds.midX - w / 2,
                              y: view.bounds.midY - h / 2, width: w, height: h)

        let path = UIBezierPath(rect: view.bounds)
        path.append(UIBezierPath(roundedRect: apertureRect, cornerRadius: 6))
        dim.path = path.cgPath
        frameLine.path = UIBezierPath(roundedRect: apertureRect, cornerRadius: 6).cgPath

        // Faint 5-line staff in the middle of the window so the user lines the
        // real staff up with where the app's staff sits.
        let staffH = h * 0.5
        let gap = staffH / 4
        let startY = apertureRect.midY - staffH / 2
        let guide = UIBezierPath()
        for i in 0..<5 {
            let y = startY + CGFloat(i) * gap
            guide.move(to: CGPoint(x: apertureRect.minX + 12, y: y))
            guide.addLine(to: CGPoint(x: apertureRect.maxX - 12, y: y))
        }
        staffGuide.path = guide.cgPath
    }

    // MARK: Capture

    @objc private func cancelTapped() { onCancel?() }

    @objc private func shoot() {
        guard session.isRunning else { return }
        output.connection(with: .video)?.videoOrientation = currentVideoOrientation()
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

    private func currentVideoOrientation() -> AVCaptureVideoOrientation {
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
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

/// The cropped photo, floating over the staff. By default the image ignores
/// touches so notes underneath stay tappable, and the grip in the control bar
/// moves the card. Tapping the "이동/크기" toggle hands the whole photo over to
/// touch: drag it anywhere and pinch to resize, freely, until you toggle back.
struct ReferenceOverlay: View {
    @ObservedObject var store: ReferenceStore
    /// Run experimental auto-transcription on the current crop.
    var onTranscribe: () -> Void = {}

    @State private var pos: CGSize = .zero
    @GestureState private var dragPos: CGSize = .zero

    @State private var width: CGFloat = 520        // card width in points; pinch resizes it
    @GestureState private var pinch: CGFloat = 1
    @State private var editing = false             // when on, the whole photo is draggable & resizable

    var body: some View {
        if let img = store.image {
            GeometryReader { geo in
                if store.visible {
                    card(img, available: geo.size.width)
                } else {
                    showButton
                }
            }
        }
    }

    private func card(_ img: UIImage, available: CGFloat) -> some View {
        // Keep the card within the screen so a big pinch can't push it off-edge.
        let liveWidth = max(220, min(width * pinch, available - 16))
        return VStack(spacing: 0) {
            controlBar
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .opacity(store.opacity)
                .overlay {
                    if editing {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor.opacity(0.9),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    }
                }
                .allowsHitTesting(editing)         // off → taps fall through to the staff
                .gesture(moveResize(available: available))
        }
        .frame(width: liveWidth)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .offset(x: pos.width + dragPos.width, y: pos.height + dragPos.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 64)
    }

    /// Interactive control bar. The grip always moves the card; the pencil-hand
    /// toggle frees the whole photo for free drag + pinch-to-resize.
    private var controlBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.subheadline).foregroundColor(.secondary)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($dragPos) { v, s, _ in s = v.translation }
                        .onEnded { v in
                            pos.width += v.translation.width
                            pos.height += v.translation.height
                        }
                )
            Image(systemName: "circle.lefthalf.filled").foregroundColor(.secondary)
            Slider(value: $store.opacity, in: 0.15...1).frame(width: 84)
            Spacer(minLength: 4)
            // Free move/resize: hand the whole photo over to touch.
            Button { editing.toggle() } label: {
                Image(systemName: editing ? "hand.draw.fill" : "hand.draw")
                    .foregroundColor(editing ? .accentColor : .secondary)
            }
            // Experimental: read the photo into notes.
            Button(action: onTranscribe) {
                Label("채보", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.iconOnly)
            }
            Button { store.visible = false } label: {
                Image(systemName: "eye.slash")
            }
            Button { store.clear() } label: {
                Image(systemName: "trash").foregroundColor(.red)
            }
        }
        .font(.body)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// Drag the whole photo anywhere, pinch to resize. Only fires in edit mode
    /// (otherwise the image isn't hit-testable and taps reach the staff).
    private func moveResize(available: CGFloat) -> some Gesture {
        DragGesture()
            .updating($dragPos) { v, s, _ in s = v.translation }
            .onEnded { v in
                pos.width += v.translation.width
                pos.height += v.translation.height
            }
            .simultaneously(with: MagnificationGesture()
                .updating($pinch) { v, s, _ in s = v }
                .onEnded { v in width = max(220, min(width * v, available - 16)) })
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
        .padding(.top, 64)
    }
}
