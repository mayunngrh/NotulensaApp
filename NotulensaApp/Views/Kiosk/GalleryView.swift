import SwiftUI
import AppKit

/// Grid of every photo captured during this event, reachable from the welcome screen.
struct GalleryView: View {
    let event: Event
    let onBack: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 20)]

    var body: some View {
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
                Color.clear.frame(width: 80)
            }
            .foregroundStyle(.white)
            .padding(24)

            if event.captures.isEmpty {
                Spacer()
                Text("No photos yet — take one!")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(event.captures.sorted { $0.takenAt > $1.takenAt }) { capture in
                            if let image = NSImage(contentsOf: MediaStore.url(for: capture.filePath)) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .shadow(radius: 6)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}
