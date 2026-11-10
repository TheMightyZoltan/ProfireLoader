//
//  FWController.h
//  OHCI 1394 link controller: bring-up, bus resets, async transactions.
//

#ifndef FWController_h
#define FWController_h

#include "Common.h"

class FWController {
public:
    kern_return_t start(IOPCIDevice *pci);
    void stop();

    uint32_t rd(uint32_t off) const;
    void     wr(uint32_t off, uint32_t v) const;
    bool     present() const { return rd(0) != 0xFFFFFFFF; }

    // Housekeeping poll. Returns true when a new bus generation was processed.
    bool pollBusReset();
    bool resetPending() const;

    // Topology after the last bus reset.
    uint32_t generation = 0xFFFFFFFF;
    uint16_t localNode  = 0xFFFF;
    bool     isRoot     = false;
    int      irmPhy     = -1;
    int      nRemote    = 0;
    uint8_t  remotePhy[63] = {};

    // Async transactions (thread safe, synchronous).
    bool readQuadlet(uint16_t node, uint16_t hi, uint32_t lo, uint32_t *v);
    bool writeQuadlet(uint16_t node, uint16_t hi, uint32_t lo, uint32_t v);
    bool compareSwap32(uint16_t node, uint16_t hi, uint32_t lo, uint32_t arg, uint32_t data, uint32_t *old);
    bool compareSwap64(uint16_t node, uint16_t hi, uint32_t lo, uint64_t arg, uint64_t data, uint64_t *old);

    // Config ROM summary of a remote node.
    struct RomInfo { uint32_t guidHi = 0, guidLo = 0, vendor = 0, model = 0; char vendorName[32] = {}, modelName[32] = {}; };
    bool readRomInfo(uint16_t node, RomInfo &info);

    // Physical (DMA-direct) requests from a node into our mapped buffers.
    void allowPhysicalFrom(int phy);
    void forceBusReset();

    // A quadlet in mapped memory that remote nodes can write to (DICE notifications).
    uint32_t notifyIova() const;
    uint32_t takeNotify();           // returns and clears the last notification bits

    // Isochronous support
    uint32_t cycleTimer() const;
    int      numIT = 0, numIR = 0;
    IOPCIDevice *pci = nullptr;

private:
    uint8_t  bar = 0;
    IOLock  *lock = nullptr;
    DmaBuf   misc;
    DmaBuf   arBuf;
    uint32_t arReadPos = 0;
    uint8_t  tlabel = 0;
    bool     resetSeen = false;
    uint32_t physMaskLo = 0, physMaskHi = 0;
    uint32_t notifyAccum = 0;

    bool     phyRead(uint8_t addr, uint8_t *val);
    bool     phyWrite(uint8_t addr, uint8_t val);
    void     buildConfigROM();
    bool     stopContext(uint32_t base);
    void     armARResponse();
    uint32_t arBytesWritten();
    int      arFindResponse(uint16_t src, uint8_t tl, uint32_t *tcode, uint32_t *rcode, uint8_t *data, uint32_t *dataLen);
    uint32_t atSend(const uint32_t hdr[4], uint32_t hdrLen, const uint8_t *payload, uint32_t plen);
    bool     transact(uint16_t node, const uint32_t hdrIn[4], uint32_t hdrLen, const uint8_t *payload, uint32_t plen,
                      uint32_t expectTcode, uint8_t *resp, uint32_t *respLen, const char *what, uint32_t lo);
    void     handleSelfIDs();
};

#endif /* FWController_h */
