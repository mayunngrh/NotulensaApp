import SwiftUI
import AppKit

struct TemplatePickerView: View {
    let event: Event
    let onPick: (PhotoTemplate) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            Text("Choose Your Layout")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)

            HStack(spacing: 40) {
                ForEach(event.templates) { template in
                    Button {
                        onPick(template)
                    } label: {
                        VStack(spacing: 12) {
                            if let image = NSImage(contentsOf: MediaStore.url(for: template.frameImagePath)) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 420)
                                    .background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Text(template.name)
                                .font(.title2.bold())
                            Text("\(template.shotCount) photos")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Back", action: onCancel)
                .controlSize(.large)
        }
        .padding(40)
    }
}
