//
//  ProFireOHCI.cpp
//  Stage 1: OHCI bring-up + config ROM discovery, no audio yet.
//
//  What it does:
//   1. Opens the PCI device (LSI FW643), enables bus mastering, maps BAR0.
//   2. Soft-resets the OHCI link, powers it up, installs a minimal local config
//      ROM, a self-ID buffer and one AT-request + one AR-response DMA context.
//   3. Forces a bus reset, parses the self-ID packets to find the other nodes.
//   4. Reads each remote node's config ROM with quadlet read requests and logs
//      the bus info block, GUID, vendor/model and text descriptors.
//
//  Everything is polled from a 20 ms timer; no interrupts are used yet.
//  Watch the output with:
//      log stream --level debug --predicate 'eventMessage CONTAINS "ProFireOHCI"'
//

#include <os/log.h>
#include <mach/mach_time.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IODMACommand.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/OSAction.h>
#include <PCIDriverKit/PCIDriverKit.h>

#include "ProFireOHCI.h"
#include "OHCI.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "ProFireOHCI: " fmt, ##__VA_ARGS__)

using namespace ohci;

// ---------------------------------------------------------------------------
// Layout of the single 16 KiB "misc" DMA buffer (all alignments satisfied
// because the buffer itself is page aligned):
//   0x0000  local config ROM image (1 KiB, must be 1 KiB aligned)
//   0x0800  self-ID buffer         (2 KiB, must be 2 KiB aligned)
//   0x1000  AT request descriptor  (OUTPUT_LAST_Immediate, 32 bytes)
//   0x1040  AR response descriptor (INPUT_MORE, 16 bytes)
// A second 16 KiB buffer receives AR response packets in buffer-fill mode.
// ---------------------------------------------------------------------------
static constexpr uint32_t kMiscSize       = 16384;
static constexpr uint32_t kOffConfigROM   = 0x0000;
static constexpr uint32_t kOffSelfID      = 0x0800;
static constexpr uint32_t kSelfIDBytes    = 2048;
static constexpr uint32_t kOffATDesc      = 0x1000;
static constexpr uint32_t kOffARDesc      = 0x1040;
static constexpr uint32_t kARBufSize      = 16384;
static constexpr uint32_t kARResetMark    = 12288;   // re-arm AR buffer past this

static constexpr uint32_t kPollMs         = 20;
static constexpr int      kMaxRomQuadlets = 256;     // 1 KiB config ROM space

struct DmaBuf {
    IOBufferMemoryDescriptor *mem  = nullptr;
    IODMACommand             *dma  = nullptr;
    uint8_t                  *cpu  = nullptr;
    uint32_t                  iova = 0;
    uint32_t                  size = 0;
};

struct ProFireOHCI_IVars {
    IOPCIDevice           *pci        = nullptr;
    uint8_t                bar        = 0;     // memoryIndex for BAR0
    IODispatchQueue       *queue      = nullptr;
    IOTimerDispatchSource *timer      = nullptr;
    OSAction              *timerAction = nullptr;
    mach_timebase_info_data_t timebase = {1, 1};

    DmaBuf                 misc;
    DmaBuf                 arBuf;
    uint32_t               arReadPos  = 0;

    bool                   running    = false;
    bool                   resetSeen  = false;
    uint32_t               generation = 0xFFFFFFFF;
    uint16_t               localNode  = 0xFFFF;
    uint8_t                tlabel     = 0;
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

static inline void ioBarrier() { __asm__ volatile("dmb sy" ::: "memory"); }

static inline uint32_t rd(ProFireOHCI_IVars *iv, uint32_t off)
{
    uint32_t v = 0xFFFFFFFF;
    iv->pci->MemoryRead32(iv->bar, off, &v);
    return v;
}

static inline void wr(ProFireOHCI_IVars *iv, uint32_t off, uint32_t v)
{
    iv->pci->MemoryWrite32(iv->bar, off, v);
}

static inline volatile uint32_t *q32(DmaBuf &b, uint32_t off)
{
    return reinterpret_cast<volatile uint32_t *>(b.cpu + off);
}

static uint64_t nowNs(ProFireOHCI_IVars *iv)
{
    return mach_absolute_time() * iv->timebase.numer / iv->timebase.denom;
}

// Poll until (reg & mask) == want, or timeout. Returns true on success.
static bool waitReg(ProFireOHCI_IVars *iv, uint32_t off, uint32_t mask, uint32_t want, uint32_t timeoutUs)
{
    for (uint32_t t = 0; t < timeoutUs; t += 10) {
        if ((rd(iv, off) & mask) == want) return true;
        IODelay(10);
    }
    return (rd(iv, off) & mask) == want;
}

// IEEE 1212 CRC-16 over host-order quadlets.
static uint16_t crc16_1212(const uint32_t *q, int count)
{
    uint32_t crc = 0;
    for (int i = 0; i < count; i++) {
        uint32_t data = q[i];
        for (int shift = 28; shift >= 0; shift -= 4) {
            uint32_t sum = ((crc >> 12) ^ (data >> shift)) & 0xF;
            crc = (crc << 4) ^ (sum << 12) ^ (sum << 5) ^ sum;
        }
        crc &= 0xFFFF;
    }
    return static_cast<uint16_t>(crc);
}

static const char *evtName(uint32_t e)
{
    switch (e) {
        case Evt_NoStatus:   return "no_status";
        case Evt_MissingAck: return "evt_missing_ack";
        case Evt_BusReset:   return "evt_bus_reset";
        case Evt_Timeout:    return "evt_timeout";
        case Evt_Flushed:    return "evt_flushed";
        case Ack_Complete:   return "ack_complete";
        case Ack_Pending:    return "ack_pending";
        case Ack_BusyX:      return "ack_busy_X";
        case Ack_BusyA:      return "ack_busy_A";
        case Ack_BusyB:      return "ack_busy_B";
        case Ack_Tardy:      return "ack_tardy";
        case Ack_DataError:  return "ack_data_error";
        case Ack_TypeError:  return "ack_type_error";
        default:             return "evt_other";
    }
}

// ---------------------------------------------------------------------------
// DMA buffers
// ---------------------------------------------------------------------------

static kern_return_t allocDma(ProFireOHCI_IVars *iv, uint32_t size, DmaBuf &b)
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
    ret = IODMACommand::Create(iv->pci, kIODMACommandCreateNoOptions, &spec, &b.dma);
    if (ret != kIOReturnSuccess) { LOG("IODMACommand create failed 0x%x", ret); return ret; }

    uint64_t flags = 0;
    uint32_t segCount = 1;
    IOAddressSegment seg = {};
    ret = b.dma->PrepareForDMA(kIODMACommandPrepareForDMANoOptions, b.mem, 0, size, &flags, &segCount, &seg);
    if (ret != kIOReturnSuccess) { LOG("PrepareForDMA failed 0x%x", ret); return ret; }
    if (segCount != 1 || seg.length < size || seg.address > 0xFFFFFFFFull) {
        LOG("DMA buffer not a single 32-bit segment (segs=%u addr=0x%llx len=%llu)",
            segCount, seg.address, seg.length);
        return kIOReturnNoResources;
    }
    b.iova = static_cast<uint32_t>(seg.address);
    b.size = size;
    return kIOReturnSuccess;
}

static void freeDma(DmaBuf &b)
{
    if (b.dma) { b.dma->CompleteDMA(kIODMACommandCompleteDMANoOptions); OSSafeReleaseNULL(b.dma); }
    OSSafeReleaseNULL(b.mem);
    b.cpu = nullptr; b.iova = 0; b.size = 0;
}

// ---------------------------------------------------------------------------
// PHY register access
// ---------------------------------------------------------------------------

static bool phyRead(ProFireOHCI_IVars *iv, uint8_t addr, uint8_t *val)
{
    wr(iv, PhyControl, PhyControl_rdReg | (uint32_t(addr & 0xF) << 8));
    for (int i = 0; i < 1000; i++) {
        uint32_t v = rd(iv, PhyControl);
        if (v & PhyControl_rdDone) {
            if (((v >> 24) & 0xF) != (addr & 0xF)) continue;
            *val = (v >> 16) & 0xFF;
            return true;
        }
        IODelay(10);
    }
    return false;
}

static bool phyWrite(ProFireOHCI_IVars *iv, uint8_t addr, uint8_t val)
{
    wr(iv, PhyControl, PhyControl_wrReg | (uint32_t(addr & 0xF) << 8) | val);
    return waitReg(iv, PhyControl, PhyControl_wrReg, 0, 10000);
}

// ---------------------------------------------------------------------------
// Local config ROM (minimal: bus info block + root dir with node caps/vendor)
// ---------------------------------------------------------------------------

static void buildConfigROM(ProFireOHCI_IVars *iv)
{
    uint32_t hwOpts  = rd(iv, BusOptions);
    uint32_t guidHi  = rd(iv, GUIDHi);
    uint32_t guidLo  = rd(iv, GUIDLo);
    uint32_t maxRec  = (hwOpts >> 12) & 0xF;
    uint32_t linkSpd = hwOpts & 0x7;

    uint32_t rom[8];
    // irmc | cmc | isc, max_rom=2, generation=2
    rom[1] = 0x31333934;                                   // "1394"
    rom[2] = (1u << 31) | (1u << 30) | (1u << 29) | (maxRec << 12) | (2u << 8) | (2u << 4) | linkSpd;
    rom[3] = guidHi;
    rom[4] = guidLo;
    rom[6] = 0x0C0083C0;                                    // node capabilities
    rom[7] = 0x03000000 | (guidHi >> 8);                   // module vendor id
    rom[5] = (2u << 16) | crc16_1212(&rom[6], 2);           // root directory header
    rom[0] = (4u << 24) | (7u << 16) | crc16_1212(&rom[1], 7);

    volatile uint32_t *dst = q32(iv->misc, kOffConfigROM);
    for (int i = 0; i < 8; i++) dst[i] = __builtin_bswap32(rom[i]);   // bus order
    ioBarrier();

    wr(iv, ConfigROMhdr, rom[0]);
    wr(iv, BusOptions,   rom[2]);
    wr(iv, ConfigROMmap, iv->misc.iova + kOffConfigROM);

    LOG("local GUID %08x%08x  hw BusOptions 0x%08x (max_rec %u, link speed S%u)",
        guidHi, guidLo, hwOpts, maxRec, 100u << linkSpd);
}

// ---------------------------------------------------------------------------
// AR response context (buffer-fill mode, single 16 KiB buffer)
// ---------------------------------------------------------------------------

static bool stopContext(ProFireOHCI_IVars *iv, uint32_t base)
{
    wr(iv, base + CtxControlClear, Ctx_run);
    return waitReg(iv, base + CtxControlSet, Ctx_active, 0, 20000);
}

static void armARResponse(ProFireOHCI_IVars *iv)
{
    stopContext(iv, ARRspContextBase);

    auto *d = reinterpret_cast<volatile Descriptor *>(iv->misc.cpu + kOffARDesc);
    d->reqCount       = kARBufSize;
    d->control        = Desc_INPUT_MORE | Desc_STATUS | Desc_BRANCH_ALWAYS;
    d->dataAddress    = iv->arBuf.iova;
    d->branchAddress  = 0;            // Z=0: end of program
    d->resCount       = kARBufSize;
    d->transferStatus = 0;
    ioBarrier();

    wr(iv, ARRspContextBase + CtxCommandPtr, (iv->misc.iova + kOffARDesc) | 1);
    wr(iv, ARRspContextBase + CtxControlSet, Ctx_run);
    iv->arReadPos = 0;
}

static uint32_t arBytesWritten(ProFireOHCI_IVars *iv)
{
    ioBarrier();
    auto *d = reinterpret_cast<volatile Descriptor *>(iv->misc.cpu + kOffARDesc);
    return kARBufSize - d->resCount;
}

// Scan newly arrived AR response packets for a matching read-quadlet response.
// Returns 1 = found, 0 = not yet, -1 = parse error (buffer re-armed).
static int arFindQuadletResponse(ProFireOHCI_IVars *iv, uint16_t srcNode, uint8_t tl,
                                 uint32_t *rcode, uint32_t *data)
{
    uint32_t avail = arBytesWritten(iv);
    while (iv->arReadPos + 16 <= avail) {
        volatile uint32_t *p = q32(iv->arBuf, iv->arReadPos);
        uint32_t h0 = p[0], h1 = p[1];
        uint32_t tcode = (h0 >> 4) & 0xF;
        uint32_t len;
        switch (tcode) {
            case TCode_WriteResponse:       len = 12 + 4; break;
            case TCode_ReadQuadletResponse: len = 16 + 4; break;
            case TCode_ReadBlockResponse:
            case TCode_LockResponse:        len = 16 + (((p[3] >> 16) + 3) & ~3u) + 4; break;
            case TCode_LinkInternal:        len = 12 + 4; break;
            default:
                LOG("AR response: unexpected tcode 0x%x at %u, re-arming", tcode, iv->arReadPos);
                armARResponse(iv);
                return -1;
        }
        if (iv->arReadPos + len > avail) break;   // packet still arriving

        if (tcode == TCode_ReadQuadletResponse) {
            uint32_t ptl  = (h0 >> 10) & 0x3F;
            uint32_t src  = h1 >> 16;
            if (ptl == tl && src == srcNode) {
                *rcode = (h1 >> 12) & 0xF;
                *data  = __builtin_bswap32(p[3]);   // data quadlets are bus order
                iv->arReadPos += len;
                return 1;
            }
        }
        iv->arReadPos += len;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// AT request: one OUTPUT_LAST_Immediate descriptor per transaction
// ---------------------------------------------------------------------------

static uint32_t atSendReadQuadlet(ProFireOHCI_IVars *iv, uint16_t dest, uint16_t offHi, uint32_t offLo, uint8_t tl)
{
    stopContext(iv, ATReqContextBase);

    volatile uint32_t *q = q32(iv->misc, kOffATDesc);
    auto *d = reinterpret_cast<volatile Descriptor *>(q);
    d->reqCount       = 12;
    d->control        = Desc_OUTPUT_LAST | Desc_KEY_IMMEDIATE | Desc_IRQ_ALWAYS | Desc_BRANCH_ALWAYS;
    d->dataAddress    = 0;
    d->branchAddress  = 0;
    d->resCount       = 0;
    d->transferStatus = 0;
    // OHCI AT header format (speed S100 = 0, retry code retry_X = 1)
    q[4] = (uint32_t(0) << 16) | (uint32_t(tl) << 10) | (1u << 8) | (TCode_ReadQuadletRequest << 4);
    q[5] = (uint32_t(dest) << 16) | offHi;
    q[6] = offLo;
    q[7] = 0;
    ioBarrier();

    wr(iv, IntEventClear, Int_reqTxComplete);
    wr(iv, ATReqContextBase + CtxCommandPtr, (iv->misc.iova + kOffATDesc) | 2);
    wr(iv, ATReqContextBase + CtxControlSet, Ctx_run);

    for (int i = 0; i < 10000; i++) {           // up to ~100 ms
        ioBarrier();
        uint16_t st = d->transferStatus;
        if (st != 0) {
            stopContext(iv, ATReqContextBase);
            return st & 0x1F;
        }
        IODelay(10);
    }
    LOG("AT request timed out (ContextControl 0x%08x)", rd(iv, ATReqContextBase + CtxControlSet));
    stopContext(iv, ATReqContextBase);
    return Evt_Timeout;
}

// Full quadlet read transaction with retries. Returns true and fills *value on success.
static bool readQuadlet(ProFireOHCI_IVars *iv, uint16_t node, uint32_t offLo, uint32_t *value)
{
    for (int attempt = 0; attempt < 6; attempt++) {
        if (rd(iv, IntEventSet) & Int_busReset) return false;     // bus changed under us
        if (iv->arReadPos > kARResetMark) armARResponse(iv);

        uint8_t tl = iv->tlabel;
        iv->tlabel = (iv->tlabel + 1) & 0x3F;

        uint32_t evt = atSendReadQuadlet(iv, node, CSRRegisterSpaceHi, offLo, tl);
        if (evt == Ack_BusyX || evt == Ack_BusyA || evt == Ack_BusyB) { IOSleep(2); continue; }
        if (evt == Ack_Complete) {
            // A read can't complete in the ack; treat as protocol oddity and retry.
            continue;
        }
        if (evt != Ack_Pending) {
            LOG("read 0x%04x:%08x -> %{public}s (0x%02x)", node, offLo, evtName(evt), evt);
            if (evt == Evt_MissingAck || evt == Evt_Timeout) { IOSleep(5); continue; }
            return false;
        }

        // Split transaction: wait up to 100 ms for the response packet.
        uint64_t deadline = nowNs(iv) + 100ull * 1000 * 1000;
        while (nowNs(iv) < deadline) {
            uint32_t rcode = 0, data = 0;
            int r = arFindQuadletResponse(iv, node, tl, &rcode, &data);
            if (r == 1) {
                if (rcode != RCode_Complete) {
                    LOG("read 0x%04x:%08x -> rcode %u", node, offLo, rcode);
                    return false;
                }
                *value = data;
                return true;
            }
            if (r < 0) break;
            IODelay(50);
        }
        LOG("read 0x%04x:%08x -> no response (attempt %d)", node, offLo, attempt + 1);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Config ROM parsing of a remote node
// ---------------------------------------------------------------------------

struct RomCache {
    uint32_t q[kMaxRomQuadlets];
    bool     have[kMaxRomQuadlets];
};

static bool romGet(ProFireOHCI_IVars *iv, uint16_t node, RomCache &rc, int idx, uint32_t *v)
{
    if (idx < 0 || idx >= kMaxRomQuadlets) return false;
    if (!rc.have[idx]) {
        if (!readQuadlet(iv, node, CSRConfigROMLo + 4 * idx, &rc.q[idx])) return false;
        rc.have[idx] = true;
    }
    *v = rc.q[idx];
    return true;
}

static const char *keyName(uint32_t key)
{
    switch (key & 0x3F) {
        case 0x01: return "Textual_Descriptor";
        case 0x02: return "Bus_Dependent_Info";
        case 0x03: return "Module_Vendor_ID";
        case 0x04: return "Module_HW_Version";
        case 0x07: return "Module_Spec_ID";
        case 0x08: return "Module_SW_Version";
        case 0x0C: return "Node_Capabilities";
        case 0x0D: return "EUI_64";
        case 0x11: return "Unit_Directory";
        case 0x12: return "Unit_Spec_ID";
        case 0x13: return "Unit_SW_Version";
        case 0x14: return "Logical_Unit_Number";
        case 0x17: return "Model_ID";
        case 0x38: return "Command_Set_Spec_ID";
        case 0x39: return "Command_Set";
        default:   return "key";
    }
}

static void logTextLeaf(ProFireOHCI_IVars *iv, uint16_t node, RomCache &rc, int idx, const char *indent)
{
    uint32_t hdr = 0, spec = 0;
    if (!romGet(iv, node, rc, idx, &hdr) || !romGet(iv, node, rc, idx + 1, &spec)) return;
    uint32_t len = hdr >> 16;
    if (spec != 0 || len < 2 || len > 64) {
        LOG("%{public}s  (non-ASCII or odd leaf, len %u, type 0x%08x)", indent, len, spec);
        return;
    }
    char text[257] = {};
    int n = 0;
    for (uint32_t i = 3; i <= len && n < 256; i++) {
        uint32_t w = 0;
        if (!romGet(iv, node, rc, idx + i, &w)) break;
        for (int s = 24; s >= 0 && n < 256; s -= 8) {
            char c = char((w >> s) & 0xFF);
            if (c) text[n++] = c;
        }
    }
    LOG("%{public}s  text: \"%{public}s\"", indent, text);
}

static void logDirectory(ProFireOHCI_IVars *iv, uint16_t node, RomCache &rc, int idx, int depth)
{
    const char *indent = depth == 0 ? "  " : "      ";
    uint32_t hdr = 0;
    if (!romGet(iv, node, rc, idx, &hdr)) { LOG("%{public}scould not read directory at q%d", indent, idx); return; }
    uint32_t len = hdr >> 16;
    if (len > 64) { LOG("%{public}sdirectory at q%d has bogus length %u", indent, idx, len); return; }

    for (uint32_t i = 1; i <= len; i++) {
        uint32_t e = 0;
        if (!romGet(iv, node, rc, idx + i, &e)) return;
        uint32_t key  = e >> 24;
        uint32_t val  = e & 0xFFFFFF;
        uint32_t type = key >> 6;          // 0 imm, 1 csr offset, 2 leaf, 3 directory
        int target = idx + int(i) + int(val);

        switch (type) {
            case 0:
                LOG("%{public}s%{public}s (0x%02x) = 0x%06x", indent, keyName(key), key, val);
                break;
            case 1:
                LOG("%{public}s%{public}s (0x%02x) -> CSR 0xFFFFF0000000 + 0x%x", indent, keyName(key), key, val * 4);
                break;
            case 2:
                LOG("%{public}s%{public}s (0x%02x) -> leaf @q%d", indent, keyName(key), key, target);
                if ((key & 0x3F) == 0x01) logTextLeaf(iv, node, rc, target, indent);
                break;
            case 3:
                LOG("%{public}s%{public}s (0x%02x) -> directory @q%d", indent, keyName(key), key, target);
                if (depth == 0) logDirectory(iv, node, rc, target, depth + 1);
                break;
        }
    }
}

static void scanNode(ProFireOHCI_IVars *iv, uint8_t phyId)
{
    uint16_t node = 0xFFC0 | phyId;
    RomCache *rc = IONewZero(RomCache, 1);
    if (!rc) return;

    LOG("---- node %u (0x%04x): reading config ROM ----", phyId, node);

    uint32_t q0 = 0;
    bool ok = false;
    for (int tries = 0; tries < 20; tries++) {          // device may still be booting
        rc->have[0] = false;
        if (!romGet(iv, node, *rc, 0, &q0)) break;
        if (q0 != 0) { ok = true; break; }
        IOSleep(100);
    }
    if (!ok) { LOG("node %u: no readable config ROM", phyId); IOSafeDeleteNULL(rc, RomCache, 1); return; }

    uint32_t infoLen = q0 >> 24, crcLen = (q0 >> 16) & 0xFF;
    LOG("ROM header 0x%08x (info_length %u, crc_length %u)", q0, infoLen, crcLen);

    if (infoLen == 1) {
        LOG("minimal ROM, vendor 0x%06x", q0 & 0xFFFFFF);
    } else if (infoLen >= 4) {
        uint32_t magic = 0, opts = 0, gHi = 0, gLo = 0;
        if (romGet(iv, node, *rc, 1, &magic) && romGet(iv, node, *rc, 2, &opts) &&
            romGet(iv, node, *rc, 3, &gHi)   && romGet(iv, node, *rc, 4, &gLo)) {
            uint32_t oui = gHi >> 8;
            LOG("bus_name 0x%08x%{public}s  bus options 0x%08x", magic, magic == 0x31333934 ? " (\"1394\")" : " (!)", opts);
            LOG("  irmc %u cmc %u isc %u bmc %u pmc %u max_rec %u (=%u bytes) link S%u",
                (opts >> 31) & 1, (opts >> 30) & 1, (opts >> 29) & 1, (opts >> 28) & 1, (opts >> 27) & 1,
                (opts >> 12) & 0xF, 2u << ((opts >> 12) & 0xF), 100u << (opts & 7));
            LOG("GUID %08x%08x  vendor OUI 0x%06x%{public}s", gHi, gLo, oui,
                oui == 0x000D6C ? " (M-Audio)" : oui == 0x000166 ? " (TC Electronic)" : "");
            logDirectory(iv, node, *rc, 1 + int(infoLen), 0);
        }
    }

    int count = 0;
    for (int i = 0; i < kMaxRomQuadlets; i++) if (rc->have[i]) count++;
    LOG("---- node %u: done, %d ROM quadlets read ----", phyId, count);
    IOSafeDeleteNULL(rc, RomCache, 1);
}

// ---------------------------------------------------------------------------
// Bus reset / self-ID handling
// ---------------------------------------------------------------------------

static void handleSelfIDs(ProFireOHCI_IVars *iv)
{
    uint32_t count  = rd(iv, SelfIDCount);
    uint32_t nodeId = rd(iv, NodeID);

    // Clear reset events so AT contexts may transmit again.
    wr(iv, IntEventClear, Int_busReset | Int_selfIDComplete | Int_selfIDComplete2);

    if (count & SelfIDCount_error) { LOG("self-ID receive error, waiting for next reset"); return; }
    if (!(nodeId & NodeID_idValid)) { LOG("node ID not valid after reset"); return; }

    uint32_t gen     = (count >> 16) & 0xFF;
    uint32_t quads   = (count >> 2) & 0x1FF;
    uint8_t  localPhy = nodeId & 0x3F;
    bool     isRoot  = nodeId & NodeID_root;
    iv->generation = gen;
    iv->localNode  = nodeId & 0xFFFF;

    if (isRoot) wr(iv, LinkControlSet, LinkControl_cycleMaster);
    else        wr(iv, LinkControlClear, LinkControl_cycleMaster);

    ioBarrier();
    volatile uint32_t *sid = q32(iv->misc, kOffSelfID);
    uint32_t bufGen = (sid[0] >> 16) & 0xFF;
    LOG("==== bus reset: generation %u (buffer %u), local node 0x%04x phy %u%{public}s, %u self-ID quadlets ====",
        gen, bufGen, iv->localNode, localPhy, isRoot ? " ROOT" : "", quads);

    uint8_t remote[64];
    int nRemote = 0;
    for (uint32_t i = 1; i + 1 < quads && i + 1 < kSelfIDBytes / 4; i += 2) {
        uint32_t s = sid[i], inv = sid[i + 1];
        if (s != ~inv) { LOG("self-ID quadlet %u fails inverse check (0x%08x / 0x%08x)", i, s, inv); continue; }
        if ((s >> 30) != 2) continue;
        if (s & (1u << 23)) continue;                     // extended packet (more ports)
        uint8_t  phy  = (s >> 24) & 0x3F;
        bool     link = (s >> 22) & 1;
        uint32_t gap  = (s >> 16) & 0x3F;
        uint32_t sp   = (s >> 14) & 0x3;
        bool     cont = (s >> 11) & 1;
        uint32_t pwr  = (s >> 8) & 0x7;
        static const char *portStr[] = {"-", "x", "parent", "child"};
        LOG("  phy %u: link %{public}s, gap %u, speed S%u, contender %u, power %u, ports [%{public}s %{public}s %{public}s]%{public}s",
            phy, link ? "on" : "off", gap, 100u << sp, cont, pwr,
            portStr[(s >> 6) & 3], portStr[(s >> 4) & 3], portStr[(s >> 2) & 3],
            phy == localPhy ? "  <- this Mac" : "");
        if (link && phy != localPhy && nRemote < 64) remote[nRemote++] = phy;
    }

    if (nRemote == 0) {
        LOG("no other nodes with an active link on the bus. Is the ProFire powered on and cabled to the dock's FW800 port?");
        return;
    }

    for (int i = 0; i < nRemote; i++) {
        if (rd(iv, IntEventSet) & Int_busReset) { LOG("bus reset during scan, restarting"); return; }
        scanNode(iv, remote[i]);
    }
}

// ---------------------------------------------------------------------------
// Controller bring-up / shutdown
// ---------------------------------------------------------------------------

static kern_return_t ohciInit(ProFireOHCI_IVars *iv)
{
    uint32_t ver = rd(iv, Version);
    LOG("OHCI version %x.%02x (raw 0x%08x), GUID_ROM %u", (ver >> 16) & 0xFF, ver & 0xFF, ver, (ver >> 24) & 1);
    if (ver == 0xFFFFFFFF) { LOG("BAR reads all ones, device not responding"); return kIOReturnNotResponding; }

    // 1. Soft reset.
    wr(iv, HCControlSet, HCControl_softReset);
    if (!waitReg(iv, HCControlSet, HCControl_softReset, 0, 500000)) { LOG("soft reset did not complete"); return kIOReturnTimeout; }

    // 2. Link power status on; some chips need a few tries.
    bool lps = false;
    for (int i = 0; i < 3 && !lps; i++) {
        wr(iv, HCControlSet, HCControl_LPS | HCControl_postedWriteEnable);
        IOSleep(50);
        lps = rd(iv, HCControlSet) & HCControl_LPS;
    }
    if (!lps) { LOG("LPS failed to come up"); return kIOReturnNotResponding; }

    // 3. Data byte order = bus order; header quadlets host order.
    wr(iv, HCControlClear, HCControl_noByteSwapData);

    // 4. Self-ID reception, PHY packets, retries.
    wr(iv, SelfIDBuffer, iv->misc.iova + kOffSelfID);
    wr(iv, LinkControlSet, LinkControl_rcvSelfID | LinkControl_rcvPhyPkt);
    wr(iv, ATRetries, (3 << 0) | (3 << 4) | (3 << 8) | (200 << 16));

    // 5. No interrupts; clear everything pending.
    wr(iv, IntMaskClear, 0xFFFFFFFF);
    wr(iv, IntEventClear, 0xFFFFFFFF);
    wr(iv, IsoXmitIntMaskClear, 0xFFFFFFFF);
    wr(iv, IsoRecvIntMaskClear, 0xFFFFFFFF);

    // 6. Local config ROM.
    buildConfigROM(iv);

    // 7. AR response context ready before the link goes live.
    armARResponse(iv);

    uint8_t phy1 = 0, phy2 = 0;
    if (phyRead(iv, 1, &phy1) && phyRead(iv, 2, &phy2))
        LOG("PHY reg1 0x%02x (gap count %u), reg2 0x%02x (%u ports, max speed code %u)",
            phy1, phy1 & 0x3F, phy2, phy2 & 0x1F, phy2 >> 5);
    else
        LOG("PHY register read failed (link may still be fine)");

    // 8. Enable the link, cycle timer, and force a bus reset.
    wr(iv, HCControlSet, HCControl_linkEnable | HCControl_BIBimageValid);
    wr(iv, LinkControlSet, LinkControl_cycleTimerEnable);

    if (phyRead(iv, 1, &phy1)) phyWrite(iv, 1, phy1 | 0x40);   // IBR: initiate bus reset
    LOG("link enabled, bus reset requested");
    return kIOReturnSuccess;
}

static void ohciShutdown(ProFireOHCI_IVars *iv)
{
    if (!iv->pci) return;
    stopContext(iv, ATReqContextBase);
    stopContext(iv, ARRspContextBase);
    wr(iv, IntMaskClear, 0xFFFFFFFF);
    wr(iv, HCControlClear, HCControl_linkEnable);
    wr(iv, HCControlSet, HCControl_softReset);
    waitReg(iv, HCControlSet, HCControl_softReset, 0, 100000);
    wr(iv, HCControlClear, HCControl_LPS);
}

static void scheduleTick(ProFireOHCI_IVars *iv)
{
    uint64_t delta = uint64_t(kPollMs) * 1000 * 1000 * iv->timebase.denom / iv->timebase.numer;
    iv->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + delta, delta / 4);
}

// ---------------------------------------------------------------------------
// IOService
// ---------------------------------------------------------------------------

bool ProFireOHCI::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(ProFireOHCI_IVars, 1);
    return ivars != nullptr;
}

void ProFireOHCI::free()
{
    IOSafeDeleteNULL(ivars, ProFireOHCI_IVars, 1);
    super::free();
}

kern_return_t IMPL(ProFireOHCI, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    auto *iv = ivars;
    mach_timebase_info(&iv->timebase);
    if (iv->timebase.numer == 0 || iv->timebase.denom == 0) iv->timebase = {1, 1};

    iv->pci = OSDynamicCast(IOPCIDevice, provider);
    if (!iv->pci) { LOG("provider is not an IOPCIDevice"); return kIOReturnNoDevice; }
    iv->pci->retain();

    ret = iv->pci->Open(this, 0);
    if (ret != kIOReturnSuccess) { LOG("PCI Open failed 0x%x", ret); goto fail; }

    {
        uint16_t vendor = 0, device = 0, cmd = 0;
        iv->pci->ConfigurationRead16(kIOPCIConfigurationOffsetVendorID, &vendor);
        iv->pci->ConfigurationRead16(kIOPCIConfigurationOffsetDeviceID, &device);
        iv->pci->ConfigurationRead16(kIOPCIConfigurationOffsetCommand, &cmd);
        iv->pci->ConfigurationWrite16(kIOPCIConfigurationOffsetCommand,
                                      cmd | kIOPCICommandMemorySpace | kIOPCICommandBusMaster);
        LOG("attached to PCI %04x:%04x, command 0x%04x -> 0x%04x", vendor, device, cmd,
            cmd | kIOPCICommandMemorySpace | kIOPCICommandBusMaster);

        uint64_t barSize = 0; uint8_t barType = 0, memIndex = 0;
        if (iv->pci->GetBARInfo(0, &memIndex, &barSize, &barType) == kIOReturnSuccess) {
            iv->bar = memIndex;
            LOG("BAR0: memory index %u, size %llu, type %u", memIndex, barSize, barType);
        }
    }

    if ((ret = allocDma(iv, kMiscSize, iv->misc)) != kIOReturnSuccess) goto fail;
    if ((ret = allocDma(iv, kARBufSize, iv->arBuf)) != kIOReturnSuccess) goto fail;
    LOG("DMA: misc @0x%08x, AR buffer @0x%08x", iv->misc.iova, iv->arBuf.iova);

    if ((ret = ohciInit(iv)) != kIOReturnSuccess) goto fail;

    ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &iv->queue);
    if (ret != kIOReturnSuccess) { LOG("CopyDispatchQueue failed 0x%x", ret); goto fail; }
    ret = IOTimerDispatchSource::Create(iv->queue, &iv->timer);
    if (ret != kIOReturnSuccess) { LOG("timer create failed 0x%x", ret); goto fail; }
    ret = CreateActionTimerFired(0, &iv->timerAction);
    if (ret != kIOReturnSuccess) { LOG("timer action create failed 0x%x", ret); goto fail; }
    iv->timer->SetHandler(iv->timerAction);
    iv->running = true;
    scheduleTick(iv);

    ret = RegisterService();
    if (ret != kIOReturnSuccess) LOG("RegisterService failed 0x%x (continuing)", ret);
    LOG("started");
    return kIOReturnSuccess;

fail:
    LOG("start failed 0x%x", ret);
    ohciShutdown(iv);
    freeDma(iv->arBuf);
    freeDma(iv->misc);
    if (iv->pci) { iv->pci->Close(this, 0); OSSafeReleaseNULL(iv->pci); }
    return ret;
}

void IMPL(ProFireOHCI, TimerFired)
{
    auto *iv = ivars;
    if (!iv->running) return;

    uint32_t ev = rd(iv, IntEventSet);
    if (ev == 0xFFFFFFFF) {
        LOG("controller vanished (dock unplugged?), stopping poll");
        iv->running = false;
        return;
    }
    if (ev & Int_unrecoverableError) {
        LOG("unrecoverable error: ATReq ctl 0x%08x, ARRsp ctl 0x%08x",
            rd(iv, ATReqContextBase + CtxControlSet), rd(iv, ARRspContextBase + CtxControlSet));
        wr(iv, IntEventClear, Int_unrecoverableError);
        armARResponse(iv);
    }
    if (ev & Int_regAccessFail) { LOG("register access failed (PHY clock off?)"); wr(iv, IntEventClear, Int_regAccessFail); }
    if (ev & Int_postedWriteErr) { LOG("posted write error"); wr(iv, IntEventClear, Int_postedWriteErr); }

    if (ev & Int_busReset) iv->resetSeen = true;
    if (iv->resetSeen && (ev & Int_selfIDComplete)) {
        iv->resetSeen = false;
        handleSelfIDs(iv);
    }

    // Keep housekeeping bits from piling up.
    wr(iv, IntEventClear, ev & (Int_reqTxComplete | Int_respTxComplete | Int_ARRQ | Int_ARRS |
                                Int_RQPkt | Int_RSPkt | Int_cycle64Seconds | Int_cycleSynch | Int_phy));
    scheduleTick(iv);
}

kern_return_t IMPL(ProFireOHCI, Stop)
{
    auto *iv = ivars;
    LOG("stopping");
    iv->running = false;

    if (iv->timer) {
        iv->timer->Cancel(^{});
        OSSafeReleaseNULL(iv->timer);
    }
    OSSafeReleaseNULL(iv->timerAction);
    OSSafeReleaseNULL(iv->queue);

    ohciShutdown(iv);
    freeDma(iv->arBuf);
    freeDma(iv->misc);
    if (iv->pci) { iv->pci->Close(this, 0); OSSafeReleaseNULL(iv->pci); }

    return Stop(provider, SUPERDISPATCH);
}
