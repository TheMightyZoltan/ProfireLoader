//
//  Common.cpp
//

#include "Common.h"

kern_return_t allocDma(IOService *device, uint32_t size, DmaBuf &b)
{
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, size, 16384, &b.mem);
    if (ret != kIOReturnSuccess) { LOG("buffer create failed 0x%x", ret); return ret; }
    b.mem->SetLength(size);

    IOAddressSegment range = {};
    ret = b.mem->GetAddressRange(&range);
    if (ret != kIOReturnSuccess) { LOG("GetAddressRange failed 0x%x", ret); return ret; }
    b.cpu = reinterpret_cast<uint8_t *>(range.address);
    bzero(b.cpu, size);

    IODMACommandSpecification spec = {};
    spec.options        = kIODMACommandSpecificationNoOptions;
    spec.maxAddressBits = 32;   // OHCI is a 32-bit bus master
    ret = IODMACommand::Create(device, kIODMACommandCreateNoOptions, &spec, &b.dma);
    if (ret != kIOReturnSuccess) { LOG("IODMACommand create failed 0x%x", ret); return ret; }

    uint64_t flags = 0;
    uint32_t segCount = DmaBuf::kMaxSegs;
    IOAddressSegment segs[DmaBuf::kMaxSegs] = {};
    ret = b.dma->PrepareForDMA(kIODMACommandPrepareForDMANoOptions, b.mem, 0, size, &flags, &segCount, segs);
    if (ret != kIOReturnSuccess) { LOG("PrepareForDMA(%u) failed 0x%x", size, ret); return ret; }

    uint64_t off = 0;
    for (uint32_t i = 0; i < segCount; i++) {
        if (segs[i].address + segs[i].length > 0x100000000ull) {
            LOG("DMA segment above 4 GiB (0x%llx)", segs[i].address);
            return kIOReturnNoResources;
        }
        b.segOff[i] = off; b.segAddr[i] = segs[i].address; b.segLen[i] = segs[i].length;
        off += segs[i].length;
    }
    b.nseg = segCount;
    b.size = size;
    if (off < size) { LOG("DMA mapping short: %llu of %u", off, size); return kIOReturnNoResources; }
    return kIOReturnSuccess;
}

void freeDma(DmaBuf &b)
{
    if (b.dma) { b.dma->CompleteDMA(kIODMACommandCompleteDMANoOptions); OSSafeReleaseNULL(b.dma); }
    OSSafeReleaseNULL(b.mem);
    b.cpu = nullptr; b.size = 0; b.nseg = 0;
}
