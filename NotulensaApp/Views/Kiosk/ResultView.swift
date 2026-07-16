import SwiftUI
import AppKit
import AVKit

/// Final session outputs — printable photo, GIF, live photo — with share options.
/// Auto-returns to idle after a timeout.
struct ResultView: View {
    @Bindable var viewModel: KioskViewModel
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
        VStack(spacing: 24) {
            Text("Here's Your Photo!")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 30)

            if availableTabs.count > 1 {
                Picker("", selection: $tab) {
                    ForEach(availableTabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }

            preview
                .frame(maxHeight: 480)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 16)

            HStack(spacing: 24) {
                actionButton("Share via AirDrop", icon: "square.and.arrow.up") {
                    ShareService.airDrop(fileURL: activeURL)
                }
                actionButton("Print", icon: "printer.fill") {
                    ShareService.print(fileURL: result.printableURL)
                }
                actionButton("Scan QR", icon: "qrcode") {
                    showQR = true
                }
            }

            Button("Done", action: onDone)
                .controlSize(.large)
                .padding(.bottom, 30)
        }
        .padding(.horizontal, 60)
        .contentShape(Rectangle())
        .onTapGesture { restartIdleTimer() }
        .onAppear { restartIdleTimer() }
        .onDisappear { idleTimer?.cancel() }
        .onChange(of: tab) { setupPlayerIfNeeded() }
        .task { setupPlayerIfNeeded() }
        .sheet(isPresented: $showQR) {
            qrSheet
        }
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
                VideoPlayer(player: player)
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

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            restartIdleTimer()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.title3.bold())
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .tint(.pink)
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
