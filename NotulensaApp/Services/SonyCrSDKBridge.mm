#import <Foundation/Foundation.h>
#include "CameraRemote_SDK.h"
#include "IDeviceCallback.h"
#include <string>
#include <mutex>
#include <vector>
#include <atomic>
#include <memory>
#include <condition_variable>
#include <chrono>

using namespace SCRSDK;

// MARK: - Device callback

// Connect() only *requests* the connection — the SDK confirms it asynchronously via
// OnConnected (or reports failure via OnError) on its own internal thread. connectCamera()
// blocks on this callback's condition variable until one of those fires, matching the
// wait pattern in Sony's own SDK samples (see getLiveViewAndOSD.cpp).
class SonyDeviceCallback : public IDeviceCallback {
public:
    std::mutex mutex;
    std::condition_variable cv;
    std::atomic<bool> connectedFlag{false};
    std::atomic<bool> connectFailed{false};
    std::atomic<bool> disconnected{false};

    void OnConnected(DeviceConnectionVersioin version) override {
        NSLog(@"[Sony SDK] OnConnected");
        connectedFlag = true;
        cv.notify_all();
    }

    void OnDisconnected(CrInt32u error) override {
        NSLog(@"[Sony SDK] OnDisconnected: 0x%04x", error);
        disconnected = true;
    }

    void OnError(CrInt32u error) override {
        NSLog(@"[Sony SDK] OnError: 0x%04x", error);
        // Only the connect phase waits on the condition variable; an error after that
        // point is surfaced separately (isConnected() / disconnected flag), not here.
        if (!connectedFlag.load()) {
            connectFailed = true;
            cv.notify_all();
        }
    }
};

// MARK: - C++ Wrapper class

class SonyCrSDKWrapper {
public:
    static SonyCrSDKWrapper& instance() {
        static SonyCrSDKWrapper inst;
        return inst;
    }

    bool initialize() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (initialized_) return true;

        bool ret = Init(0);
        if (!ret) {
            NSLog(@"[Sony SDK] Initialize failed");
            return false;
        }

        initialized_ = true;
        NSLog(@"[Sony SDK] Initialized successfully");
        return true;
    }

    void release() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!initialized_) return;

        disconnectCamera();
        Release();
        initialized_ = false;
        NSLog(@"[Sony SDK] Released");
    }

    bool connectCamera() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!initialized_) return false;
        if (connected_) return true;

        // Enumerate cameras with 5 second timeout
        ICrEnumCameraObjectInfo* enumInfo = nullptr;
        CrError ret = EnumCameraObjects(&enumInfo, 5);
        if (ret != CrError_None || !enumInfo) {
            NSLog(@"[Sony SDK] EnumCameraObjects failed: 0x%04x", ret);
            return false;
        }

        // Get first camera
        const ICrCameraObjectInfo* cameraInfo = enumInfo->GetCameraObjectInfo(0);
        if (!cameraInfo) {
            NSLog(@"[Sony SDK] No cameras found");
            enumInfo->Release();
            return false;
        }

        const CrChar* model = cameraInfo->GetModel();
        std::string name = model ? std::string(model) : "Sony camera";

        callback_ = std::make_unique<SonyDeviceCallback>();
        ret = Connect(const_cast<ICrCameraObjectInfo*>(cameraInfo), callback_.get(), &deviceHandle_);
        enumInfo->Release();
        if (ret != CrError_None) {
            NSLog(@"[Sony SDK] Connect failed: 0x%04x", ret);
            callback_.reset();
            return false;
        }

        // Block until the async handshake actually finishes (OnConnected/OnError) —
        // Connect() returning CrError_None only means the request was accepted.
        {
            std::unique_lock<std::mutex> cbLock(callback_->mutex);
            callback_->cv.wait_for(cbLock, std::chrono::seconds(8), [&] {
                return callback_->connectedFlag.load() || callback_->connectFailed.load();
            });
        }

        if (!callback_->connectedFlag.load()) {
            NSLog(@"[Sony SDK] Connect handshake did not complete in time");
            Disconnect(deviceHandle_);
            ReleaseDevice(deviceHandle_);
            deviceHandle_ = 0;
            callback_.reset();
            return false;
        }

        cameraName_ = name;
        connected_ = true;

        NSLog(@"[Sony SDK] Camera connected: %s", cameraName_.c_str());
        return true;
    }

    void disconnectCamera() {
        if (!connected_) return;

        stopLiveView();
        if (deviceHandle_ != 0) {
            Disconnect(deviceHandle_);
            ReleaseDevice(deviceHandle_);
            deviceHandle_ = 0;
        }
        callback_.reset();
        connected_ = false;
        cameraName_.clear();
        NSLog(@"[Sony SDK] Camera disconnected");
    }

    bool startLiveView() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!connected_) return false;

        evfActive_ = true;
        NSLog(@"[Sony SDK] Live view started");
        return true;
    }

    void stopLiveView() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!evfActive_) return;

        evfActive_ = false;
        NSLog(@"[Sony SDK] Live view stopped");
    }

    bool getLiveViewImage(std::vector<uint8_t>& outJpeg) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!connected_ || !evfActive_ || deviceHandle_ == 0) return false;
        if (callback_ && callback_->disconnected.load()) return false;

        // Sony's sample always sizes the buffer from GetLiveViewImageInfo() right before
        // reading a frame rather than guessing a fixed size — GetLiveViewImage rejects
        // an under/mismatched buffer.
        CrImageInfo info;
        CrError infoRet = GetLiveViewImageInfo(deviceHandle_, &info);
        if (infoRet != CrError_None) {
            if (!loggedInfoFailure_) {
                loggedInfoFailure_ = true;
                NSLog(@"[Sony SDK] GetLiveViewImageInfo failed: 0x%04x", infoRet);
            }
            return false;
        }
        CrInt32u bufSize = info.GetBufferSize();
        if (bufSize == 0) return false;
        if (liveViewBuffer_.size() < bufSize) {
            liveViewBuffer_.resize(bufSize);
        }

        CrImageDataBlock block;
        block.SetSize(static_cast<CrInt32u>(liveViewBuffer_.size()));
        block.SetData(liveViewBuffer_.data());

        CrError ret = GetLiveViewImage(deviceHandle_, &block);
        if (ret != CrError_None) {
            if (!loggedImageFailure_) {
                loggedImageFailure_ = true;
                NSLog(@"[Sony SDK] GetLiveViewImage failed: 0x%04x", ret);
            }
            return false;
        }

        CrInt32u imageSize = block.GetImageSize();
        if (imageSize == 0) return false;

        if (!loggedFirstFrame_) {
            loggedFirstFrame_ = true;
            NSLog(@"[Sony SDK] First live view frame received: %u bytes", imageSize);
        }

        outJpeg.assign(liveViewBuffer_.begin(), liveViewBuffer_.begin() + imageSize);
        return true;
    }

    bool captureImage() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!connected_ || deviceHandle_ == 0) return false;

        // Simulates a full shutter press: press then release. The resulting JPEG
        // still needs to be pulled via the contents-transfer API — not implemented yet.
        CrError ret = SendCommand(deviceHandle_, CrCommandId_Release, CrCommandParam_Down);
        if (ret != CrError_None) {
            NSLog(@"[Sony SDK] Shutter press failed: 0x%04x", ret);
            return false;
        }
        SendCommand(deviceHandle_, CrCommandId_Release, CrCommandParam_Up);
        return true;
    }

    bool isConnected() const {
        return connected_ && !(callback_ && callback_->disconnected.load());
    }

    std::string getConnectedCameraName() const {
        return cameraName_;
    }

private:
    SonyCrSDKWrapper() = default;
    ~SonyCrSDKWrapper() {
        release();
    }

    bool initialized_ = false;
    bool connected_ = false;
    bool evfActive_ = false;
    CrDeviceHandle deviceHandle_ = 0;
    std::string cameraName_;
    std::unique_ptr<SonyDeviceCallback> callback_;
    std::vector<uint8_t> liveViewBuffer_;
    bool loggedFirstFrame_ = false;
    bool loggedInfoFailure_ = false;
    bool loggedImageFailure_ = false;
    mutable std::mutex mutex_;
};

// MARK: - C interface for Swift

extern "C" {

    bool SonyCrSDK_Initialize(void) {
        return SonyCrSDKWrapper::instance().initialize();
    }

    void SonyCrSDK_Release(void) {
        SonyCrSDKWrapper::instance().release();
    }

    int SonyCrSDK_EnumerateCameras(const char** outNames, int maxCount) {
        return 0; // TODO: Implement when needed
    }

    bool SonyCrSDK_ConnectCamera(int index) {
        return SonyCrSDKWrapper::instance().connectCamera();
    }

    void SonyCrSDK_DisconnectCamera(void) {
        SonyCrSDKWrapper::instance().disconnectCamera();
    }

    bool SonyCrSDK_StartLiveView(void) {
        return SonyCrSDKWrapper::instance().startLiveView();
    }

    void SonyCrSDK_StopLiveView(void) {
        SonyCrSDKWrapper::instance().stopLiveView();
    }

    bool SonyCrSDK_IsConnected(void) {
        return SonyCrSDKWrapper::instance().isConnected();
    }

    const char* SonyCrSDK_GetCameraName(void) {
        static thread_local std::string name;
        name = SonyCrSDKWrapper::instance().getConnectedCameraName();
        return name.c_str();
    }

    bool SonyCrSDK_CaptureImage(uint8_t** outJpegData, int* outSize) {
        if (!SonyCrSDKWrapper::instance().captureImage()) {
            return false;
        }
        // TODO: Implement image retrieval via contents-transfer API
        return true;
    }

    bool SonyCrSDK_GetLiveViewImage(uint8_t** outJpegData, int* outSize) {
        std::vector<uint8_t> jpeg;
        if (!SonyCrSDKWrapper::instance().getLiveViewImage(jpeg)) {
            return false;
        }
        *outSize = static_cast<int>(jpeg.size());
        *outJpegData = new uint8_t[jpeg.size()];
        std::copy(jpeg.begin(), jpeg.end(), *outJpegData);
        return true;
    }

    void SonyCrSDK_FreeMemory(uint8_t* ptr) {
        delete[] ptr;
    }
}
