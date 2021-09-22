#import "WindowControl.h"

CFArrayRef TXTWindowListCreate(CGWindowListOption option, CGWindowID relativeToWindow) {
    return CGWindowListCreate(option, relativeToWindow);
}

OSStatus TXTGetProcessForPID(pid_t pid, ProcessSerialNumber *psn) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return GetProcessForPID(pid, psn);
#pragma clang diagnostic pop
}
