import SwiftUI
import AppKit
import AVFoundation

/// Live preview + countdown per shot; after each shot: Retake or Next.
/// When in preview mode, shows landscape-oriented live feed with no review screens.
struct CaptureView: View {
    @ObservedObject var viewModel: KioskViewModel
    /// Observed so the Canon live-view state (evfReady / errorMessage) refreshes the preview.
    @ObservedObject private var canon = CanonCameraService.shared
    /// Observed so the Sony live-view state (evfReady / errorMessage) refreshes the preview.
    @ObservedObject private var sony = SonyCameraService.shared

    var body: some View {
        normalCaptureView
    }

    private var normalCaptureView: some View {
        // The camera preview stays mounted the whole time capturing is active — swapping it
        // in and out (e.g. for each review screen) recreates its NSView/CALayer and causes
        // a visible fade-in every shot, which was also degrading the live photo look.
        ZStack {
            liveView
        }
        .overlay(alignment: .topLeading) {
            // Back button to exit capture
            if viewModel.countdown != nil {
                Button {
                    viewModel.backToWelcome()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(20)
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
        .overlay(alignment: .bottom) {
            // Compact photo strip at bottom, centered
            if !viewModel.shots.isEmpty, viewModel.reviewShot == nil {
                let sortedPhotos = Array(viewModel.shots.keys).sorted()

                VStack(spacing: 12) {
                    Text("Photos Taken: \(viewModel.shots.count)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)

                    HStack(spacing: 12) {
                        ForEach(sortedPhotos.prefix(4), id: \.self) { order in
                            if let data = viewModel.shots[order],
                               let image = NSImage(data: data) {
                                VStack(spacing: 6) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 100, height: 133)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(
                                                    order == viewModel.currentOrder - 1 ? Color.cyan : Color.gray,
                                                    lineWidth: 2
                                                )
                                        }
                                    Text("Photo \(order)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.reviewShot != nil, !viewModel.shots.isEmpty {
                VStack(spacing: 12) {
                    Text("Photos Taken: \(viewModel.shots.count)")
                        .font(.headline)
                        .foregroundStyle(.white)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(viewModel.shots.keys).sorted(), id: \.self) { order in
                                if let data = viewModel.shots[order],
                                   let image = NSImage(data: data) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 60, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(
                                                    order == viewModel.currentOrder ? Color.yellow : Color.gray,
                                                    lineWidth: 2
                                                )
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(height: 100)
                }
                .padding(.vertical, 16)
                .background(.black.opacity(0.6))
                .padding(.bottom, 40)
            }
        }
        // Review screen overlay — rendered on top of all other overlays so buttons are always tappable
        .overlay {
            if let review = viewModel.reviewShot, let image = NSImage(data: review) {
                reviewView(image)
                    .zIndex(100)
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
            Color.black.ignoresSafeArea()

            // During countdown, show the last taken photo so people can see themselves —
            // BUT NOT in preview mode: show live feed the whole time so they can verify
            // the camera preview keeps working throughout the entire session.
            if !viewModel.isInPreviewMode,
               let countdown = viewModel.countdown,
               let lastPhoto = viewModel.shots[viewModel.currentOrder - 1],
               let image = NSImage(data: lastPhoto) {
                // Last shot preview during countdown
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Live camera feed
                Group {
                    if viewModel.usesCanon {
                        if canon.isConnected && canon.evfReady {
                            CanonEvfPreviewView(contentsGravity: .resizeAspect)
                        } else {
                            connectingPlaceholder(canon.errorMessage ?? "Connecting to Canon camera…")
                        }
                    } else if viewModel.usesSony {
                        if sony.isConnected && sony.evfReady {
                            SonyEvfPreviewView(contentsGravity: .resizeAspect)
                        } else {
                            connectingPlaceholder(sony.errorMessage ?? "Connecting to Sony camera…")
                        }
                    } else {
                        CameraPreviewView(session: viewModel.camera.session, videoGravity: .resizeAspect)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }

            // Countdown overlay
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

    private func connectingPlaceholder(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(.white)
            Text(message)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
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
