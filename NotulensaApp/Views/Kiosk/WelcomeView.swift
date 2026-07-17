import SwiftUI
import AppKit
import AVFoundation

/// Kiosk welcome screen: background photo + Start Photo Session + Gallery buttons,
/// positioned exactly as configured in the event setup wizard.
struct WelcomeView: View {
    @ObservedObject var event: Event
    let viewModel: KioskViewModel
    let onStart: () -> Void
    let onGallery: () -> Void
    let onPreview: () -> Void
    let onClose: () -> Void

    var body: some View {
        if event.enablePreview {
            previewModeWelcome
        } else {
            normalWelcome
        }
    }

    private var normalWelcome: some View {
        ZStack {
            WelcomeScreenLayoutView(event: event, isEditable: false, onStart: onStart, onGallery: onGallery, onPreview: event.enablePreview ? onPreview : nil)
                .ignoresSafeArea()

            if !viewModel.shots.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            onClose()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text("Photos Taken: \(viewModel.shots.count)")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .padding(16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(viewModel.shots.keys).sorted(), id: \.self) { order in
                                if let data = viewModel.shots[order],
                                   let image = NSImage(data: data) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8)
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
                    .frame(height: 120)

                    Spacer()
                }
                .background(.black.opacity(0.5))
            }
        }
    }

    private var previewModeWelcome: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                Spacer()

                HStack {
                    Spacer()

                    // Landscape camera preview (16:9 aspect ratio, centered).
                    ZStack {
                        if viewModel.canon.isConnected && viewModel.canon.evfReady {
                            CanonEvfPreviewView(contentsGravity: .resizeAspect)
                        } else if viewModel.sony.isConnected && viewModel.sony.evfReady {
                            SonyEvfPreviewView(contentsGravity: .resizeAspect)
                        } else if viewModel.canon.isConnected {
                            previewPlaceholder(viewModel.canon.errorMessage ?? "Connecting to Canon camera…")
                        } else if viewModel.sony.isConnected {
                            previewPlaceholder(viewModel.sony.errorMessage ?? "Connecting to Sony camera…")
                        } else {
                            CameraPreviewView(session: viewModel.camera.session, videoGravity: .resizeAspect)
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.3), lineWidth: 1))

                    Spacer()
                }
                .padding(.horizontal, 40)

                Spacer()

                // Buttons centered: Take Photo + Gallery
                HStack(spacing: 30) {
                    Button(action: onGallery) {
                        Label("Gallery", systemImage: "photo.stack.fill")
                            .font(.title2.bold())
                            .padding(.horizontal, 30)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.indigo)

                    Button(action: onPreview) {
                        Label("Take Photo", systemImage: "camera.fill")
                            .font(.title2.bold())
                            .padding(.horizontal, 30)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.pink)
                }

                Spacer()

                VStack(spacing: 8) {
                    Text("Preview Mode Enabled")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Tap to start a live preview session")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(.vertical, 16)
            }
        }
    }

    private func previewPlaceholder(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(.white)
            Text(message)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}
