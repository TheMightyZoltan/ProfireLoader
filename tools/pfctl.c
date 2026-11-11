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
    unsigned arg = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 0) : 0;
    char c = 0;
    if (!strcmp(w, "restart")) c = 'R';
    else if (!strcmp(w, "stop")) c = 'S';
    else if (!strcmp(w, "dump")) c = 'D';
    else if (!strcmp(w, "levels")) c = 'L';
    else if (!strcmp(w, "notone")) c = 'N';
    else if (!strcmp(w, "delay")) c = 'Y';
    else if (!strcmp(w, "tone")) c = argc > 2 ? 'O' : 'T';
    else if (!strcmp(w, "rate")) { c = 'A'; arg /= 10; }
    else if (!strcmp(w, "itrestart")) c = 'I';
    else if (!strcmp(w, "itdiag")) c = 'Q';
    else if (!strcmp(w, "forceroot")) c = 'F';
    else if (!strcmp(w, "unforceroot")) c = 'K';
    else if (!strcmp(w, "raw")) c = 'W';
    else if (!strcmp(w, "zts")) c = 'J';
    else if (!strcmp(w, "busreset")) c = 'G';
    else if (!strcmp(w, "reenable")) c = 'E';
    else if (!strcmp(w, "noout")) c = 'Z';
    else if (!strcmp(w, "router")) c = 'U';
    else if (!strcmp(w, "loadrouter")) c = 'H';
    else if (!strcmp(w, "peekb")) c = 'B';     // DICE base space, arg = quadlet index
    else if (!strcmp(w, "peekx")) c = 'X';     // EAP space, arg = quadlet index
    else if (!strcmp(w, "itcm")) c = 'M';
    else { fprintf(stderr, "unknown command %s\n", w); return 2; }
    // Every driver instance (one per FireWire controller) gets the command.
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("ProFireOHCI"), &it) != KERN_SUCCESS) it = 0;
    int sent = 0;
    for (io_service_t svc; it && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
        uint64_t id = 0; IORegistryEntryGetRegistryEntryID(svc, &id);
        io_connect_t conn = 0;
        uint32_t type = 0xFE000000u | ((uint32_t)(unsigned char)c << 16) | (arg & 0xFFFF);
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
        if (conn) IOServiceClose(conn);
        // 0xe00002eb (aborted) = handled; restart may also report a dead connection.
        printf("sent %s %u to 0x%llx -> 0x%x%s\n", w, arg, id, kr, kr == (kern_return_t)0xe00002eb ? " (ok)" : "");
        sent++;
    }
    if (it) IOObjectRelease(it);
    if (!sent) { fprintf(stderr, "ProFireOHCI service not found\n"); return 1; }
    return 0;
}
