import SwiftUI
import AVKit
import AppKit

/// Attract screen: looping idle video (or photo). Tap anywhere to continue to the welcome screen.
struct IdleView: View {
    let event: Event
    let onContinue: () -> Void
    let onExit: () -> Void

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ZStack {
            idleMedia
                .ignoresSafeArea()

            VStack(alignment: .leading) {
                Button {
                    onExit()
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(20)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onContinue)
        .onAppear(perform: setupVideo)
        .onDisappear {
            player?.pause()
            player = nil
            looper = nil
        }
        .overlay(alignment: .topTrailing) {
            // Hidden exit: double-click the top-right corner.
            Color.clear
                .frame(width: 80, height: 80)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onExit)
        }
    }

    @ViewBuilder
    private var idleMedia: some View {
        if let path = event.idleMediaPath {
            let url = MediaStore.url(for: path)
            if event.idleMediaIsVideo {
                if let player {
                    VideoPlayer(player: player)
                        .disabled(true)
                        .scaledToFill()
                } else {
                    Color.black
                }
            } else if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        } else {
            Color.black
        }
    }

    private func setupVideo() {
        guard event.idleMediaIsVideo, let path = event.idleMediaPath else { return }
        let item = AVPlayerItem(url: MediaStore.url(for: path))
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        queue.play()
    }
}
