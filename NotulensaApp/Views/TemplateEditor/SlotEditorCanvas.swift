import SwiftUI
import AppKit

/// Editing surface: black 4R canvas, frame PNG at its own rect/layer, photo slots as
/// draggable/resizable overlays. Each slot is its own observed subview so mutations
/// (drag/resize) refresh immediately without SwiftData/Observation (Ventura-compatible).
struct SlotEditorCanvas: View {
    @ObservedObject var template: PhotoTemplate
    @Binding var selectedSlot: PhotoSlot?
    var frameSelected: Bool = false

    @State private var frameDragStart: CGPoint?

    static let space = "slot-editor-canvas"

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / template.canvasWidth,
                            geo.size.height / template.canvasHeight)
            let canvasSize = CGSize(width: template.canvasWidth * scale,
                                    height: template.canvasHeight * scale)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: canvasSize.width, height: canvasSize.height)

                ForEach(template.sortedSlots.filter { $0.layer < template.frameLayer }) { slot in
                    SlotBoxView(slot: slot, template: template, scale: scale, selectedSlot: $selectedSlot)
                }

                frameImage(scale: scale)

                ForEach(template.sortedSlots.filter { $0.layer >= template.frameLayer }) { slot in
                    SlotBoxView(slot: slot, template: template, scale: scale, selectedSlot: $selectedSlot)
                }
            }
            .coordinateSpace(name: Self.space)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Frame PNG

    @ViewBuilder
    private func frameImage(scale: CGFloat) -> some View {
        if let image = NSImage(contentsOf: MediaStore.url(for: template.frameImagePath)) {
            let rect = template.frameRect(imageSize: image.size)
            Image(nsImage: image)
                .resizable()
                .frame(width: rect.width * scale, height: rect.height * scale)
                .overlay {
                    if frameSelected {
                        Rectangle().strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    }
                }
                .offset(x: rect.minX * scale, y: rect.minY * scale)
                .allowsHitTesting(frameSelected)
                .gesture(frameMoveGesture(rect: rect, scale: scale))
        }
    }

    private func frameMoveGesture(rect: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard frameSelected else { return }
                if frameDragStart == nil {
                    frameDragStart = rect.origin
                    template.frameWidth = rect.width
                    template.frameHeight = rect.height
                }
                guard let start = frameDragStart else { return }
                template.frameX = start.x + value.translation.width / scale
                template.frameY = start.y + value.translation.height / scale
            }
            .onEnded { _ in frameDragStart = nil }
    }
}

/// One photo slot: observes its own slot so drag/resize redraw instantly.
private struct SlotBoxView: View {
    @ObservedObject var slot: PhotoSlot
    let template: PhotoTemplate
    let scale: CGFloat
    @Binding var selectedSlot: PhotoSlot?

    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?

    private var isSelected: Bool { slot === selectedSlot }

    var body: some View {
        let w = slot.width * scale
        let h = slot.height * scale

        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.blue.opacity(0.2))
                .overlay(
                    Rectangle().strokeBorder(isSelected ? Color.accentColor : .blue, lineWidth: 2)
                )
                .overlay(
                    Text("\(slot.order)")
                        .font(.system(size: max(14, min(w, h) * 0.3), weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                )
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 22, height: 22)
                    .offset(x: 11, y: 11)
                    .gesture(resizeGesture)
            }
        }
        .frame(width: w, height: h)
        .rotationEffect(.degrees(slot.rotation))
        .offset(x: slot.x * scale, y: slot.y * scale)
        .onTapGesture { selectedSlot = slot }
        .gesture(moveGesture)
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named(SlotEditorCanvas.space))
            .onChanged { value in
                selectedSlot = slot
                if dragStart == nil { dragStart = CGPoint(x: slot.x, y: slot.y) }
                guard let start = dragStart else { return }
                slot.x = min(max(start.x + value.translation.width / scale, -slot.width * 0.9),
                             template.canvasWidth - slot.width * 0.1)
                slot.y = min(max(start.y + value.translation.height / scale, -slot.height * 0.9),
                             template.canvasHeight - slot.height * 0.1)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(coordinateSpace: .named(SlotEditorCanvas.space))
            .onChanged { value in
                if resizeStart == nil { resizeStart = CGSize(width: slot.width, height: slot.height) }
                guard let start = resizeStart else { return }
                let angle = -slot.rotation * .pi / 180
                let dx = (value.translation.width * cos(angle) - value.translation.height * sin(angle)) / scale
                let dy = (value.translation.width * sin(angle) + value.translation.height * cos(angle)) / scale
                slot.width = max(50, start.width + dx)
                slot.height = max(50, start.height + dy)
            }
            .onEnded { _ in resizeStart = nil }
    }
}
