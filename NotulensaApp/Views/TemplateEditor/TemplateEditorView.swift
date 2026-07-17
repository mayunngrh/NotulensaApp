import SwiftUI
import Combine
import AppKit

struct TemplateEditorView: View {
    @ObservedObject var template: PhotoTemplate
    @EnvironmentObject private var store: PhotoboothStore
    @State private var selectedSlot: PhotoSlot?
    @State private var selectedLayerID: AnyHashable?

    var body: some View {
        HSplitView {
            SlotEditorCanvas(
                template: template,
                selectedSlot: $selectedSlot,
                frameSelected: selectedLayerID == AnyHashable("frame")
            )
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            inspector
                .frame(width: 280)
        }
        .navigationTitle(template.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addSlot()
                } label: {
                    Label("Add Slot", systemImage: "plus.square.dashed")
                }
            }
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Form {
                Section("Template") {
                    TextField("Name", text: $template.name)
                    LabeledContent("Canvas", value: "4R portrait — \(Int(template.canvasWidth)) × \(Int(template.canvasHeight)) px")
                    LabeledContent("Shots needed", value: "\(template.shotCount)")
                }
                Section("Placement foto") {
                    Button {
                        addSlot()
                    } label: {
                        Label("+ Placement foto", systemImage: "plus.square.dashed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    if let slot = selectedSlot {
                        HStack {
                            Button {
                                copySlot(slot)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(role: .destructive) {
                                deleteSlot(slot)
                            } label: {
                                Label("Hapus", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            // A template must keep at least one photo slot.
                            .disabled(template.slots.count <= 1)
                        }
                    }
                }
                if let slot = selectedSlot {
                    SlotInspectorSections(slot: slot, slotCount: template.slots.count) {
                        normalizeOrders()
                    }
                } else {
                    Section {
                        Text("Add a placement, then drag it over a cutout of your frame PNG. Drag to move, corner handle to resize.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            layersPanel
        }
    }

    // MARK: Layers panel (Photoshop-style, drag to reorder)

    private enum LayerEntry: Identifiable {
        case frame
        case slot(PhotoSlot)

        var id: AnyHashable {
            switch self {
            case .frame: AnyHashable("frame")
            case .slot(let slot): AnyHashable(slot.id)
            }
        }
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Layers")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            List(selection: $selectedLayerID) {
                ForEach(layerEntries) { entry in
                    layerRow(entry)
                        .tag(entry.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                }
                .onMove(perform: moveLayers)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: selectedLayerID) { _ in
                if selectedLayerID == AnyHashable("frame") {
                    selectedSlot = nil
                } else if let slot = template.slots.first(where: { AnyHashable($0.id) == selectedLayerID }) {
                    selectedSlot = slot
                }
            }
            .onChange(of: selectedSlot) { _ in
                if let slot = selectedSlot {
                    selectedLayerID = AnyHashable(slot.id)
                }
            }
            Text("Drag rows to reorder — the top row is drawn in front.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .frame(minHeight: 230)
    }

    @ViewBuilder
    private func layerRow(_ entry: LayerEntry) -> some View {
        switch entry {
        case .frame:
            layerCard(title: "Frame PNG", icon: "photo", tint: .gray, selected: false)
        case .slot(let slot):
            layerCard(
                title: "Photo \(slot.order)",
                icon: "line.3.horizontal",
                tint: slot === selectedSlot ? .pink : .yellow,
                selected: slot === selectedSlot
            )
        }
    }

    /// Front-most first; on a layer tie the slot is treated as in front of the frame.
    private var layerEntries: [LayerEntry] {
        var items: [(layer: Int, entry: LayerEntry)] = template.slots.map { ($0.layer, .slot($0)) }
        items.append((template.frameLayer, .frame))
        return items.sorted { a, b in
            if a.layer != b.layer { return a.layer > b.layer }
            if case .frame = b.entry { return true }
            return false
        }.map(\.entry)
    }

    private func moveLayers(from source: IndexSet, to destination: Int) {
        var rows = layerEntries
        rows.move(fromOffsets: source, toOffset: destination)
        for (index, entry) in rows.enumerated() {
            let layer = rows.count - 1 - index
            switch entry {
            case .frame: template.frameLayer = layer
            case .slot(let slot): slot.layer = layer
            }
        }
        template.objectWillChange.send()
        store.save()
    }

    private func layerCard(title: String, icon: String, tint: Color, selected: Bool) -> some View {
        HStack {
            Text(title)
                .fontWeight(.semibold)
            Spacer()
            Image(systemName: icon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(selected ? 0.55 : 0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }

    // MARK: Slot actions

    private func copySlot(_ source: PhotoSlot) {
        let copy = PhotoSlot(
            order: source.order,
            x: min(source.x + 40, template.canvasWidth - source.width),
            y: min(source.y + 40, template.canvasHeight - source.height),
            width: source.width,
            height: source.height,
            rotation: source.rotation,
            layer: source.layer
        )
        template.slots.append(copy)
        selectedSlot = copy
        store.save()
    }

    private func deleteSlot(_ slot: PhotoSlot) {
        selectedSlot = nil
        template.slots.removeAll { $0 === slot }
        normalizeOrders()
        store.save()
    }

    /// Keeps photo numbers consecutive (1, 2, 3…): deleting Photo 2 turns Photo 3 into Photo 2.
    private func normalizeOrders() {
        let ranks = Set(template.slots.map(\.order)).sorted()
        for slot in template.slots {
            slot.order = (ranks.firstIndex(of: slot.order) ?? 0) + 1
        }
        template.objectWillChange.send()
    }

    private func addSlot() {
        let nextOrder = (template.slots.map(\.order).max() ?? 0) + 1
        let slot = PhotoSlot(
            order: nextOrder,
            x: template.canvasWidth * 0.25,
            y: template.canvasHeight * 0.25,
            width: template.canvasWidth * 0.5,
            height: template.canvasHeight * 0.3,
            layer: template.slots.count
        )
        template.slots.append(slot)
        selectedSlot = slot
        store.save()
    }
}

/// Numeric inspector for the selected slot; observes the slot so edits reflect live.
private struct SlotInspectorSections: View {
    @ObservedObject var slot: PhotoSlot
    let slotCount: Int
    let onOrderChange: () -> Void

    var body: some View {
        Section("Posisi") {
            HStack {
                numberField("X", value: $slot.x, range: -10000...10000)
                numberField("Y", value: $slot.y, range: -10000...10000)
            }
        }
        Section("Ukuran") {
            HStack {
                numberField("Lebar", value: $slot.width, range: 20...20000)
                numberField("Tinggi", value: $slot.height, range: 20...20000)
            }
        }
        Section("Kemiringan") {
            HStack {
                numberField("Derajat", value: $slot.rotation, range: -180...180)
                Slider(value: $slot.rotation, in: -45...45, step: 1)
            }
        }
        Section("Foto") {
            Stepper("Photo # \(slot.order)", value: $slot.order, in: 1...max(1, slotCount))
                .onChange(of: slot.order) { _ in onOrderChange() }
        }
    }

    private func numberField(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        TextField(label, value: Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        ), format: .number.precision(.fractionLength(0)))
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 60)
    }
}
