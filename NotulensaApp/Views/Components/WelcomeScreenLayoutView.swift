import SwiftUI
import AppKit

/// Shared rendering of the welcome screen: background photo + Start Photo Session button
/// + Gallery button, positioned by relative (0...1) coordinates stored on the event.
/// Used both live in the kiosk and, in editable mode, in the event setup wizard.
struct WelcomeScreenLayoutView: View {
    @Bindable var event: Event
    var isEditable: Bool = false
    var onStart: (() -> Void)?
    var onGallery: (() -> Void)?

    @State private var dragStartStart: CGPoint?
    @State private var dragStartGallery: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                button(
                    title: "Start Photo Session",
                    systemImage: "camera.fill",
                    tint: .pink,
                    relX: event.startButtonRelX, relY: event.startButtonRelY,
                    geo: geo, action: onStart,
                    drag: dragGesture(relX: Binding(
                        get: { event.startButtonRelX }, set: { event.startButtonRelX = $0 }
                    ), relY: Binding(
                        get: { event.startButtonRelY }, set: { event.startButtonRelY = $0 }
                    ), geo: geo, start: $dragStartStart)
                )

                button(
                    title: "Gallery",
                    systemImage: "photo.stack.fill",
                    tint: .indigo,
                    relX: event.galleryButtonRelX, relY: event.galleryButtonRelY,
                    geo: geo, action: onGallery,
                    drag: dragGesture(relX: Binding(
                        get: { event.galleryButtonRelX }, set: { event.galleryButtonRelX = $0 }
                    ), relY: Binding(
                        get: { event.galleryButtonRelY }, set: { event.galleryButtonRelY = $0 }
                    ), geo: geo, start: $dragStartGallery)
                )
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let path = event.welcomeBackgroundPath, let image = NSImage(contentsOf: MediaStore.url(for: path)) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [.black, .indigo.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func button(title: String, systemImage: String, tint: Color, relX: Double, relY: Double, geo: GeometryProxy, action: (() -> Void)?, drag: some Gesture) -> some View {
        Group {
            if isEditable {
                Label(title, systemImage: systemImage)
                    .font(.title3.bold())
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(tint, in: Capsule())
                    .foregroundStyle(.white)
                    .overlay(Capsule().strokeBorder(.white, lineWidth: 2))
            } else {
                Button(action: { action?() }) {
                    Label(title, systemImage: systemImage)
                        .font(.title3.bold())
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .tint(tint)
            }
        }
        .position(x: relX * geo.size.width, y: relY * geo.size.height)
        .gesture(drag, isEnabled: isEditable)
    }

    private func dragGesture(relX: Binding<Double>, relY: Binding<Double>, geo: GeometryProxy, start: Binding<CGPoint?>) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard isEditable else { return }
                if start.wrappedValue == nil {
                    start.wrappedValue = CGPoint(x: relX.wrappedValue, y: relY.wrappedValue)
                }
                guard let origin = start.wrappedValue else { return }
                relX.wrappedValue = min(max(origin.x + value.translation.width / geo.size.width, 0.05), 0.95)
                relY.wrappedValue = min(max(origin.y + value.translation.height / geo.size.height, 0.05), 0.95)
            }
            .onEnded { _ in start.wrappedValue = nil }
    }
}
