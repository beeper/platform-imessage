#ifndef WindowControl_h
#define WindowControl_h

#include "CGSInternal.h"
#include <CoreGraphics/CoreGraphics.h>

// CGWindowListCreate is unavailable in Swift for some reason
CFArrayRef TXTWindowListCreate(CGWindowListOption option, CGWindowID relativeToWindow);
OSStatus TXTGetProcessForPID(pid_t pid, ProcessSerialNumber *psn);

#endif /* WindowList_h */
