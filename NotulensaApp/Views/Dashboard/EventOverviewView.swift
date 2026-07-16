import SwiftUI
import AppKit

/// Read-only overview shown on the right side of the dashboard: event summary,
/// welcome screen preview, templates, and capture settings at a glance.
/// Editing happens in the Edit Event sheet; launching goes straight to kiosk mode.
struct EventOverviewView: View {
    let event: Event
    let onEdit: () -> Void
    let onLaunch: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                section("Welcome Screen") {
                    WelcomeScreenLayoutView(event: event, isEditable: false, onStart: nil, onGallery: nil)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                        .overlay(alignment: .bottomLeading) {
                            if event.idleMediaPath == nil {
                                Text("No idle media set")
                                    .font(.caption)
                                    .padding(6)
                                    .background(.orange.opacity(0.8), in: Capsule())
                                    .padding(10)
                            }
                        }
                }

                section("Templates (\(event.templates.count))") {
                    if event.templates.isEmpty {
                        Text("No templates yet — add at least one in Edit Event.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 16) {
                            ForEach(event.templates) { template in
                                VStack(spacing: 6) {
                                    if let image = NSImage(contentsOf: MediaStore.url(for: template.frameImagePath)) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(height: 140)
                                            .background(.black)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    Text(template.name).font(.caption.bold())
                                    Text("\(template.shotCount) shot(s)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                section("Capture Settings") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow {
                            settingItem("Countdown (1st photo)", "\(event.countdownFirst)s", icon: "timer")
                            settingItem("Countdown (others)", "\(event.countdownOthers)s", icon: "timer")
                        }
                        GridRow {
                            settingItem("Review each photo", "\(event.reviewSeconds)s", icon: "eye")
                            settingItem("Live photo loops", "\(event.livePhotoLoops)×", icon: "livephoto")
                        }
                        GridRow {
                            settingItem("GIF width", "\(event.gifWidth)px", icon: "photo.stack")
                            settingItem("GIF frame time", event.gifFrameSeconds.formatted(.number.precision(.fractionLength(1))) + "s", icon: "clock")
                        }
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 16) {
                Button {
                    onEdit()
                } label: {
                    Label("Edit Event", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {
                    onLaunch()
                } label: {
                    Label("Launch Event", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.pink)
                .disabled(!event.canStart)
            }
            .padding()
            .background(.bar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.name)
                .font(.largeTitle.bold())
            Text("Created \(event.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(event.captures.count) session(s) so far")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !event.canStart {
                Label("Needs at least one template before it can launch", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func settingItem(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.pink)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.bold())
            }
        }
        .frame(minWidth: 180, alignment: .leading)
    }
}
