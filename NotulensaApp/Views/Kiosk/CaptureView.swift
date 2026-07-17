import SwiftUI
import AppKit

/// Live preview + countdown per shot; after each shot: Retake or Next.
struct CaptureView: View {
    @ObservedObject var viewModel: KioskViewModel
    /// Observed so the Canon live-view state (evfReady / errorMessage) refreshes the preview.
    @ObservedObject private var canon = CanonCameraService.shared

    var body: some View {
        // The camera preview stays mounted the whole time capturing is active — swapping it
        // in and out (e.g. for each review screen) recreates its NSView/CALayer and causes
        // a visible fade-in every shot, which was also degrading the live photo look.
        ZStack {
            liveView
            if let review = viewModel.reviewShot, let image = NSImage(data: review) {
                reviewView(image)
            }
        }
        .overlay(alignment: .top) {
            if let template = viewModel.template {
                Text("Photo \(viewModel.currentOrder) of \(template.shotCount)")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 30)
            }
        }
        .alert("Something went wrong", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("Try Again") {
                viewModel.errorMessage = nil
                viewModel.beginCountdown()
            }
            Button("Cancel", role: .cancel) {
                viewModel.errorMessage = nil
                viewModel.backToIdle()
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var liveView: some View {
        ZStack {
            if viewModel.usesCanon {
                // Canon EVF frames go straight into a CALayer — no SwiftUI re-render per frame.
                Group {
                    if canon.isConnected && canon.evfReady {
                        CanonEvfPreviewView()
                    } else {
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.large).tint(.white)
                            Text(canon.errorMessage ?? "Connecting to Canon camera…")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            } else {
                CameraPreviewView(session: viewModel.camera.session)
                    .ignoresSafeArea()
            }
            if let countdown = viewModel.countdown {
                Text("\(countdown)")
                    .font(.system(size: 220, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(radius: 20)
                    .transition(.scale.combined(with: .opacity))
                    .id(countdown)
            }
        }
        .animation(.spring(duration: 0.3), value: viewModel.countdown)
    }

    private func reviewView(_ image: NSImage) -> some View {
        VStack(spacing: 30) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 12)
                .padding(.top, 90)

            HStack(spacing: 30) {
                Button {
                    viewModel.retake()
                } label: {
                    Label("Retake", systemImage: "arrow.counterclockwise")
                        .font(.title2.bold())
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    viewModel.next()
                } label: {
                    Label(viewModel.isLastShot ? "Finish" : "Next", systemImage: viewModel.isLastShot ? "checkmark" : "arrow.right")
                        .font(.title2.bold())
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.pink)
            }
            .padding(.bottom, 50)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.8))
        .ignoresSafeArea()
    }
}
