import SwiftUI
import AppKit
import AVKit

/// Grid of every photo captured during this event, reachable from the welcome screen.
/// Tapping a photo opens it in a result-style detail view (Photo / Slideshow / Live Photo).
struct GalleryView: View {
    let event: Event
    let onBack: () -> Void

    @State private var selected: CompositedPhoto?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 20)]

    private var sortedCaptures: [CompositedPhoto] {
        event.captures.sorted { $0.takenAt > $1.takenAt }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Spacer()
                    Text("Gallery")
                        .font(.title.bold())
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                if event.captures.isEmpty {
                    Spacer()
                    Text("No photos yet — take one!")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(sortedCaptures) { capture in
                                if let image = NSImage(contentsOf: MediaStore.url(for: capture.filePath)) {
                                    Button {
                                        selected = capture
                                    } label: {
                                        Image(nsImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                            .shadow(radius: 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(16)
                    }
                    // Expand the scroll area to fill all remaining height below the header.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Fill the whole screen and pin content to the top (default frame alignment is
            // center, which is what pushed the header into the vertical middle).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black.ignoresSafeArea())

            // Detail overlay (macOS has no fullScreenCover, so overlay manually).
            if let capture = selected {
                GalleryDetailView(capture: capture) { selected = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selected?.id)
    }
}

/// Result-style viewer for a single saved session, opened from the gallery.
/// Self-contained (no live KioskViewModel) — uses the capture's own stored paths.
private struct GalleryDetailView: View {
    @ObservedObject var capture: CompositedPhoto
    let onClose: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case printable = "Photo"
        case slideshow = "Slideshow"
        case live = "Live Photo"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .printable
    @State private var showQR = false
    @State private var player: AVPlayer?

    private var slideshowURL: URL? {
        capture.slideshowPath.map { MediaStore.url(for: $0) }
    }
    private var livePhotoURL: URL? {
        capture.livePhotoPath.map { MediaStore.url(for: $0) }
    }
    private var printableURL: URL {
        MediaStore.url(for: capture.filePath)
    }

    private var availableTabs: [Tab] {
        var tabs: [Tab] = [.printable]
        if slideshowURL != nil { tabs.append(.slideshow) }
        if livePhotoURL != nil { tabs.append(.live) }
        return tabs
    }

    private var activeURL: URL {
        switch tab {
        case .printable: printableURL
        case .slideshow: slideshowURL ?? printableURL
        case .live: livePhotoURL ?? printableURL
        }
    }

    private var activeVideoURL: URL? {
        switch tab {
        case .printable: nil
        case .slideshow: slideshowURL
        case .live: livePhotoURL
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Text("Your Photo")
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
                            ShareService.print(fileURL: printableURL)
                        }
                        if capture.driveURL != nil {
                            iconButton(icon: "qrcode", size: 34) {
                                showQR = true
                            }
                        }
                    }
                    .padding(.trailing, 24)
                }

                HStack {
                    Button(action: onClose) {
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
        .onChange(of: tab) { _ in setupPlayerIfNeeded() }
        .task { setupPlayerIfNeeded() }
        .sheet(isPresented: $showQR) {
            qrSheet
        }
    }

    private func iconButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
            if let image = NSImage(contentsOf: printableURL) {
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
        guard let url = activeVideoURL else {
            player = nil
            return
        }
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

            if let urlString = capture.driveURL, let link = URL(string: urlString),
               let qr = QRService.qrImage(for: link) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 280, height: 280)
                Label("All photos, slideshow, and live photo are in the folder.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
                    .frame(width: 280, height: 160)
                Text("This session has no Drive link.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Close") { showQR = false }
                .controlSize(.large)
        }
        .padding(40)
        .frame(minWidth: 420)
    }
}
