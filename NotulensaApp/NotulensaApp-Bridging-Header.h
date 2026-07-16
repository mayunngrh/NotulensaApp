//
// Bridging header: exposes the Canon EDSDK C API to Swift.
// Headers live in Vendor/EDSDKHeaders (see HEADER_SEARCH_PATHS).
//
// EDSDK's headers switch on __MACOS__ (defined by Canon's sample projects in
// build settings) — without it the basic Eds* typedefs never get defined.
#ifndef __MACOS__
#define __MACOS__ 1
#endif
#include <stdbool.h>

#import "EDSDK.h"
#import "EDSDKTypes.h"
#import "EDSDKErrors.h"
