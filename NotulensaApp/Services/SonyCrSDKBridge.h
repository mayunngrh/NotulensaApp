#ifndef SONY_CRSDK_BRIDGE_H
#define SONY_CRSDK_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

// MARK: - C interface for Swift (no C++ types)

#ifdef __cplusplus
extern "C" {
#endif

bool SonyCrSDK_Initialize(void);
void SonyCrSDK_Release(void);
int SonyCrSDK_EnumerateCameras(const char** outNames, int maxCount);
bool SonyCrSDK_ConnectCamera(int index);
void SonyCrSDK_DisconnectCamera(void);
bool SonyCrSDK_StartLiveView(void);
void SonyCrSDK_StopLiveView(void);
bool SonyCrSDK_IsConnected(void);
const char* SonyCrSDK_GetCameraName(void);
bool SonyCrSDK_CaptureImage(uint8_t** outJpegData, int* outSize);
bool SonyCrSDK_GetLiveViewImage(uint8_t** outJpegData, int* outSize);
void SonyCrSDK_FreeMemory(uint8_t* ptr);

#ifdef __cplusplus
}
#endif

#endif
