import SwiftUI
import AppKit

/// Kiosk welcome screen: background photo + Start Photo Session + Gallery buttons,
/// positioned exactly as configured in the event setup wizard.
struct WelcomeView: View {
    @ObservedObject var event: Event
    let viewModel: KioskViewModel
    let onStart: () -> Void
    let onGallery: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            WelcomeScreenLayoutView(event: event, isEditable: false, onStart: onStart, onGallery: onGallery)
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
}
