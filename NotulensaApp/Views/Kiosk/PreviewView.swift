import SwiftUI
import AppKit

/// Full-screen preview mode: landscape aspect ratio fitted to width,
/// even if height is cut off on a portrait-oriented kiosk display.
struct PreviewView: View {
    @ObservedObject var viewModel: KioskViewModel
    @ObservedObject private var canon = CanonCameraService.shared
    @ObservedObject private var sony = SonyCameraService.shared
    let camera: CameraService

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Landscape preview: fit to width, height overflow is OK
            VStack(spacing: 0) {
                if viewModel.usesCanon {
                    // Canon EVF live preview
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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black)
                        }
                    }
                    .ignoresSafeArea()
                } else if viewModel.usesSony {
                    // Sony live preview
                    Group {
                        if sony.isConnected && sony.evfReady {
                            SonyEvfPreviewView()
                        } else {
                            VStack(spacing: 16) {
                                ProgressView().controlSize(.large).tint(.white)
                                Text(sony.errorMessage ?? "Connecting to Sony camera…")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black)
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    // Webcam preview in landscape aspect ratio
                    CameraPreviewView(session: camera.session)
                        .ignoresSafeArea()
                }
            }

            // Photo counter and close button overlay
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        viewModel.backToWelcome()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if !viewModel.shots.isEmpty {
                        Text("Preview Photos: \(viewModel.shots.count)")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                .padding(16)

                Spacer()
            }
            .background(.black.opacity(0.5))
        }
    }
}
