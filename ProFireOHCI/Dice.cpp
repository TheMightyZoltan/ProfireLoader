//
//  Dice.cpp
//

#include "Dice.h"
#include "DiceRegs.h"
#include "OHCI.h"

using namespace dice;

static const char *rateName(uint32_t idx)
{
    static const char *n[] = {"32k", "44.1k", "48k", "88.2k", "96k", "176.4k", "192k",
                              "any-low", "any-mid", "any-high", "none"};
    return idx < 11 ? n[idx] : "?";
}
static const char *sourceName(uint32_t s)
{
    static const char *n[] = {"AES1", "AES2", "AES3", "AES4", "AES_ANY", "ADAT", "TDIF", "WordClock",
                              "ARX1", "ARX2", "ARX3", "ARX4", "Internal"};
    return s < SrcCount ? n[s] : "?";
}

bool Dice::rd(uint32_t lo, uint32_t *v) { return fw->readQuadlet(node, kAddrHi, lo, v); }
bool Dice::wr(uint32_t lo, uint32_t v)  { return fw->writeQuadlet(node, kAddrHi, lo, v); }

uint32_t Dice::global() const { return kBaseLo + sec[2 * Global] * 4; }
uint32_t Dice::txBase() const { return kBaseLo + sec[2 * Tx] * 4; }
uint32_t Dice::rxBase() const { return kBaseLo + sec[2 * Rx] * 4; }

// DICE strings: first character in the low byte of each quadlet.
void Dice::readString(uint32_t lo, uint32_t bytes, char *out, uint32_t outSize)
{
    uint32_t n = 0;
    for (uint32_t off = 0; off < bytes && n + 4 < outSize; off += 4) {
        uint32_t v = 0;
        if (!rd(lo + off, &v)) break;
        bool end = false;
        for (int b = 0; b < 4; b++) {
            char c = char((v >> (8 * b)) & 0xFF);
            if (!c) { end = true; break; }
            out[n++] = (c == '\\') ? '|' : c;
        }
        if (end) break;
    }
    // trim trailing separators
    while (n && out[n - 1] == '|') n--;
    out[n] = 0;
}

bool Dice::probe(FWController *f, uint16_t n)
{
    fw = f; node = n;
    for (int i = 0; i < 10; i++) if (!rd(kBaseLo + 4 * i, &sec[i])) return false;
    readString(global() + GlobalNickName, 64, nick, sizeof(nick));
    if (sec[2 * Global + 1] * 4 > GlobalClockCaps) rd(global() + GlobalClockCaps, &clockCaps);
    return readStreamFormats();
}

bool Dice::readStreamFormats()
{
    uint32_t v = 0;
    if (!rd(txBase() + StreamNumber, &numTx) || !rd(txBase() + StreamSize, &txSize)) return false;
    if (!rd(rxBase() + StreamNumber, &numRx) || !rd(rxBase() + StreamSize, &rxSize)) return false;
    if (numTx > kMaxStreams) numTx = kMaxStreams;
    if (numRx > kMaxStreams) numRx = kMaxStreams;
    for (uint32_t i = 0; i < numTx; i++) {
        uint32_t e = txBase() + StreamEntries + i * txSize * 4;
        rd(e + TxNumAudio, &tx[i].audio); rd(e + TxNumMIDI, &tx[i].midi);
        if (txSize * 4 >= TxNames + 256) readString(e + TxNames, 256, tx[i].names, sizeof(tx[i].names));
    }
    for (uint32_t i = 0; i < numRx; i++) {
        uint32_t e = rxBase() + StreamEntries + i * rxSize * 4;
        rd(e + RxNumAudio, &rx[i].audio); rd(e + RxNumMIDI, &rx[i].midi);
        if (rxSize * 4 >= RxNames + 256) readString(e + RxNames, 256, rx[i].names, sizeof(rx[i].names));
    }
    (void)v;
    return true;
}

void Dice::dump()
{
    uint32_t cs = 0, st = 0, rate = 0, ver = 0;
    rd(global() + GlobalClockSelect, &cs);
    rd(global() + GlobalStatus, &st);
    rd(global() + GlobalSampleRate, &rate);
    rd(global() + GlobalVersion, &ver);
    LOG("DICE \"%{public}s\" v%u.%u.%u.%u: clock %{public}s / %{public}s, %{public}s, measured %u Hz",
        nick, ver >> 24, (ver >> 16) & 0xFF, (ver >> 8) & 0xFF, ver & 0xFF,
        rateName((cs >> 8) & 0xFF), sourceName(cs & 0xFF), (st & kStatusLocked) ? "locked" : "NOT locked", rate);
    for (uint32_t i = 0; i < numTx; i++)
        LOG("  tx%u (to Mac): %u audio + %u MIDI: %{public}s", i, tx[i].audio, tx[i].midi, tx[i].names);
    for (uint32_t i = 0; i < numRx; i++)
        LOG("  rx%u (from Mac): %u audio + %u MIDI: %{public}s", i, rx[i].audio, rx[i].midi, rx[i].names);
}

bool Dice::takeOwnership()
{
    uint64_t mine = (uint64_t(fw->localNode) << 48) | fw->notifyIova();
    uint64_t old = 0;
    fw->allowPhysicalFrom(node & 0x3F);
    if (!fw->compareSwap64(node, kAddrHi, global() + GlobalOwnerHi, kOwnerNoOwner, mine, &old)) return false;
    if (old != kOwnerNoOwner && old != mine) {
        LOG("DICE owned by 0x%016llx (stale?), taking over", old);
        uint64_t old2 = 0;
        if (!fw->compareSwap64(node, kAddrHi, global() + GlobalOwnerHi, old, mine, &old2) || old2 != old) return false;
    }
    owned = true;
    fw->takeNotify();
    LOG("DICE ownership taken (notify -> 0x%04x:%08x)", fw->localNode, fw->notifyIova());
    return true;
}

void Dice::releaseOwnership()
{
    if (!owned) return;
    uint64_t mine = (uint64_t(fw->localNode) << 48) | fw->notifyIova(), old = 0;
    fw->compareSwap64(node, kAddrHi, global() + GlobalOwnerHi, mine, kOwnerNoOwner, &old);
    owned = false;
}

uint32_t Dice::currentRate()
{
    uint32_t cs = 0;
    if (!rd(global() + GlobalClockSelect, &cs)) return 0;
    uint32_t idx = (cs >> 8) & 0xFF;
    return idx < kRateCount ? kRates[idx] : 0;
}

bool Dice::locked()
{
    uint32_t st = 0;
    return rd(global() + GlobalStatus, &st) && (st & kStatusLocked);
}

bool Dice::setRate(uint32_t hz, bool force)
{
    uint32_t idx = 0;
    while (idx < kRateCount && kRates[idx] != hz) idx++;
    if (idx == kRateCount || !(clockCaps & (1u << idx))) { LOG("rate %u not supported", hz); return false; }
    uint32_t cs = 0;
    if (!rd(global() + GlobalClockSelect, &cs)) return false;
    // Linux snd-dice always re-selects the clock right after taking ownership: "the unit can return
    // invalid stream formats... selecting clock parameters have an effect for the unit to refine it".
    if (!force && ((cs >> 8) & 0xFF) == idx && locked()) return true;

    fw->takeNotify();
    uint32_t ncs = (cs & ~kRateMask) | (idx << kRateShift);
    if (!wr(global() + GlobalClockSelect, ncs)) return false;
    uint32_t got = 0;
    for (int i = 0; i < 100 && !(got & NotifyClockAccepted); i++) {
        IOSleep(10);
        fw->pollBusReset();
        got |= fw->takeNotify();
    }
    bool lockedNow = false;
    for (int i = 0; i < 50 && !lockedNow; i++) { lockedNow = locked(); if (!lockedNow) IOSleep(10); }
    LOG("clock -> %{public}s: notification 0x%08x%{public}s, %{public}s", rateName(idx), got,
        (got & NotifyClockAccepted) ? " (accepted)" : " (no CLOCK_ACCEPTED)", lockedNow ? "locked" : "NOT locked");
    readStreamFormats();
    return lockedNow;
}

bool Dice::allocIso(uint32_t payloadBytes, int *channel, uint32_t *bandwidth)
{
    static int fallbackNext = 1;
    uint32_t bw = 512 + 12 + ((payloadBytes + 3) & ~3u);     // S400 units + pessimistic overhead
    *bandwidth = 0;
    if (fw->irmPhy >= 0) {
        uint16_t irm = 0xFFC0 | uint16_t(fw->irmPhy);
        uint32_t cur = 0, old = 0;
        bool bwOK = false;
        for (int tries = 0; tries < 5 && !bwOK; tries++) {
            if (!fw->readQuadlet(irm, kAddrHi, ohci::CSRBandwidthAvailable, &cur)) break;
            if (cur < bw) { LOG("IRM: not enough bandwidth (%u < %u)", cur, bw); break; }
            if (!fw->compareSwap32(irm, kAddrHi, ohci::CSRBandwidthAvailable, cur, cur - bw, &old)) break;
            bwOK = (old == cur);
        }
        if (bwOK) {
            for (int reg = 0; reg < 2; reg++) {
                uint32_t lo = reg ? ohci::CSRChannelsAvailLo : ohci::CSRChannelsAvailHi;
                for (int tries = 0; tries < 5; tries++) {
                    if (!fw->readQuadlet(irm, kAddrHi, lo, &cur)) break;
                    // skip channel 31 (broadcast) and 0
                    uint32_t usable = cur & (reg ? 0xFFFFFFFFu : 0x7FFFFFFEu);
                    if (!usable) break;
                    int bit = 31 - __builtin_ctz(usable);              // bit 31 = channel 0
                    uint32_t mask = 1u << (31 - bit);
                    if (!fw->compareSwap32(irm, kAddrHi, lo, cur, cur & ~mask, &old)) break;
                    if (old == cur) {
                        *channel = bit + 32 * reg;
                        *bandwidth = bw;
                        LOG("IRM: allocated channel %d, %u bandwidth units", *channel, bw);
                        return true;
                    }
                }
            }
            fw->compareSwap32(irm, kAddrHi, ohci::CSRBandwidthAvailable, cur - bw, cur, &old);  // best effort undo
        }
    }
    *channel = fallbackNext++;
    if (fallbackNext > 30) fallbackNext = 1;
    LOG("IRM allocation unavailable, using channel %d without reservation", *channel);
    return true;
}

void Dice::freeIso(int channel, uint32_t bandwidth)
{
    if (fw->irmPhy < 0 || bandwidth == 0 || channel < 0) return;
    uint16_t irm = 0xFFC0 | uint16_t(fw->irmPhy);
    uint32_t cur = 0, old = 0;
    for (int tries = 0; tries < 5; tries++) {
        if (!fw->readQuadlet(irm, kAddrHi, ohci::CSRBandwidthAvailable, &cur)) break;
        if (fw->compareSwap32(irm, kAddrHi, ohci::CSRBandwidthAvailable, cur, cur + bandwidth, &old) && old == cur) break;
    }
    uint32_t lo = channel < 32 ? ohci::CSRChannelsAvailHi : ohci::CSRChannelsAvailLo;
    uint32_t mask = 1u << (31 - (channel & 31));
    for (int tries = 0; tries < 5; tries++) {
        if (!fw->readQuadlet(irm, kAddrHi, lo, &cur)) break;
        if (fw->compareSwap32(irm, kAddrHi, lo, cur, cur | mask, &old) && old == cur) break;
    }
}

bool Dice::setTxChannel(int i, int channel, int speed)
{
    uint32_t e = txBase() + StreamEntries + uint32_t(i) * txSize * 4;
    return wr(e + TxIsoChannel, uint32_t(channel)) && wr(e + TxSpeed, uint32_t(speed));
}

bool Dice::setRxChannel(int i, int channel)
{
    uint32_t e = rxBase() + StreamEntries + uint32_t(i) * rxSize * 4;
    return wr(e + RxIsoChannel, uint32_t(channel)) && wr(e + RxSeqStart, 0);
}

bool Dice::enable(bool on)
{
    return wr(global() + GlobalEnable, on ? 1 : 0);
}

// ---------------------------------------------------------------------------
// EAP router

static const char *blockName(uint32_t b, bool dst)
{
    switch (b) {
        case 0: return "AES";
        case 1: return "ADAT";
        case 2: return dst ? "MIX0" : "MIX";
        case 3: return dst ? "MIX1" : "?3";
        case 4: return "INS0";
        case 5: return "INS1";
        case 10: return "ARM";
        case 11: return dst ? "ATX0" : "ARX0";
        case 12: return dst ? "ATX1" : "ARX1";
        case 15: return "MUTE";
        default: return "?";
    }
}

bool Dice::readExt()
{
    haveExt = true;
    for (int i = 0; i < 18 && haveExt; i++) haveExt = rd(kExtBaseLo + 4 * i, &ext[i]);
    return haveExt;
}

static void appendRoute(char *line, uint32_t &n, uint32_t size, uint32_t e)
{
    uint32_t src = e & 0xFF, dst = (e >> 8) & 0xFF;
    const char *a = blockName(dst >> 4, true), *b = blockName(src >> 4, false);
    char tmp[40]; uint32_t k = 0;
    for (const char *p = a; *p; p++) tmp[k++] = *p;
    tmp[k++] = char('0' + (dst & 0xF) / 10); tmp[k++] = char('0' + (dst & 0xF) % 10);
    tmp[k++] = '<'; 
    for (const char *p = b; *p; p++) tmp[k++] = *p;
    tmp[k++] = char('0' + (src & 0xF) / 10); tmp[k++] = char('0' + (src & 0xF) % 10);
    tmp[k++] = ' ';
    for (uint32_t i = 0; i < k && n + 1 < size; i++) line[n++] = tmp[i];
    line[n] = 0;
}

void Dice::dumpRouter()
{
    if (!readExt()) { LOG("no EAP"); return; }
    static const char *names[] = {"caps", "cmd", "mixer", "peak", "router", "stream_config",
                                  "current_config", "standalone_config", "application"};
    for (int i = 0; i < 9; i++) LOG("EAP %{public}s @0x%x size %u", names[i], ext[2 * i] * 4, ext[2 * i + 1]);

    uint32_t caps[4] = {};
    for (int i = 0; i < 4; i++) rd(kExtBaseLo + ext[0] * 4 + 4 * i, &caps[i]);
    LOG("EAP caps router 0x%08x mixer 0x%08x general 0x%08x", caps[0], caps[1], caps[2]);

    struct { const char *what; uint32_t lo; } tables[] = {
        { "router (new)",        kExtBaseLo + ext[2 * 4] * 4 },
        { "current low router",  kExtBaseLo + ext[2 * 6] * 4 + 0x0000 },
        { "current mid router",  kExtBaseLo + ext[2 * 6] * 4 + 0x2000 },
    };
    for (auto &t : tables) {
        uint32_t n = 0;
        if (!rd(t.lo, &n)) { LOG("%{public}s: unreadable", t.what); continue; }
        LOG("%{public}s: %u entries", t.what, n);
        if (n > 128) n = 128;
        char line[400]; uint32_t len = 0; line[0] = 0;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t e = 0;
            rd(t.lo + 4 + 4 * i, &e);
            appendRoute(line, len, sizeof(line), e);
            if (len > 330) { LOG("  %{public}s", line); len = 0; line[0] = 0; }
        }
        if (len) LOG("  %{public}s", line);
    }
    // current low stream config: tx count, rx count, then per-stream (audio, midi, ac3, names...)
    uint32_t sc = kExtBaseLo + ext[2 * 6] * 4 + 0x1000, ntx = 0, nrx = 0;
    rd(sc, &ntx); rd(sc + 4, &nrx);
    LOG("current low stream config: %u tx, %u rx", ntx, nrx);
}

void Dice::peek(uint32_t lo, uint32_t count)
{
    for (uint32_t i = 0; i < count; i += 8) {
        uint32_t v[8] = {};
        for (uint32_t k = 0; k < 8; k++) rd(lo + 4 * (i + k), &v[k]);
        LOG("peek 0x%08x: %08x %08x %08x %08x %08x %08x %08x %08x", lo + 4 * i, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
    }
}

// EAP command section: [0] opcode (bit 31 = execute, cleared by the device when done), [1] return value.
bool Dice::eapCommand(uint32_t opcode)
{
    if (!haveExt && !readExt()) return false;
    uint32_t cmd = kExtBaseLo + ext[2 * 1] * 4;
    if (!wr(cmd, opcode | (1u << 31))) return false;
    for (int i = 0; i < 200; i++) {
        uint32_t v = 0;
        if (rd(cmd, &v) && !(v & (1u << 31))) {
            uint32_t ret = 0;
            rd(cmd + 4, &ret);
            LOG("EAP command 0x%08x done, return 0x%08x", opcode, ret);
            return ret == 0;
        }
        IOSleep(5);
    }
    LOG("EAP command 0x%08x timed out", opcode);
    return false;
}

// Copy the stored host routing for each rate mode into the EAP "new router" area and load it.
bool Dice::loadHostRouter()
{
    if (!haveExt && !readExt()) return false;
    uint32_t routerLo = kExtBaseLo + ext[2 * 4] * 4;
    uint32_t routerQuads = ext[2 * 4 + 1];
    uint32_t cur = kExtBaseLo + ext[2 * 6] * 4;
    static const struct { uint32_t off, flag; const char *name; } modes[] = {
        { 0x0000, 1u << 16, "low" }, { 0x2000, 1u << 17, "mid" }, { 0x4000, 1u << 18, "high" },
    };
    bool ok = true;
    for (auto &m : modes) {
        uint32_t n = 0;
        if (!rd(cur + m.off, &n) || n == 0 || n + 1 > routerQuads) { LOG("router %{public}s: %u entries, skipped", m.name, n); continue; }
        if (!wr(routerLo, n)) return false;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t e = 0;
            if (!rd(cur + m.off + 4 + 4 * i, &e) || !wr(routerLo + 4 + 4 * i, e)) return false;
        }
        bool r = eapCommand(0x0001 | m.flag);       // LD_ROUTER for this rate mode
        LOG("host router %{public}s (%u entries) %{public}s", m.name, n, r ? "loaded" : "FAILED");
        ok = ok && r;
    }

    // Stream config (which router slots feed which isochronous channels), like M-Audio's
    // WriteStreamConfig: copy each rate mode's stored config into the EAP area and LD_STRM_CFG.
    uint32_t scLo = kExtBaseLo + ext[2 * 5] * 4;
    uint32_t scQuads = ext[2 * 5 + 1];
    static const uint32_t scOff[3] = { 0x1000, 0x3000, 0x5000 };
    for (int m = 0; m < 3; m++) {
        uint32_t ntx = 0, nrx = 0;
        if (!rd(cur + scOff[m], &ntx) || !rd(cur + scOff[m] + 4, &nrx) || ntx > 8 || nrx > 8 || (ntx + nrx) == 0) {
            LOG("stream config %{public}s: tx %u rx %u, skipped", modes[m].name, ntx, nrx);
            continue;
        }
        bool copied = true;
        for (uint32_t i = 0; i < scQuads && copied; i++) {
            uint32_t v = 0;
            copied = rd(cur + scOff[m] + 4 * i, &v) && wr(scLo + 4 * i, v);
        }
        bool r = copied && eapCommand(0x0002 | modes[m].flag);   // LD_STRM_CFG
        LOG("host stream config %{public}s (%u tx / %u rx) %{public}s", modes[m].name, ntx, nrx, r ? "loaded" : "FAILED");
        ok = ok && r;
    }
    return ok;
}
