// pfctl: send a developer command to the ProFire driver.
//   pfctl restart | tone | stop | dump | levels | notone | "delay N" | "tone N" | "rate N"
// Commands travel as IOServiceOpen() types: 0xFE000000 | cmd << 16 | arg.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: pfctl restart|tone|stop|dump|levels|notone|delay N|tone N|rate N\n"); return 2; }
    const char *w = argv[1];
    unsigned arg = argc > 2 ? (unsigned)atoi(argv[2]) : 0;
    char c = 0;
    if (!strcmp(w, "restart")) c = 'R';
    else if (!strcmp(w, "stop")) c = 'S';
    else if (!strcmp(w, "dump")) c = 'D';
    else if (!strcmp(w, "levels")) c = 'L';
    else if (!strcmp(w, "notone")) c = 'N';
    else if (!strcmp(w, "delay")) c = 'Y';
    else if (!strcmp(w, "tone")) c = argc > 2 ? 'O' : 'T';
    else if (!strcmp(w, "rate")) { c = 'A'; arg /= 10; }
    else { fprintf(stderr, "unknown command %s\n", w); return 2; }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("ProFireOHCI"));
    if (!svc) { fprintf(stderr, "ProFireOHCI service not found\n"); return 1; }
    io_connect_t conn = 0;
    uint32_t type = 0xFE000000u | ((uint32_t)(unsigned char)c << 16) | (arg & 0xFFFF);
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
    if (conn) IOServiceClose(conn);
    IOObjectRelease(svc);
    // 0xe00002eb (aborted) = handled; restart may also report a dead connection.
    printf("sent %s %u -> 0x%x%s\n", w, arg, kr, kr == (kern_return_t)0xe00002eb ? " (ok)" : "");
    return 0;
}
