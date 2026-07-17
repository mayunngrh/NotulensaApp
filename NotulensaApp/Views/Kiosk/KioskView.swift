import SwiftUI
import AppKit

/// Fullscreen kiosk container: owns the session state machine for a running event.
struct KioskView: View {
    let event: Event
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: PhotoboothStore
    @StateObject private var viewModel: KioskViewModel

    init(event: Event) {
        self.event = event
        _viewModel = StateObject(wrappedValue: KioskViewModel(event: event))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content(viewModel)
        }
        .preferredColorScheme(.dark)
        .task {
            // Start both paths: Canon EVF streams only while a body is connected,
            // and the webcam stays warm as the automatic fallback.
            viewModel.canon.setEvfEnabled(true)
            await viewModel.camera.start()
            setFullscreen(true)
        }
        .onDisappear {
            viewModel.canon.setEvfEnabled(false)
            viewModel.camera.stop()
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
            ResultView(viewModel: vm, result: result) {
                persistResult(vm)
                vm.backToIdle()
            }
        }
    }

    private func persistResult(_ vm: KioskViewModel) {
        guard let relPath = vm.pendingResultPath else { return }
        vm.pendingResultPath = nil
        let photo = CompositedPhoto(filePath: relPath, livePhotoPath: vm.pendingLivePhotoPath, slideshowPath: vm.pendingSlideshowPath)
        photo.rawPhotoPaths = vm.pendingRawPaths
        photo.driveURL = vm.pendingDriveURL
        vm.pendingLivePhotoPath = nil
        vm.pendingSlideshowPath = nil
        vm.pendingRawPaths = []
        event.captures.append(photo)
        store.save()
    }

    private func exitKiosk() {
        viewModel.backToIdle()
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
