//
//  FWController.cpp
//

#include "FWController.h"
#include "OHCI.h"

using namespace ohci;

// Layout of the 16 KiB "misc" DMA buffer.
static constexpr uint32_t kMiscSize     = 16384;
static constexpr uint32_t kOffConfigROM = 0x0000;   // 1 KiB aligned
static constexpr uint32_t kOffSelfID    = 0x0800;   // 2 KiB aligned
static constexpr uint32_t kSelfIDBytes  = 2048;
static constexpr uint32_t kOffATDesc    = 0x1000;   // 2 descriptor blocks + 1 descriptor
static constexpr uint32_t kOffARDesc    = 0x1040;
static constexpr uint32_t kOffATPayload = 0x1200;   // up to 512 bytes
static constexpr uint32_t kOffNotify    = 0x1800;   // DICE notification target
static constexpr uint32_t kARBufSize    = 16384;
static constexpr uint32_t kARResetMark  = 12288;

uint32_t FWController::rd(uint32_t off) const
{
    uint32_t v = 0xFFFFFFFF;
    pci->MemoryRead32(bar, off, &v);
    return v;
}

void FWController::wr(uint32_t off, uint32_t v) const
{
    pci->MemoryWrite32(bar, off, v);
}

static bool waitBits(const FWController *c, uint32_t off, uint32_t mask, uint32_t want, uint32_t timeoutUs)
{
    for (uint32_t t = 0; t < timeoutUs; t += 10) {
        if ((c->rd(off) & mask) == want) return true;
        IODelay(10);
    }
    return (c->rd(off) & mask) == want;
}

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
    return uint16_t(crc);
}

static const char *evtName(uint32_t e)
{
    switch (e) {
        case Evt_MissingAck: return "evt_missing_ack";
        case Evt_Timeout:    return "evt_timeout";
        case Evt_Flushed:    return "evt_flushed";
        case Ack_Complete:   return "ack_complete";
        case Ack_Pending:    return "ack_pending";
        case Ack_BusyX: case Ack_BusyA: case Ack_BusyB: return "ack_busy";
        case Ack_DataError:  return "ack_data_error";
        case Ack_TypeError:  return "ack_type_error";
        default:             return "evt_other";
    }
}

// ---------------------------------------------------------------------------

bool FWController::phyRead(uint8_t addr, uint8_t *val)
{
    wr(PhyControl, PhyControl_rdReg | (uint32_t(addr & 0xF) << 8));
    for (int i = 0; i < 1000; i++) {
        uint32_t v = rd(PhyControl);
        if ((v & PhyControl_rdDone) && ((v >> 24) & 0xF) == (addr & 0xF)) { *val = (v >> 16) & 0xFF; return true; }
        IODelay(10);
    }
    return false;
}

bool FWController::phyWrite(uint8_t addr, uint8_t val)
{
    wr(PhyControl, PhyControl_wrReg | (uint32_t(addr & 0xF) << 8) | val);
    return waitBits(this, PhyControl, PhyControl_wrReg, 0, 10000);
}

void FWController::buildConfigROM()
{
    uint32_t hwOpts = rd(BusOptions), guidHi = rd(GUIDHi), guidLo = rd(GUIDLo);
    uint32_t maxRec = (hwOpts >> 12) & 0xF, linkSpd = hwOpts & 0x7;
    uint32_t rom[8];
    rom[1] = 0x31333934;
    rom[2] = (1u << 31) | (1u << 30) | (1u << 29) | (maxRec << 12) | (2u << 8) | (2u << 4) | linkSpd;
    rom[3] = guidHi;
    rom[4] = guidLo;
    rom[6] = 0x0C0083C0;
    rom[7] = 0x03000000 | (guidHi >> 8);
    rom[5] = (2u << 16) | crc16_1212(&rom[6], 2);
    rom[0] = (4u << 24) | (7u << 16) | crc16_1212(&rom[1], 7);
    volatile uint32_t *dst = misc.q32(kOffConfigROM);
    for (int i = 0; i < 8; i++) dst[i] = __builtin_bswap32(rom[i]);
    ioBarrier();
    wr(ConfigROMhdr, rom[0]);
    wr(BusOptions, rom[2]);
    wr(ConfigROMmap, misc.iova(kOffConfigROM));
}

bool FWController::stopContext(uint32_t base)
{
    wr(base + CtxControlClear, Ctx_run);
    return waitBits(this, base + CtxControlSet, Ctx_active, 0, 20000);
}

void FWController::armARResponse()
{
    stopContext(ARRspContextBase);
    auto *d = reinterpret_cast<volatile Descriptor *>(misc.cpu + kOffARDesc);
    d->reqCount = kARBufSize;
    d->control = Desc_INPUT_MORE | Desc_STATUS | Desc_BRANCH_ALWAYS;
    d->dataAddress = arBuf.iova(0);
    d->branchAddress = 0;
    d->resCount = kARBufSize;
    d->transferStatus = 0;
    ioBarrier();
    wr(ARRspContextBase + CtxCommandPtr, misc.iova(kOffARDesc) | 1);
    wr(ARRspContextBase + CtxControlSet, Ctx_run);
    arReadPos = 0;
}

uint32_t FWController::arBytesWritten()
{
    ioBarrier();
    auto *d = reinterpret_cast<volatile Descriptor *>(misc.cpu + kOffARDesc);
    return kARBufSize - d->resCount;
}

// 1 = found, 0 = not yet, -1 = parse error
int FWController::arFindResponse(uint16_t src, uint8_t tl, uint32_t *tcodeOut, uint32_t *rcode,
                                 uint8_t *data, uint32_t cap, uint32_t *dataLen)
{
    uint32_t avail = arBytesWritten();
    while (arReadPos + 16 <= avail) {
        volatile uint32_t *p = arBuf.q32(arReadPos);
        uint32_t h0 = p[0], h1 = p[1];
        uint32_t tcode = (h0 >> 4) & 0xF;
        uint32_t len, dlen = 0;
        switch (tcode) {
            case TCode_WriteResponse:       len = 12 + 4; break;
            case TCode_ReadQuadletResponse: len = 16 + 4; dlen = 4; break;
            case TCode_ReadBlockResponse:
            case TCode_LockResponse:        dlen = p[3] >> 16; len = 16 + ((dlen + 3) & ~3u) + 4; break;
            case TCode_LinkInternal:        len = 12 + 4; break;
            default:
                LOG("AR response: unexpected tcode 0x%x, re-arming", tcode);
                armARResponse();
                return -1;
        }
        if (arReadPos + len > avail) break;
        if (tcode != TCode_LinkInternal && ((h0 >> 10) & 0x3F) == tl && (h1 >> 16) == src) {
            *tcodeOut = tcode;
            *rcode = (h1 >> 12) & 0xF;
            uint32_t n = dlen > cap ? cap : dlen;
            const volatile uint8_t *src8 = reinterpret_cast<const volatile uint8_t *>(
                tcode == TCode_ReadQuadletResponse ? &p[3] : &p[4]);
            for (uint32_t i = 0; i < n; i++) data[i] = src8[i];
            *dataLen = n;
            arReadPos += len;
            return 1;
        }
        arReadPos += len;
    }
    return 0;
}

uint32_t FWController::atSend(const uint32_t hdr[4], uint32_t hdrLen, const uint8_t *payload, uint32_t plen)
{
    stopContext(ATReqContextBase);
    volatile uint32_t *q = misc.q32(kOffATDesc);
    auto *d0 = reinterpret_cast<volatile Descriptor *>(q);
    auto *d2 = reinterpret_cast<volatile Descriptor *>(misc.cpu + kOffATDesc + 32);
    volatile Descriptor *last;
    uint32_t z;

    d0->reqCount = uint16_t(hdrLen);
    d0->dataAddress = 0;
    d0->branchAddress = 0;
    d0->resCount = 0;
    d0->transferStatus = 0;
    for (int i = 0; i < 4; i++) q[4 + i] = hdr[i];

    if (plen == 0) {
        d0->control = Desc_OUTPUT_LAST | Desc_KEY_IMMEDIATE | Desc_IRQ_ALWAYS | Desc_BRANCH_ALWAYS;
        last = d0; z = 2;
    } else {
        volatile uint8_t *pl = misc.cpu + kOffATPayload;
        for (uint32_t i = 0; i < plen; i++) pl[i] = payload[i];
        d0->control = Desc_OUTPUT_MORE | Desc_KEY_IMMEDIATE;
        d2->reqCount = uint16_t(plen);
        d2->control = Desc_OUTPUT_LAST | Desc_IRQ_ALWAYS | Desc_BRANCH_ALWAYS;
        d2->dataAddress = misc.iova(kOffATPayload);
        d2->branchAddress = 0;
        d2->resCount = 0;
        d2->transferStatus = 0;
        last = d2; z = 3;
    }
    ioBarrier();
    wr(IntEventClear, Int_reqTxComplete);
    wr(ATReqContextBase + CtxCommandPtr, misc.iova(kOffATDesc) | z);
    wr(ATReqContextBase + CtxControlSet, Ctx_run);

    for (int i = 0; i < 10000; i++) {
        ioBarrier();
        uint16_t st = last->transferStatus;
        if (st != 0) { stopContext(ATReqContextBase); return st & 0x1F; }
        IODelay(10);
    }
    stopContext(ATReqContextBase);
    return Evt_Timeout;
}

bool FWController::transact(uint16_t node, const uint32_t hdrIn[4], uint32_t hdrLen,
                            const uint8_t *payload, uint32_t plen, uint32_t expectTcode,
                            uint8_t *resp, uint32_t respCap, uint32_t *respLen, const char *what, uint32_t lo)
{
    IOLockLock(lock);
    bool ok = false;
    for (int attempt = 0; attempt < 6 && !ok; attempt++) {
        if (resetPending()) break;
        if (arReadPos > kARResetMark) armARResponse();

        uint8_t tl = tlabel;
        tlabel = (tlabel + 1) & 0x3F;
        uint32_t hdr[4] = { hdrIn[0] | (uint32_t(tl) << 10), hdrIn[1], hdrIn[2], hdrIn[3] };

        uint32_t evt = atSend(hdr, hdrLen, payload, plen);
        if (evt == Ack_BusyX || evt == Ack_BusyA || evt == Ack_BusyB) { IOSleep(2); continue; }
        if (evt == Ack_Complete) {
            if (expectTcode == TCode_WriteResponse) { if (respLen) *respLen = 0; ok = true; }
            continue;
        }
        if (evt != Ack_Pending) {
            LOG("%{public}s 0x%04x:%08x -> %{public}s (0x%02x)", what, node, lo, evtName(evt), evt);
            if (evt == Evt_MissingAck || evt == Evt_Timeout) { IOSleep(5); continue; }
            break;
        }
        uint64_t deadline = nowNs() + 100ull * 1000 * 1000;
        while (nowNs() < deadline) {
            uint32_t tcode = 0, rcode = 0, dlen = 0;
            int r = arFindResponse(node, tl, &tcode, &rcode, resp, respCap, &dlen);
            if (r == 1) {
                if (rcode != RCode_Complete) { LOG("%{public}s 0x%04x:%08x -> rcode %u", what, node, lo, rcode); attempt = 99; break; }
                if (tcode != expectTcode) { LOG("%{public}s: unexpected response tcode 0x%x", what, tcode); attempt = 99; break; }
                if (respLen) *respLen = dlen;
                ok = true;
                break;
            }
            if (r < 0) break;
            IODelay(50);
        }
        if (!ok && attempt < 99) LOG("%{public}s 0x%04x:%08x -> no response (attempt %d)", what, node, lo, attempt + 1);
    }
    IOLockUnlock(lock);
    return ok;
}

bool FWController::readQuadlet(uint16_t node, uint16_t hi, uint32_t lo, uint32_t *v)
{
    uint32_t hdr[4] = { (1u << 8) | (TCode_ReadQuadletRequest << 4), (uint32_t(node) << 16) | hi, lo, 0 };
    uint8_t d[16]; uint32_t n = 0;
    if (!transact(node, hdr, 12, nullptr, 0, TCode_ReadQuadletResponse, d, sizeof(d), &n, "read", lo) || n < 4) return false;
    *v = (uint32_t(d[0]) << 24) | (uint32_t(d[1]) << 16) | (uint32_t(d[2]) << 8) | d[3];
    return true;
}

bool FWController::writeQuadlet(uint16_t node, uint16_t hi, uint32_t lo, uint32_t v)
{
    uint32_t hdr[4] = { (1u << 8) | (TCode_WriteQuadletRequest << 4), (uint32_t(node) << 16) | hi, lo, __builtin_bswap32(v) };
    uint32_t n = 0;
    return transact(node, hdr, 16, nullptr, 0, TCode_WriteResponse, nullptr, 0, &n, "write", lo);
}

static void putBE32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = uint8_t(v); }
static uint32_t getBE32(const uint8_t *p) { return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3]; }

bool FWController::compareSwap32(uint16_t node, uint16_t hi, uint32_t lo, uint32_t arg, uint32_t data, uint32_t *old)
{
    uint8_t pl[8]; putBE32(pl, arg); putBE32(pl + 4, data);
    uint32_t hdr[4] = { (1u << 8) | (TCode_LockRequest << 4), (uint32_t(node) << 16) | hi, lo, (8u << 16) | 2 };
    uint8_t d[16]; uint32_t n = 0;
    if (!transact(node, hdr, 16, pl, 8, TCode_LockResponse, d, sizeof(d), &n, "lock32", lo) || n < 4) return false;
    *old = getBE32(d);
    return true;
}

bool FWController::compareSwap64(uint16_t node, uint16_t hi, uint32_t lo, uint64_t arg, uint64_t data, uint64_t *old)
{
    uint8_t pl[16];
    putBE32(pl, uint32_t(arg >> 32)); putBE32(pl + 4, uint32_t(arg));
    putBE32(pl + 8, uint32_t(data >> 32)); putBE32(pl + 12, uint32_t(data));
    uint32_t hdr[4] = { (1u << 8) | (TCode_LockRequest << 4), (uint32_t(node) << 16) | hi, lo, (16u << 16) | 2 };
    uint8_t d[16]; uint32_t n = 0;
    if (!transact(node, hdr, 16, pl, 16, TCode_LockResponse, d, sizeof(d), &n, "lock64", lo) || n < 8) return false;
    *old = (uint64_t(getBE32(d)) << 32) | getBE32(d + 4);
    return true;
}

bool FWController::readBlock(uint16_t node, uint16_t hi, uint32_t lo, uint8_t *buf, uint32_t bytes)
{
    while (bytes) {
        uint32_t n = bytes > 512 ? 512 : bytes;
        uint32_t hdr[4] = { (1u << 8) | (TCode_ReadBlockRequest << 4), (uint32_t(node) << 16) | hi, lo, n << 16 };
        uint32_t got = 0;
        if (!transact(node, hdr, 16, nullptr, 0, TCode_ReadBlockResponse, buf, n, &got, "readblk", lo) || got < n) return false;
        buf += n; lo += n; bytes -= n;
    }
    return true;
}

bool FWController::writeBlock(uint16_t node, uint16_t hi, uint32_t lo, const uint8_t *buf, uint32_t bytes)
{
    while (bytes) {
        uint32_t n = bytes > 512 ? 512 : bytes;
        uint32_t hdr[4] = { (1u << 8) | (TCode_WriteBlockRequest << 4), (uint32_t(node) << 16) | hi, lo, n << 16 };
        uint32_t got = 0;
        if (!transact(node, hdr, 16, buf, n, TCode_WriteResponse, nullptr, 0, &got, "writeblk", lo)) return false;
        buf += n; lo += n; bytes -= n;
    }
    return true;
}

// ---------------------------------------------------------------------------

bool FWController::readRomInfo(uint16_t node, RomInfo &info)
{
    uint32_t q0 = 0;
    for (int tries = 0; tries < 20; tries++) {
        if (!readQuadlet(node, CSRRegisterSpaceHi, CSRConfigROMLo, &q0)) return false;
        if (q0) break;
        IOSleep(100);
    }
    uint32_t infoLen = q0 >> 24;
    if (infoLen < 4) return false;
    if (!readQuadlet(node, CSRRegisterSpaceHi, CSRConfigROMLo + 12, &info.guidHi) ||
        !readQuadlet(node, CSRRegisterSpaceHi, CSRConfigROMLo + 16, &info.guidLo)) return false;

    int root = 1 + int(infoLen);
    uint32_t hdr = 0;
    if (!readQuadlet(node, CSRRegisterSpaceHi, CSRConfigROMLo + 4 * root, &hdr)) return false;
    uint32_t len = hdr >> 16;
    char *lastText = nullptr;
    for (uint32_t i = 1; i <= len && i < 32; i++) {
        uint32_t e = 0;
        if (!readQuadlet(node, CSRRegisterSpaceHi, CSRConfigROMLo + 4 * (root + i), &e)) break;
        uint32_t key = e >> 24, val = e & 0xFFFFFF;
        if (key == 0x03) { info.vendor = val; lastText = info.vendorName; }
        else if (key == 0x17) { info.model = val; lastText = info.modelName; }
        else if (key == 0x81 && lastText) {
            int leaf = root + int(i) + int(val);
            uint32_t lh = 0;
            readQuadlet(node, CSRRegisterSpaceHi, CSRConfigROMLo + 4 * leaf, &lh);
            uint32_t ll = lh >> 16, n = 0;
            for (uint32_t k = 3; k <= ll && k < 10 && n < 28; k++) {
                uint32_t w = 0;
                if (!readQuadlet(node, CSRRegisterSpaceHi, CSRConfigROMLo + 4 * (leaf + int(k)), &w)) break;
                for (int s = 24; s >= 0 && n < 28; s -= 8) { char c = char((w >> s) & 0xFF); if (c) lastText[n++] = c; }
            }
            lastText[n] = 0;
            lastText = nullptr;
        } else lastText = nullptr;
    }
    return true;
}

void FWController::allowPhysicalFrom(int phy)
{
    if (phy < 0) return;
    if (phy < 32) physMaskLo |= 1u << phy; else physMaskHi |= 1u << (phy - 32);
    wr(PhyReqFilterLoSet, physMaskLo);
    wr(PhyReqFilterHiSet, physMaskHi);
}

void FWController::forceBusReset()
{
    uint8_t r1 = 0;
    if (phyRead(1, &r1)) phyWrite(1, r1 | 0x40);
}

uint32_t FWController::notifyIova() const { return misc.iova(kOffNotify); }

uint32_t FWController::takeNotify()
{
    ioBarrier();
    volatile uint32_t *q = misc.q32(kOffNotify);
    uint32_t v = __builtin_bswap32(*q);
    if (v) { *q = 0; ioBarrier(); }
    uint32_t r = notifyAccum | v;
    notifyAccum = 0;
    return r;
}

uint32_t FWController::cycleTimer() const { return rd(IsochronousCycleTimer); }

bool FWController::resetPending() const { return (rd(IntEventSet) & Int_busReset) != 0; }

// ---------------------------------------------------------------------------

void FWController::handleSelfIDs()
{
    uint32_t count = rd(SelfIDCount), nodeId = rd(NodeID);
    wr(IntEventClear, Int_busReset | Int_selfIDComplete | Int_selfIDComplete2);
    nRemote = 0; irmPhy = -1;
    if (count & SelfIDCount_error) { LOG("self-ID receive error"); return; }
    if (!(nodeId & NodeID_idValid)) { LOG("node ID not valid after reset"); return; }

    generation = (count >> 16) & 0xFF;
    localNode = nodeId & 0xFFFF;
    isRoot = nodeId & NodeID_root;
    uint8_t localPhy = nodeId & 0x3F;
    if (isRoot) wr(LinkControlSet, LinkControl_cycleMaster);
    else        wr(LinkControlClear, LinkControl_cycleMaster);

    // Filters are cleared by bus resets.
    if (physMaskLo) wr(PhyReqFilterLoSet, physMaskLo);
    if (physMaskHi) wr(PhyReqFilterHiSet, physMaskHi);

    ioBarrier();
    volatile uint32_t *sid = misc.q32(kOffSelfID);
    uint32_t quads = (count >> 2) & 0x1FF;
    char line[160]; uint32_t ln = 0;
    for (uint32_t i = 1; i + 1 < quads && i + 1 < kSelfIDBytes / 4; i += 2) {
        uint32_t s = sid[i];
        if (s != ~sid[i + 1] || (s >> 30) != 2 || (s & (1u << 23))) continue;
        uint8_t phy = (s >> 24) & 0x3F;
        bool link = (s >> 22) & 1, contender = (s >> 11) & 1;
        if (link && contender) irmPhy = phy;           // highest qualifying phy wins
        if (link && phy != localPhy && nRemote < 63) remotePhy[nRemote++] = phy;
        const char *tag = phy == localPhy ? "mac" : "dev";
        for (const char *p = tag; *p && ln + 12 < sizeof(line); p++) line[ln++] = *p;
        line[ln++] = char('0' + phy / 10); line[ln++] = char('0' + phy % 10);
        line[ln++] = link ? '+' : '-'; line[ln++] = ' ';
    }
    line[ln] = 0;
    LOG("bus reset: generation %u, local node 0x%04x%{public}s, IRM phy %d, nodes: %{public}s",
        generation, localNode, isRoot ? " (root)" : "", irmPhy, line);
}

bool FWController::pollBusReset()
{
    uint32_t ev = rd(IntEventSet);
    if (ev == 0xFFFFFFFF) return false;
    if (ev & Int_unrecoverableError) {
        LOG("unrecoverable error, re-arming async receive");
        wr(IntEventClear, Int_unrecoverableError);
        IOLockLock(lock); armARResponse(); IOLockUnlock(lock);
    }
    if (ev & Int_regAccessFail) wr(IntEventClear, Int_regAccessFail);
    if (ev & Int_postedWriteErr) { LOG("posted write error"); wr(IntEventClear, Int_postedWriteErr); }
    wr(IntEventClear, ev & (Int_reqTxComplete | Int_respTxComplete | Int_ARRQ | Int_ARRS | Int_RQPkt |
                            Int_RSPkt | Int_cycle64Seconds | Int_cycleSynch | Int_phy | Int_isochTx | Int_isochRx));

    // Collect notification writes so callers can poll for them.
    ioBarrier();
    volatile uint32_t *q = misc.q32(kOffNotify);
    uint32_t v = __builtin_bswap32(*q);
    if (v) { *q = 0; notifyAccum |= v; }

    if (ev & Int_busReset) resetSeen = true;
    if (resetSeen && (ev & Int_selfIDComplete)) {
        resetSeen = false;
        IOLockLock(lock);
        handleSelfIDs();
        IOLockUnlock(lock);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------

kern_return_t FWController::start(IOPCIDevice *dev)
{
    pci = dev;
    lock = IOLockAlloc();
    uint64_t barSize = 0; uint8_t barType = 0, memIndex = 0;
    if (pci->GetBARInfo(0, &memIndex, &barSize, &barType) == kIOReturnSuccess) bar = memIndex;

    kern_return_t ret;
    if ((ret = allocDma(pci, kMiscSize, misc)) != kIOReturnSuccess) return ret;
    if ((ret = allocDma(pci, kARBufSize, arBuf)) != kIOReturnSuccess) return ret;

    uint32_t ver = rd(Version);
    if (ver == 0xFFFFFFFF) { LOG("controller not responding"); return kIOReturnNotResponding; }

    wr(HCControlSet, HCControl_softReset);
    if (!waitBits(this, HCControlSet, HCControl_softReset, 0, 500000)) { LOG("soft reset timeout"); return kIOReturnTimeout; }
    bool lps = false;
    for (int i = 0; i < 3 && !lps; i++) {
        wr(HCControlSet, HCControl_LPS | HCControl_postedWriteEnable);
        IOSleep(50);
        lps = rd(HCControlSet) & HCControl_LPS;
    }
    if (!lps) { LOG("LPS failed"); return kIOReturnNotResponding; }
    wr(HCControlClear, HCControl_noByteSwapData);
    wr(SelfIDBuffer, misc.iova(kOffSelfID));
    wr(LinkControlSet, LinkControl_rcvSelfID | LinkControl_rcvPhyPkt);
    wr(ATRetries, (3 << 0) | (3 << 4) | (3 << 8) | (200 << 16));
    wr(IntMaskClear, 0xFFFFFFFF);
    wr(IntEventClear, 0xFFFFFFFF);

    // How many isochronous contexts does this controller have?
    wr(IsoXmitIntMaskSet, 0xFFFFFFFF);
    numIT = __builtin_popcount(rd(IsoXmitIntMaskSet));
    wr(IsoXmitIntMaskClear, 0xFFFFFFFF);
    wr(IsoRecvIntMaskSet, 0xFFFFFFFF);
    numIR = __builtin_popcount(rd(IsoRecvIntMaskSet));
    wr(IsoRecvIntMaskClear, 0xFFFFFFFF);
    wr(IsoXmitIntEventClear, 0xFFFFFFFF);
    wr(IsoRecvIntEventClear, 0xFFFFFFFF);
    wr(IRMultiChanMaskHiClear, 0xFFFFFFFF);
    wr(IRMultiChanMaskLoClear, 0xFFFFFFFF);

    buildConfigROM();
    armARResponse();

    wr(HCControlSet, HCControl_linkEnable | HCControl_BIBimageValid);
    wr(LinkControlSet, LinkControl_cycleTimerEnable);
    uint8_t phy1 = 0;
    if (phyRead(1, &phy1)) phyWrite(1, phy1 | 0x40);   // initiate bus reset
    LOG("OHCI %x.%02x up: %d IT / %d IR contexts, GUID %08x%08x", (ver >> 16) & 0xFF, ver & 0xFF,
        numIT, numIR, rd(GUIDHi), rd(GUIDLo));
    return kIOReturnSuccess;
}

void FWController::stop()
{
    if (!pci) return;
    if (present()) {
        stopContext(ATReqContextBase);
        stopContext(ARRspContextBase);
        for (int i = 0; i < numIT; i++) wr(ITContextBase + ITContextStride * i + CtxControlClear, Ctx_run);
        for (int i = 0; i < numIR; i++) wr(IRContextBase + IRContextStride * i + CtxControlClear, Ctx_run);
        IOSleep(2);
        wr(IntMaskClear, 0xFFFFFFFF);
        wr(HCControlClear, HCControl_linkEnable);
        wr(HCControlSet, HCControl_softReset);
        waitBits(this, HCControlSet, HCControl_softReset, 0, 100000);
        wr(HCControlClear, HCControl_LPS);
    }
    freeDma(arBuf);
    freeDma(misc);
    if (lock) { IOLockFree(lock); lock = nullptr; }
}
