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

// MARK: - Camera

/// Thin wrapper over UIImagePickerController for the camera. (PHPicker can't
/// take a live photo, so the camera path still needs the older controller.)
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.dismiss()
            if let image { parent.onImage(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
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

/// The cropped photo, floating over the staff. The image itself ignores
/// touches so notes underneath stay tappable; only the control bar (move
/// handle, opacity, hide, delete) is interactive.
struct ReferenceOverlay: View {
    @ObservedObject var store: ReferenceStore

    @State private var pos: CGSize = .zero
    @GestureState private var dragPos: CGSize = .zero

    var body: some View {
        if let img = store.image {
            if store.visible {
                card(img)
            } else {
                showButton
            }
        }
    }

    private func card(_ img: UIImage) -> some View {
        VStack(spacing: 0) {
            // Interactive control bar. Only the grip moves the card, so it
            // doesn't fight the opacity slider for drags.
            HStack(spacing: 14) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.subheadline).foregroundColor(.secondary)
                    .frame(width: 40, height: 30)
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
                Slider(value: $store.opacity, in: 0.15...1).frame(width: 130)
                Spacer(minLength: 4)
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

            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .opacity(store.opacity)
                .allowsHitTesting(false)   // taps fall through to the staff
        }
        .frame(maxWidth: 560)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .offset(x: pos.width + dragPos.width, y: pos.height + dragPos.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 64)
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
