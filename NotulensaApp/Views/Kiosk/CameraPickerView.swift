import SwiftUI

struct CameraPickerView: View {
    @ObservedObject var viewModel: KioskViewModel
    let onSelectCanon: () -> Void
    let onSelectWebcam: () -> Void
    let onCancel: () -> Void

    private var canon: CanonCameraService { viewModel.canon }
    private var webcam: CameraService { viewModel.camera }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                VStack(spacing: 8) {
                    Text("Select Camera")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Choose which camera to use for this session")
                        .font(.system(size: 18))
                        .foregroundStyle(.gray)
                }
                .padding(.top, 60)

                VStack(spacing: 20) {
                    if let canonName = canon.cameraName {
                        Button(action: onSelectCanon) {
                            VStack(spacing: 12) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.green)
                                Text(canonName)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("Connected")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.green)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.green.opacity(0.5), lineWidth: 2)
                            )
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.gray)
                            Text("Canon Camera")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.gray)
                            Text("Not connected")
                                .font(.system(size: 14))
                                .foregroundStyle(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(16)
                        .opacity(0.5)
                    }

                    Button(action: onSelectWebcam) {
                        VStack(spacing: 12) {
                            Image(systemName: "macbook.and.iphone")
                                .font(.system(size: 40))
                                .foregroundStyle(.blue)
                            Text("Webcam")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Built-in")
                                .font(.system(size: 14))
                                .foregroundStyle(.blue)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.blue.opacity(0.5), lineWidth: 2)
                        )
                    }
                }
                .padding(.horizontal, 40)

                Spacer()

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
    }
}
