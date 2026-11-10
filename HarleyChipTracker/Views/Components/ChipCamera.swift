import AVFoundation
import SwiftUI
import UIKit

/// A camera with a round viewfinder, sized for chips. The collector lines the chip up in the
/// circle, and the photo comes back cropped to the square around it.
struct ChipCamera: View {
    var onPick: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera = ChipCameraModel()

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        GeometryReader { proxy in
            let circle = Self.circle(in: proxy.size)
            ZStack {
                Color.black
                CameraPreview(session: camera.session)

                // Dim everything outside the circle.
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .mask {
                        Rectangle()
                            .overlay {
                                Circle()
                                    .frame(width: circle.width, height: circle.height)
                                    .position(x: circle.midX, y: circle.midY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 2)
                    .frame(width: circle.width, height: circle.height)
                    .position(x: circle.midX, y: circle.midY)

                Text(camera.isReady ? "Fit your chip in the circle" : "")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .position(x: proxy.size.width / 2, y: circle.minY - 32)

                controls(size: proxy.size, circle: circle)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .alert("Camera Unavailable", isPresented: $camera.failed) {
            Button("OK") { dismiss() }
        } message: {
            Text("Allow camera access for Chip Chaser in Settings, or choose a photo from your library instead.")
        }
    }

    private func controls(size: CGSize, circle: CGRect) -> some View {
        VStack {
            Spacer()
            ZStack {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.leading, 28)
                    Spacer()
                }
                Button {
                    Task { await capture(viewSize: size, circle: circle) }
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                        Circle().fill(.white).frame(width: 60, height: 60)
                    }
                }
                .disabled(!camera.isReady || camera.isCapturing)
                .opacity(camera.isReady ? 1 : 0.4)
                .accessibilityLabel("Take Photo")
            }
            .padding(.bottom, 48)
        }
    }

    private func capture(viewSize: CGSize, circle: CGRect) async {
        guard let photo = await camera.capture() else { return }
        let cropped = Self.crop(photo, toCircle: circle, inView: viewSize) ?? photo
        dismiss()
        onPick(cropped)
    }

    /// The viewfinder circle: centered a little above the middle, leaving room for the controls.
    static func circle(in size: CGSize) -> CGRect {
        let diameter = max(80, min(size.width - 40, size.height * 0.62))
        let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
        return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }

    /// Crops an upright photo, shown aspect-filled in a view of `viewSize`, to the square around
    /// `circle` (in view points), with a small margin so the rim isn't clipped.
    static func crop(_ image: UIImage, toCircle circle: CGRect, inView viewSize: CGSize) -> UIImage? {
        guard let rect = cropRect(imageSize: CGSize(width: image.size.width * image.scale,
                                                    height: image.size.height * image.scale),
                                  circle: circle, viewSize: viewSize),
              let upright = upright(image), let cropped = upright.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }

    /// The circle's bounding square in image pixels, for an image aspect-filled into the view.
    static func cropRect(imageSize: CGSize, circle: CGRect, viewSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let offset = CGPoint(x: (viewSize.width - imageSize.width * scale) / 2,
                             y: (viewSize.height - imageSize.height * scale) / 2)
        let padded = circle.insetBy(dx: -circle.width * 0.06, dy: -circle.height * 0.06)
        let rect = CGRect(x: (padded.minX - offset.x) / scale, y: (padded.minY - offset.y) / scale,
                          width: padded.width / scale, height: padded.height / scale)
            .integral
            .intersection(CGRect(origin: .zero, size: imageSize))
        return rect.isEmpty ? nil : rect
    }

    private static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }.cgImage
    }
}

/// Runs the capture session off the main thread and hands back photos.
@Observable
final class ChipCameraModel {
    let session = AVCaptureSession()
    var isReady = false
    var isCapturing = false
    var failed = false

    @ObservationIgnored private let output = AVCapturePhotoOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "ChipCamera.session")
    @ObservationIgnored private var delegate: PhotoDelegate?

    func start() async {
        var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard allowed else { failed = true; return }

        let session = session, output = output
        let configured = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            queue.async {
                done.resume(returning: Self.configure(session, output: output))
            }
        }
        guard configured else { failed = true; return }
        isReady = true
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func capture() async -> UIImage? {
        guard isReady, !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // the app is portrait only
        }
        return await withCheckedContinuation { (done: CheckedContinuation<UIImage?, Never>) in
            let delegate = PhotoDelegate { image in
                done.resume(returning: image)
            }
            self.delegate = delegate
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    private nonisolated static func configure(_ session: AVCaptureSession, output: AVCapturePhotoOutput) -> Bool {
        if session.isRunning { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
        session.startRunning()
        return true
    }

    private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
        let finish: (UIImage?) -> Void

        init(finish: @escaping (UIImage?) -> Void) { self.finish = finish }

        nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
            Task { @MainActor in finish(image) }
        }
    }
}

/// The live camera feed, filling its view.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
