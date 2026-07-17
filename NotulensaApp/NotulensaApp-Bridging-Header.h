//
// Bridging header: exposes Canon EDSDK and Sony CrSDK C APIs to Swift.
//
// Canon EDSDK:
// Headers live in Vendor/EDSDKHeaders (see HEADER_SEARCH_PATHS).
// EDSDK's headers switch on __MACOS__ (defined by Canon's sample projects in
// build settings) — without it the basic Eds* typedefs never get defined.
#ifndef __MACOS__
#define __MACOS__ 1
#endif
#include <stdbool.h>

#import "EDSDK.h"
#import "EDSDKTypes.h"
#import "EDSDKErrors.h"

// Sony CrSDK Bridge:
// C interface to the Objective-C++ wrapper around the Sony Camera Remote SDK
#import "SonyCrSDKBridge.h"
