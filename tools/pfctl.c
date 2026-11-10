// pfctl: send a developer command to the ProFire driver.
//   pfctl restart | tone | stop | dump | levels
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: pfctl restart|tone|stop|dump|levels\n"); return 2; }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("ProFireOHCI"));
    if (!svc) { fprintf(stderr, "ProFireOHCI service not found\n"); return 1; }
    CFStringRef cmd = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    kern_return_t kr = IORegistryEntrySetCFProperty(svc, CFSTR("ProFireCommand"), cmd);
    CFRelease(cmd);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS && !(kr == kIOReturnNotResponding || kr == MACH_SEND_INVALID_DEST)) {
        fprintf(stderr, "command failed: 0x%x\n", kr);
        return 1;
    }
    printf("sent \"%s\" (0x%x)\n", argv[1], kr);
    return 0;
}
