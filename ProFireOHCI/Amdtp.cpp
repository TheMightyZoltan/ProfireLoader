//
//  Amdtp.cpp
//

#include "Amdtp.h"
#include "OHCI.h"
#include <math.h>

using namespace ohci;

// OUTPUT_MORE_Immediate (32) + OUTPUT_LAST (16), padded to 64 so no block crosses a 4 KiB page
static constexpr uint32_t kITBlock = 64;

static inline uint32_t be(uint32_t v) { return __builtin_bswap32(v); }

bool AmdtpEngine::allocRing(Ring &r, uint32_t descBytes)
{
    if (r.data.cpu) return true;
    uint32_t db = (descBytes + 16383) & ~16383u;
    return allocDma(fw->pci, db, r.desc) == kIOReturnSuccess &&
           allocDma(fw->pci, kSlots * kSlotSize, r.data) == kIOReturnSuccess;
}

void AmdtpEngine::freeRing(Ring &r) { freeDma(r.desc); freeDma(r.data); }

// ---------------------------------------------------------------------------
// Receive (IR, packet-per-buffer, isochHeader)
// ---------------------------------------------------------------------------

void AmdtpEngine::programIR(int s)
{
    Ring &r = ir[s];
    uint32_t base = IRContextBase + IRContextStride * uint32_t(cfg.in[s].ctx);
    fw->wr(base + CtxControlClear, 0xFFFFFFFF);
    for (int i = 0; i < 200 && (fw->rd(base + CtxControlSet) & Ctx_active); i++) IODelay(10);

    for (uint32_t i = 0; i < kSlots; i++) {
        auto *d = reinterpret_cast<volatile Descriptor *>(r.desc.cpu + i * 16);
        d->reqCount = kSlotSize;
        d->control = Desc_INPUT_LAST | Desc_STATUS | Desc_BRANCH_ALWAYS;
        d->dataAddress = r.data.iova(i * kSlotSize);
        d->branchAddress = r.desc.iova(((i + 1) % kSlots) * 16) | 1;
        d->resCount = kSlotSize;
        d->transferStatus = 0;
    }
    ioBarrier();
    fw->wr(base + IRContextMatch, (1u << 29) | (uint32_t(cfg.in[s].channel) & 0x3F));   // tag 1 (CIP)
    fw->wr(base + CtxCommandPtr, r.desc.iova(0) | 1);
    fw->wr(base + CtxControlSet, IRCtx_isochHeader | Ctx_run);
    irRead[s] = 0;
}

bool AmdtpEngine::peekIR(int s, uint32_t *cycle16, const volatile uint32_t **payload, uint32_t *payloadBytes)
{
    Ring &r = ir[s];
    auto *d = reinterpret_cast<volatile Descriptor *>(r.desc.cpu + irRead[s] * 16);
    ioBarrier();
    if (d->transferStatus == 0) return false;
    const volatile uint32_t *q = r.data.q32(irRead[s] * kSlotSize);
    uint32_t ch = uint32_t(cfg.in[s].channel) & 0x3F;
    auto isHdr = [ch](uint32_t x) { return ((x >> 4) & 0xF) == 0xA && ((x >> 8) & 0x3F) == ch; };

    if (layout < 0) {
        if (isHdr(q[0])) layout = 0;
        else if (isHdr(q[1])) layout = 1;
        else {
            LOG("IR%d: unrecognised packet layout %08x %08x %08x %08x (status 0x%04x res %u)", s,
                q[0], q[1], q[2], q[3], d->transferStatus, d->resCount);
            layout = 1;
        }
        LOG("IR packet layout: %{public}s", layout == 0 ? "[header][payload][trailer]" : "[trailer][header][payload]");
    }
    uint32_t hdr, ts;
    if (layout == 0) {
        hdr = q[0];
        uint32_t len = hdr >> 16;
        if (len + 8 > kSlotSize) len = kSlotSize - 8;
        *payload = q + 1;
        ts = q[1 + (len + 3) / 4] & 0xFFFF;
    } else {
        ts = q[0] & 0xFFFF;
        hdr = q[1];
        *payload = q + 2;
    }
    uint32_t len = hdr >> 16;
    if (len + 8 > kSlotSize) len = kSlotSize - 8;
    *payloadBytes = len;
    *cycle16 = ts;
    return true;
}

void AmdtpEngine::releaseIR(int s)
{
    auto *d = reinterpret_cast<volatile Descriptor *>(ir[s].desc.cpu + irRead[s] * 16);
    d->resCount = kSlotSize;
    d->transferStatus = 0;
    ioBarrier();
    irRead[s] = (irRead[s] + 1) % kSlots;
}

// 16-bit cycle stamp (3-bit seconds | 13-bit cycle) -> absolute cycle near `near`.
uint64_t AmdtpEngine::unwrap(uint32_t cycle16, uint64_t near) const
{
    int64_t c = int64_t(((cycle16 >> 13) & 7) * 8000 + (cycle16 & 0x1FFF));
    int64_t b = int64_t(near % 64000);
    int64_t diff = (c - b + 64000) % 64000;
    if (diff > 32000) diff -= 64000;
    return uint64_t(int64_t(near) + diff);
}

uint64_t AmdtpEngine::hostOfCycle(uint64_t absCycle) const
{
    double dCycles = refCycle - double(absCycle);              // positive: in the past
    int64_t ns = int64_t(dCycles * 125000.0);
    return refHost - uint64_t(clock.nsToTicks(ns));
}

// ---------------------------------------------------------------------------
// Transmit (IT)
// ---------------------------------------------------------------------------

void AmdtpEngine::writeIT(int o, uint64_t absCycle, uint32_t blocks, uint16_t syt, uint64_t firstFrame)
{
    Ring &r = it[o];
    uint32_t slot = uint32_t((absCycle - itStartAbs) % kSlots);
    uint8_t *blk = r.desc.cpu + slot * kITBlock;
    volatile uint32_t *q = r.data.q32(slot * kSlotSize);
    const StreamCfg &sc = cfg.out[o];
    uint32_t dbs = sc.pcm + sc.midiSlots;
    uint32_t sid = fw->localNode & 0x3F;

    if (blocks == 0) syt = 0xFFFF;
    q[0] = be((sid << 24) | (dbs << 16) | dbc[o]);
    q[1] = be(0x80000000u | (0x10u << 24) | ((cfg.sfc & 0xFF) << 16) | syt);

    uint32_t chanOff = 0;
    for (int i = 0; i < o; i++) chanOff += cfg.out[i].pcm;
    const double w = 2.0 * M_PI * 1000.0 / double(cfg.rate);
    for (uint32_t b = 0; b < blocks; b++) {
        uint64_t frame = firstFrame + b;
        const float *src = outRing ? outRing + (frame % ringFrames) * outChannels + chanOff : nullptr;
        volatile uint32_t *dst = q + 2 + b * dbs;
        for (uint32_t k = 0; k < sc.pcm; k++) {
            float x = src ? src[k] : 0.0f;
            if (toneChannel >= 0 && uint32_t(toneChannel) == chanOff + k)
                x = 0.25f * float(sin(w * double(frame % (uint64_t(cfg.rate) * 10))));
            if (x > 1.0f) x = 1.0f; else if (x < -1.0f) x = -1.0f;
            int32_t v = int32_t(lrintf(x * 8388607.0f));
            dst[k] = be(0x40000000u | (uint32_t(v) & 0xFFFFFF));
        }
        for (uint32_t m = 0; m < sc.midiSlots; m++) dst[sc.pcm + m] = be(0x80000000u);
    }
    uint32_t dataLen = 8 + blocks * dbs * 4;
    dbc[o] = uint8_t(dbc[o] + blocks);

    auto *d0 = reinterpret_cast<volatile Descriptor *>(blk);
    volatile uint32_t *imm = reinterpret_cast<volatile uint32_t *>(blk + 16);
    auto *d2 = reinterpret_cast<volatile Descriptor *>(blk + 32);
    d0->reqCount = 8;
    d0->control = Desc_OUTPUT_MORE | Desc_KEY_IMMEDIATE;
    d0->dataAddress = 0;
    // Skip address -> this block: on a lost cycle or late fetch the controller retries next cycle
    // instead of going dead (same as Linux firewire-ohci).
    d0->branchAddress = r.desc.iova(slot * kITBlock) | 3;
    d0->resCount = 0;
    d0->transferStatus = 0;
    imm[0] = (2u << 16) | (1u << 14) | ((uint32_t(sc.channel) & 0x3F) << 8) | (0xAu << 4);   // S400, tag 1
    imm[1] = dataLen << 16;
    imm[2] = 0; imm[3] = 0;
    d2->reqCount = uint16_t(dataLen);
    d2->control = Desc_OUTPUT_LAST | Desc_STATUS | Desc_BRANCH_ALWAYS;
    d2->dataAddress = r.data.iova(slot * kSlotSize);
    d2->branchAddress = r.desc.iova(((slot + 1) % kSlots) * kITBlock) | 3;
    d2->resCount = 0;
    d2->transferStatus = 0;
}

void AmdtpEngine::programIT(int o)
{
    uint32_t base = ITContextBase + ITContextStride * uint32_t(cfg.out[o].ctx);
    fw->wr(base + CtxControlClear, 0xFFFFFFFF);
    for (int i = 0; i < 200 && (fw->rd(base + CtxControlSet) & Ctx_active); i++) IODelay(10);
    for (uint32_t i = 0; i < kSlots; i++) writeIT(o, itStartAbs + i, 0, 0xFFFF, 0);
    ioBarrier();
    uint64_t m = itStartAbs % 64000;
    uint32_t match = uint32_t((((m / 8000) & 3) << 13) | (m % 8000));
    fw->wr(base + CtxCommandPtr, it[o].desc.iova(0) | 3);
    if (itCycleMatch) fw->wr(base + CtxControlSet, Ctx_run | ITCtx_cycleMatchEn | (match << ITCtx_cycleMatchShift));
    else              fw->wr(base + CtxControlSet, Ctx_run);
}

void AmdtpEngine::startIT(uint64_t firstIRAbs)
{
    uint64_t target = firstIRAbs + cfg.transferDelayCycles;
    uint64_t nowAbs = uint64_t(refCycle);
    if (target < nowAbs + 8) target = nowAbs + 8;
    itStartAbs = target;
    itNextAbs = target;
    delay = uint32_t(target - firstIRAbs);
    for (int o = 0; o < cfg.nOut; o++) { dbc[o] = 0; programIT(o); }
    itStarted = true;
    LOG("transmit started: IR cycle %llu -> IT cycle %llu (delay %u cycles = %u us)",
        firstIRAbs, target, delay, delay * 125);
}

// ---------------------------------------------------------------------------

kern_return_t AmdtpEngine::start(FWController *f, const Config &c)
{
    fw = f; cfg = c;
    clock.init();
    for (int s = 0; s < cfg.nIn; s++) if (!allocRing(ir[s], kSlots * 16)) return kIOReturnNoMemory;
    for (int o = 0; o < cfg.nOut; o++) if (!allocRing(it[o], kSlots * kITBlock)) return kIOReturnNoMemory;

    uint32_t ct = fw->cycleTimer();
    lastAbs = 64000 + ((ct >> 25) % 8) * 8000 + ((ct >> 12) & 0x1FFF);
    refHost = clock.now(); refCycle = double(lastAbs);
    inSample = 0; gotFirst = false; itStarted = false; layout = -1;
    histPos = 0;
    for (int i = 0; i < kHist; i++) hist[i] = {0xFFFF, 0, 0};
    for (int i = 0; i < kMaxStreams; i++) { synced[i] = false; frameS[i] = 0; statResyncS[i] = 0; disagree[i] = 0; }
    statLate = statEmpty = statPackets = statResync = 0; statLastLog = 0;
    for (int i = 0; i < 64; i++) peak[i] = 0;
    for (int s = 0; s < cfg.nIn; s++) programIR(s);
    active = true;
    return kIOReturnSuccess;
}

void AmdtpEngine::stop()
{
    if (!fw) return;
    active = false;
    if (fw->present()) {
        for (int o = 0; o < cfg.nOut; o++) fw->wr(ITContextBase + ITContextStride * uint32_t(cfg.out[o].ctx) + CtxControlClear, Ctx_run);
        for (int s = 0; s < cfg.nIn; s++) fw->wr(IRContextBase + IRContextStride * uint32_t(cfg.in[s].ctx) + CtxControlClear, Ctx_run);
        IOSleep(2);
    }
    itStarted = false; gotFirst = false;
}

// Diagnose a dead IT context once: where it stopped and what the descriptors say.
void AmdtpEngine::checkITDead()
{
    if (!itStarted || itDeadLogged) return;
    for (int o = 0; o < cfg.nOut; o++) {
        uint32_t base = ITContextBase + ITContextStride * uint32_t(cfg.out[o].ctx);
        uint32_t ctl = fw->rd(base + CtxControlSet);
        if (!(ctl & Ctx_dead)) continue;
        itDeadLogged = true;
        uint32_t cmd = fw->rd(base + CtxCommandPtr);
        uint32_t d0 = it[o].desc.iova(0);
        int slot = int(((cmd & ~0xFu) - d0) / kITBlock);
        uint32_t ct = fw->cycleTimer();
        uint32_t sent = 0;
        for (uint32_t i = 0; i < kSlots; i++) {
            auto *d2 = reinterpret_cast<volatile Descriptor *>(it[o].desc.cpu + i * kITBlock + 32);
            if (d2->transferStatus) sent++;
        }
        LOG("IT%d DEAD: ctl 0x%08x cmdPtr 0x%08x (Z %u, slot %d of desc base 0x%08x), %u slots with status, cycle timer %u.%u, start abs %llu",
            o, ctl, cmd, cmd & 0xF, slot, d0, sent, (ct >> 25), (ct >> 12) & 0x1FFF, itStartAbs);
        for (int k = slot - 2; k <= slot + 1; k++) {
            if (k < 0 || k >= int(kSlots)) continue;
            auto *b0 = reinterpret_cast<volatile uint32_t *>(it[o].desc.cpu + uint32_t(k) * kITBlock);
            LOG("  slot %d: d0 %08x %08x %08x %08x | imm %08x %08x | d2 %08x %08x %08x %08x",
                k, b0[0], b0[1], b0[2], b0[3], b0[4], b0[5], b0[8], b0[9], b0[10], b0[11]);
        }
    }
}


// Write one packet's PCM into the Core Audio input ring at firstFrame.
void AmdtpEngine::writeInput(int s, const volatile uint32_t *payload, uint32_t dbs, uint32_t blocks, uint64_t firstFrame)
{
    if (!inRing || !blocks) return;
    uint32_t chanOff = 0;
    for (int i = 0; i < s; i++) chanOff += cfg.in[i].pcm;
    uint32_t pcm = cfg.in[s].pcm;
    for (uint32_t b = 0; b < blocks; b++) {
        float *dst = inRing + ((firstFrame + b) % ringFrames) * inChannels + chanOff;
        const volatile uint32_t *q = payload + 2 + b * dbs;
        for (uint32_t k = 0; k < pcm && chanOff + k < inChannels; k++) {
            float x = 0.0f;
            if (k < dbs) {
                uint32_t qd = be(q[k]);
                x = float(int32_t(qd << 8) >> 8) * (1.0f / 8388608.0f);
            }
            dst[k] = x;
            float a = x < 0 ? -x : x;
            if (chanOff + k < 64 && a > peak[chanOff + k]) peak[chanOff + k] = a;
        }
    }
}

// SYT (4-bit cycle | 12-bit offset in 24.576 MHz ticks) -> absolute ticks, choosing the cycle
// nearest to (and normally a few cycles after) the packet's own cycle.
uint64_t AmdtpEngine::sytTicks(uint16_t syt, uint64_t cycleAbs)
{
    uint64_t sc = (syt >> 12) & 0xF;
    uint64_t cand = (cycleAbs & ~uint64_t(15)) + sc;
    if (cand + 4 < cycleAbs) cand += 16;
    else if (cand > cycleAbs + 12) cand -= 16;
    return cand * 3072 + (syt & 0xFFF);
}

// Stream-0 frame that is presented at the same time as a stream-s packet's first block.
bool AmdtpEngine::impliedFrame(uint16_t syt, uint64_t cs, int64_t *frame)
{
    int best = -1; uint64_t bestDist = ~0ull;
    for (int i = 0; i < kHist; i++) {
        const SytHist &h = hist[i];
        if (h.syt == 0xFFFF) continue;
        uint64_t dist = h.cycle > cs ? h.cycle - cs : cs - h.cycle;
        if (dist < bestDist) { bestDist = dist; best = i; }
    }
    if (best < 0 || bestDist > 6) return false;
    int64_t t1 = int64_t(((syt >> 12) & 0xF) * 3072 + (syt & 0xFFF));
    int64_t t0 = int64_t(((hist[best].syt >> 12) & 0xF) * 3072 + (hist[best].syt & 0xFFF));
    int64_t expect = (int64_t(cs) - int64_t(hist[best].cycle)) * 3072;
    int64_t d = expect + (((t1 - t0 - expect) % 49152 + 49152 + 24576) % 49152 - 24576);
    double tpf = 24576000.0 / double(cfg.rate);
    *frame = int64_t(hist[best].frame) + int64_t(double(d) / tpf + (d >= 0 ? 0.5 : -0.5));
    return true;
}

// Secondary receive streams: sequential frame counter, anchored to stream 0 by matching SYT.
void AmdtpEngine::pumpSecondary(int s)
{
    for (uint32_t budget = 0; budget < kSlots; budget++) {
        uint32_t ts = 0, bytes = 0;
        const volatile uint32_t *p = nullptr;
        if (!peekIR(s, &ts, &p, &bytes)) return;
        uint64_t cs = unwrap(ts, lastAbs);
        if (cs > lastAbs) return;                       // stream 0 hasn't reached this cycle yet

        uint32_t cip0 = be(p[0]), cip1 = be(p[1]);
        uint32_t dbs = (cip0 >> 16) & 0xFF, fdf = (cip1 >> 16) & 0xFF;
        uint16_t syt = uint16_t(cip1 & 0xFFFF);
        uint32_t blocks = (dbs && fdf != 0xFF && bytes >= 8) ? (bytes - 8) / (dbs * 4) : 0;

        int64_t imp = 0;
        bool haveImp = blocks && syt != 0xFFFF && inSample >= cfg.rate / 10 && impliedFrame(syt, cs, &imp);
        if (!synced[s] && haveImp) {
            frameS[s] = uint64_t(imp); synced[s] = true; statResyncS[s]++; disagree[s] = 0;
            LOG("IR%d anchored at frame %lld (stream 0 at %llu)", s, imp, inSample);
        } else if (synced[s] && haveImp) {
            int64_t e = imp - int64_t(frameS[s]);
            if (e > 2 || e < -2) {
                if (++disagree[s] >= 50) {
                    LOG("IR%d alignment off by %lld frames, re-anchoring", s, e);
                    frameS[s] = uint64_t(imp); disagree[s] = 0; statResyncS[s]++;
                }
            } else disagree[s] = 0;
        }
        if (synced[s] && blocks) {
            // Stay within half a ring of stream 0, otherwise re-anchor.
            int64_t lag = int64_t(inSample) - int64_t(frameS[s]);
            if (lag < -int64_t(ringFrames / 4) || lag > int64_t(ringFrames / 2)) {
                synced[s] = false;
                LOG("IR%d drifted (lag %lld frames), re-anchoring", s, lag);
            } else {
                writeInput(s, p, dbs, blocks, frameS[s]);
                frameS[s] += blocks;
            }
        }
        releaseIR(s);
    }
}

void AmdtpEngine::pump()
{
    if (!active || cfg.nIn == 0) return;
    checkITDead();
    if (restartITRequested && itStarted) {
        restartITRequested = false;
        itDeadLogged = false;
        uint32_t ct = fw->cycleTimer();
        uint32_t c64 = ((ct >> 25) % 8) * 8000 + ((ct >> 12) & 0x1FFF);
        uint64_t nowAbs = unwrap(((c64 / 8000) << 13) | (c64 % 8000), lastAbs);
        itStartAbs = nowAbs + 16;
        itNextAbs = itStartAbs;
        delay = uint32_t(itStartAbs - lastAbs);
        for (int o = 0; o < cfg.nOut; o++) { dbc[o] = 0; programIT(o); }
        LOG("IT restarted at cycle %llu (delay %u)", itStartAbs, delay);
    }

    // Host time <-> cycle reference.
    uint64_t h0 = clock.now();
    uint32_t ct = fw->cycleTimer();
    uint64_t h1 = clock.now();
    uint32_t c64 = ((ct >> 25) % 8) * 8000 + ((ct >> 12) & 0x1FFF);
    uint64_t nowAbs = unwrap(((c64 / 8000) << 13) | (c64 % 8000), lastAbs);
    refHost = (h0 + h1) / 2;
    refCycle = double(nowAbs) + double(ct & 0xFFF) / 3072.0;

    for (uint32_t budget = 0; budget < kSlots; budget++) {
        uint32_t ts0 = 0, bytes0 = 0;
        const volatile uint32_t *p0 = nullptr;
        if (!peekIR(0, &ts0, &p0, &bytes0)) break;
        uint64_t C = unwrap(ts0, lastAbs);

        const volatile uint32_t *ps[kMaxStreams] = { p0 };
        uint32_t bytes[kMaxStreams] = { bytes0 };

        uint32_t cip0 = be(p0[0]), cip1 = be(p0[1]);
        uint32_t dbs0 = (cip0 >> 16) & 0xFF, fdf = (cip1 >> 16) & 0xFF;
        uint16_t syt = uint16_t(cip1 & 0xFFFF);
        uint32_t blocks = (dbs0 && fdf != 0xFF && bytes0 >= 8) ? (bytes0 - 8) / (dbs0 * 4) : 0;
        uint64_t firstFrame = inSample;

        if (rawDumps > 0 && blocks) {
            rawDumps--;
            LOG("raw IR0 cyc %llu bytes %u: cip %08x %08x | %08x %08x %08x %08x %08x %08x | %08x %08x %08x %08x %08x %08x",
                C, bytes0, cip0, cip1, be(p0[2]), be(p0[3]), be(p0[4]), be(p0[5]), be(p0[6]), be(p0[7]),
                be(p0[8]), be(p0[9]), be(p0[10]), be(p0[11]), be(p0[12]), be(p0[13]));

            LOG("raw dbs %u fdf 0x%02x syt 0x%04x blocks %u inRing %p inCh %u", dbs0, fdf, syt, blocks, inRing, inChannels);
        }

        // Input samples of stream 0; remember its SYT -> frame mapping for the other streams.
        writeInput(0, ps[0], dbs0, blocks, firstFrame);
        (void)bytes;
        if (blocks && syt != 0xFFFF) {
            hist[histPos] = { syt, C, firstFrame };
            histPos = (histPos + 1) % kHist;
        }

        // Zero timestamps at every ring wrap.
        if (zts) {
            for (uint32_t b = 0; b < blocks; b++) {
                uint64_t f = firstFrame + b;
                if (f % ringFrames == 0)
                    zts(ztsCtx, f, hostOfCycle(C) + uint64_t(clock.nsToTicks(int64_t(b) * 1000000000ll / int64_t(cfg.rate))));
            }
        }

        // Transmit: replay this cycle's shape onto the outgoing streams.
        if (cfg.nOut > 0) {
            if (!itStarted) startIT(C);
            uint64_t target = C + delay;
            if (target >= itNextAbs) {
                uint32_t gap = 0;
                while (itNextAbs < target && gap < kSlots) {
                    for (int o = 0; o < cfg.nOut; o++) writeIT(o, itNextAbs, 0, 0xFFFF, 0);
                    itNextAbs++; gap++;
                }
                if (gap) statResync++;
                if (target <= nowAbs + 1) statLate++;
                uint16_t osyt = syt == 0xFFFF ? syt : uint16_t(((((syt >> 12) + delay) & 0xF) << 12) | (syt & 0xFFF));
                for (int o = 0; o < cfg.nOut; o++) writeIT(o, target, blocks, osyt, firstFrame);
                ioBarrier();
                itNextAbs = target + 1;
            }
        }

        inSample += blocks;
        lastAbs = C;
        releaseIR(0);
        statPackets++;
        if (!blocks) statEmpty++;
        gotFirst = true;
    }

    for (int s2 = 1; s2 < cfg.nIn; s2++) pumpSecondary(s2);

    if (refHost - statLastLog > uint64_t(clock.nsToTicks(2000000000ll))) {
        if (statLastLog) logStats();
        statLastLog = refHost;
    }
}

static uint32_t putUInt(char *buf, uint32_t n, uint32_t v)
{
    char tmp[12]; uint32_t k = 0;
    do { tmp[k++] = char('0' + v % 10); v /= 10; } while (v && k < sizeof(tmp));
    while (k) buf[n++] = tmp[--k];
    return n;
}

void AmdtpEngine::logStats()
{
    uint32_t irCtl = fw->rd(IRContextBase + IRContextStride * uint32_t(cfg.in[0].ctx) + CtxControlSet);
    uint32_t itCtl = cfg.nOut ? fw->rd(ITContextBase + ITContextStride * uint32_t(cfg.out[0].ctx) + CtxControlSet) : 0;
    LOG("stream: %llu frames, %llu packets (%llu empty), late %llu, gaps %llu, IR ctl 0x%08x, IT ctl 0x%08x",
        inSample, statPackets, statEmpty, statLate, statResync, irCtl, itCtl);
    if (cfg.nIn > 1)
        LOG("IR1: %{public}s, frame lag %lld, anchors %llu",
            synced[1] ? "anchored" : "NOT anchored", int64_t(inSample) - int64_t(frameS[1]), statResyncS[1]);
    if (levelLog) {
        char line[400]; uint32_t n = 0;
        for (uint32_t c = 0; c < inChannels && c < 64 && n + 16 < sizeof(line); c++) {
            // peak in tenths of a percent of full scale
            n = putUInt(line, n, c + 1); line[n++] = ':';
            n = putUInt(line, n, uint32_t(peak[c] * 1000.0f + 0.5f));
            line[n++] = ' ';
            peak[c] = 0;
        }
        line[n] = 0;
        LOG("input peaks (per mille FS): %{public}s", line);
    }
}
