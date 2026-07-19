import SwiftUI
import AppKit
import AVKit

/// Final session outputs — printable photo, GIF, live photo — with share options.
/// Auto-returns to idle after a timeout.
struct ResultView: View {
    @ObservedObject var viewModel: KioskViewModel
    let result: SessionResult
    let onDone: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case printable = "Photo"
        case slideshow = "Slideshow"
        case live = "Live Photo"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .printable
    @State private var showQR = false
    @State private var idleTimer: Task<Void, Never>?
    @State private var player: AVPlayer?

    private let idleTimeout: Duration = .seconds(60)

    private var availableTabs: [Tab] {
        var tabs: [Tab] = [.printable]
        if result.slideshowURL != nil { tabs.append(.slideshow) }
        if result.livePhotoURL != nil { tabs.append(.live) }
        return tabs
    }

    private var activeURL: URL {
        switch tab {
        case .printable: result.printableURL
        case .slideshow: result.slideshowURL ?? result.printableURL
        case .live: result.livePhotoURL ?? result.printableURL
        }
    }

    /// Video URL for the currently selected tab, if it's a video tab.
    private var activeVideoURL: URL? {
        switch tab {
        case .printable: nil
        case .slideshow: result.slideshowURL
        case .live: result.livePhotoURL
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar with title and tab picker
                VStack(spacing: 12) {
                    Text("Here's Your Photo!")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)

                    if availableTabs.count > 1 {
                        Picker("", selection: $tab) {
                            ForEach(availableTabs) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 320)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 16)

                // Main content: large photo with icon overlay
                ZStack(alignment: .trailing) {
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(20)

                    // Middle-right vertical action stack.
                    VStack(spacing: 24) {
                        iconButton(icon: "square.and.arrow.up", size: 34) {
                            ShareService.airDrop(fileURL: activeURL)
                        }
                        iconButton(icon: "printer.fill", size: 34) {
                            ShareService.print(fileURL: result.printableURL)
                        }
                        iconButton(icon: "qrcode", size: 34) {
                            showQR = true
                        }
                    }
                    .padding(.trailing, 24)
                }

                // Bottom bar with Done button
                HStack {
                    Button(action: onDone) {
                        Text("Done")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 100)
                            .frame(height: 44)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { restartIdleTimer() }
        .onAppear { restartIdleTimer() }
        .onDisappear { idleTimer?.cancel() }
        .onChange(of: tab) { _ in setupPlayerIfNeeded() }
        .task { setupPlayerIfNeeded() }
        .sheet(isPresented: $showQR) {
            qrSheet
        }
    }

    private func iconButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: {
            restartIdleTimer()
            action()
        }) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Color.pink.opacity(0.8))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preview: some View {
        switch tab {
        case .printable:
            if let image = NSImage(contentsOf: activeURL) {
                Image(nsImage: image).resizable().scaledToFit()
            }
        case .slideshow, .live:
            if let player {
                StablePlayerView(player: player, controlsStyle: .inline)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
            }
        }
    }

    private func setupPlayerIfNeeded() {
        guard let url = activeVideoURL else { return }
        let item = AVPlayerItem(url: url)
        let p = AVQueuePlayer()
        p.isMuted = true
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            p.seek(to: .zero)
            p.play()
        }
        p.replaceCurrentItem(with: item)
        player = p
        p.play()
    }


    private var qrSheet: some View {
        VStack(spacing: 20) {
            Text("Scan to Download")
                .font(.title.bold())

            // The session folder (and its public link) is created when the session starts,
            // so the QR is always ready here — files stream in behind it.
            if let link = viewModel.driveLink {
                if let qr = QRService.qrImage(for: link) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 280, height: 280)
                }
                switch viewModel.uploadState {
                case .done:
                    Label("All photos, slideshow, and live photo are in the folder.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                case .failed(let message):
                    Text("Some files failed to upload: \(message)")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.orange)
                    Button {
                        viewModel.retryUpload()
                    } label: {
                        Label("Retry Upload", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                default:
                    Label("Files are uploading — they'll appear in the folder shortly.", systemImage: "arrow.up.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if case .notSignedIn = viewModel.uploadState {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
                    .frame(width: 280, height: 160)
                Text("Google Drive is not connected. Sign in from the Dashboard (Google Drive settings) to enable QR sharing.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = viewModel.uploadState {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 80))
                    .foregroundStyle(.orange)
                    .frame(width: 280, height: 160)
                Text("Could not reach Google Drive: \(message)")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    viewModel.retryUpload()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                ProgressView()
                    .frame(width: 280, height: 280)
            }

            Button("Close") { showQR = false }
                .controlSize(.large)
        }
        .padding(40)
        .frame(minWidth: 420)
    }

    private func restartIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task {
            try? await Task.sleep(for: idleTimeout)
            if !Task.isCancelled { onDone() }
        }
    }
}
