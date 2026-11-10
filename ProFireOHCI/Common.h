//
//  Common.h
//  Shared helpers: logging, barriers, time, DMA buffers.
//

#ifndef Common_h
#define Common_h

#include <stdint.h>
#include <os/log.h>
#include <time.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IODMACommand.h>
#include <PCIDriverKit/PCIDriverKit.h>

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "ProFireOHCI: " fmt, ##__VA_ARGS__)


// Full-system barrier so DMA descriptors are visible to the device in order.
static inline void ioBarrier()
{
#if defined(__arm64__) || defined(__aarch64__)
    __asm__ volatile("dmb sy" ::: "memory");
#else
    __asm__ volatile("mfence" ::: "memory");
#endif
}

static inline uint64_t nowNs() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// mach_absolute_time units <-> ns
struct HostClock {
    uint32_t numer = 1, denom = 1;
    void init() {
        mach_timebase_info_data_t tb = {};
        mach_timebase_info(&tb);
        if (tb.numer && tb.denom) { numer = tb.numer; denom = tb.denom; }
    }
    uint64_t now() const { return mach_absolute_time(); }
    // ticks = ns * denom / numer
    int64_t nsToTicks(int64_t ns) const { return ns * int64_t(denom) / int64_t(numer); }
};

// A DMA buffer that may consist of several IOVA segments (each page aligned).
struct DmaBuf {
    static constexpr uint32_t kMaxSegs = 64;
    IOBufferMemoryDescriptor *mem  = nullptr;
    IODMACommand             *dma  = nullptr;
    uint8_t                  *cpu  = nullptr;
    uint32_t                  size = 0;
    uint32_t                  nseg = 0;
    uint64_t                  segOff[kMaxSegs] = {};
    uint64_t                  segAddr[kMaxSegs] = {};
    uint64_t                  segLen[kMaxSegs] = {};

    // IOVA of a byte offset (the caller guarantees the object doesn't straddle a segment).
    uint32_t iova(uint32_t off) const {
        for (uint32_t i = 0; i < nseg; i++)
            if (off >= segOff[i] && off < segOff[i] + segLen[i])
                return uint32_t(segAddr[i] + (off - segOff[i]));
        return 0;
    }
    volatile uint32_t *q32(uint32_t off) const { return reinterpret_cast<volatile uint32_t *>(cpu + off); }
};

kern_return_t allocDma(IOService *device, uint32_t size, DmaBuf &b);
void freeDma(DmaBuf &b);

#endif /* Common_h */
