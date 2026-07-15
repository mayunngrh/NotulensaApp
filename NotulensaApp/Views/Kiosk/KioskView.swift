import SwiftUI
import SwiftData
import AppKit

/// Fullscreen kiosk container: owns the session state machine for a running event.
struct KioskView: View {
    let event: Event
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @State private var viewModel: KioskViewModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let vm = viewModel {
                content(vm)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            let vm = KioskViewModel(event: event)
            viewModel = vm
            await vm.camera.start()
            setFullscreen(true)
        }
        .onDisappear {
            viewModel?.camera.stop()
        }
        .onExitCommand {
            exitKiosk()
        }
    }

    @ViewBuilder
    private func content(_ vm: KioskViewModel) -> some View {
        switch vm.state {
        case .idle:
            IdleView(event: event) {
                vm.showWelcome()
            } onExit: {
                exitKiosk()
            }
        case .welcome:
            WelcomeView(event: event) {
                vm.startSession()
            } onGallery: {
                vm.showGallery()
            }
            .overlay(alignment: .topTrailing) {
                Color.clear
                    .frame(width: 80, height: 80)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: exitKiosk)
            }
        case .gallery:
            GalleryView(event: event) {
                vm.showWelcome()
            }
        case .pickTemplate:
            TemplatePickerView(event: event) { template in
                vm.pick(template)
            } onCancel: {
                vm.backToWelcome()
            }
        case .capturing:
            CaptureView(viewModel: vm)
        case .processing:
            ProcessingView(message: vm.processingMessage)
        case .result(let result):
            ResultView(result: result) {
                persistResult(vm)
                vm.backToIdle()
            }
        }
    }

    private func persistResult(_ vm: KioskViewModel) {
        guard let relPath = vm.pendingResultPath else { return }
        vm.pendingResultPath = nil
        let photo = CompositedPhoto(filePath: relPath, gifPath: vm.pendingGifPath, livePhotoPath: vm.pendingLivePhotoPath)
        vm.pendingGifPath = nil
        vm.pendingLivePhotoPath = nil
        photo.event = event
        context.insert(photo)
        try? context.save()
    }

    private func exitKiosk() {
        viewModel?.backToIdle()
        setFullscreen(false)
        router.runningEvent = nil
    }

    private func setFullscreen(_ on: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let isFullscreen = window.styleMask.contains(.fullScreen)
        if on != isFullscreen {
            window.toggleFullScreen(nil)
        }
    }
}
