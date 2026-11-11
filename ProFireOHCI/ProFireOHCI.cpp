//
//  ProFireOHCI.cpp
//  M-Audio ProFire 2626 sound card: OHCI 1394 + TCAT DICE + AMDTP + AudioDriverKit.
//
//  Logs:  /usr/bin/log stream --predicate 'eventMessage BEGINSWITH "ProFireOHCI: "'
//  Developer commands (tools/pfctl):  restart | tone | stop | dump
//

#include <stdlib.h>
#include <_abort.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/OSAction.h>
#include <DriverKit/OSString.h>
#include <DriverKit/OSDictionary.h>
#include <AudioDriverKit/AudioDriverKit.h>
#include <PCIDriverKit/PCIDriverKit.h>

#include "ProFireOHCI.h"
#include "ProFireAudioDevice.h"
#include <DriverKit/IOUserClient.h>
#include "Common.h"
#include "OHCI.h"
#include "FWController.h"
#include "Dice.h"
#include "DiceRegs.h"
#include "Amdtp.h"

static constexpr uint32_t kRingFrames      = 4096;    // == zero timestamp period
static constexpr uint32_t kHousekeepingMs  = 20;
static constexpr uint32_t kPumpNs          = 1000000; // 1 ms
static constexpr uint32_t kTransferDelay   = 48;      // cycles (6 ms) from received to transmitted packet

struct ProFireOHCI_IVars {
    IOPCIDevice *pci = nullptr;
    FWController fw;
    Dice dice;
    AmdtpEngine engine;
    bool fwUp = false;
    bool diceFound = false;
    uint32_t lastGen = 0xFFFFFFFF;

    IODispatchQueue *ioQueue = nullptr;
    IOTimerDispatchSource *hkTimer = nullptr, *pumpTimer = nullptr;
    OSAction *hkAction = nullptr, *pumpAction = nullptr;

    OSSharedPtr<ProFireAudioDevice> device;
    OSSharedPtr<IOUserAudioStream> inStream, outStream;
    OSSharedPtr<IOBufferMemoryDescriptor> inBuf, outBuf;
    float *inRing = nullptr, *outRing = nullptr;
    uint32_t inCh = 0, outCh = 0;
    double rate = 48000;

    bool streaming = false;
    bool restartPending = false;
    // Keep-streaming mode: the stream runs whenever a ProFire is found (silence while no app
    // plays), so apps join a running stream: no start-up transient, steady power LED.
    bool keepStreaming = true;
    bool ioActive = false;              // Core Audio IO running (some app is using the device)
    uint64_t keepRetryNs = 0;
    uint32_t delayCycles = 48;
    bool routerLoaded = false;
    bool noOut = false;
    int  isoCh[2 * Dice::kMaxStreams] = {};
    uint32_t isoBw[2 * Dice::kMaxStreams] = {};
    float *testIn = nullptr, *testOut = nullptr;
};

// ---------------------------------------------------------------------------

static bool gZtsLog = false;
static uint64_t gLastZtsSample = 0, gLastZtsHost = 0;

static void ztsThunk(void *ctx, uint64_t sampleTime, uint64_t hostTime)
{
    auto *dev = static_cast<ProFireAudioDevice *>(ctx);
    if (gZtsLog && gLastZtsHost) {
        int64_t dh = int64_t(hostTime - gLastZtsHost);
        LOG("zts sample %llu host %llu: +%lld frames, +%lld ticks (ideal %lld at 24 MHz), now-host %lld",
            sampleTime, hostTime, int64_t(sampleTime - gLastZtsSample), dh,
            int64_t(sampleTime - gLastZtsSample) * 24000000ll / 48000ll, int64_t(mach_absolute_time() - hostTime));
    }
    gLastZtsSample = sampleTime; gLastZtsHost = hostTime;
    if (dev) dev->UpdateCurrentZeroTimestamp(sampleTime, hostTime);
}

static uint32_t rateIndex(double r)
{
    for (uint32_t i = 0; i < dice::kRateCount; i++) if (uint32_t(r) == dice::kRates[i]) return i;
    return 2;
}

static OSSharedPtr<OSString> makeString(const char *s)
{
    return OSSharedPtr<OSString>(OSString::withCString(s), OSNoRetain);
}
// A temporary OSString that lives until the end of the full expression.
struct TmpStr { OSSharedPtr<OSString> p; explicit TmpStr(const char *s) : p(makeString(s)) {} operator OSString *() { return p.get(); } };
#define PFSTR(x) (TmpStr(x))

static void hex32(char *out, uint32_t v)
{
    static const char *h = "0123456789abcdef";
    for (int i = 0; i < 8; i++) out[i] = h[(v >> (28 - 4 * i)) & 0xF];
}

static IOUserAudioStreamBasicDescription pcmFormat(double rate, uint32_t ch)
{
    IOUserAudioStreamBasicDescription f = {};
    f.mSampleRate = rate;
    f.mFormatID = IOUserAudioFormatID::LinearPCM;
    f.mFormatFlags = IOUserAudioFormatFlags(FormatFlagIsFloat | FormatFlagIsPacked);
    f.mBytesPerPacket = 4 * ch;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * ch;
    f.mChannelsPerFrame = ch;
    f.mBitsPerChannel = 32;
    return f;
}

// Name each channel from the DICE "a|b|c" name list.
static void nameChannels(ProFireAudioDevice *dev, IOUserAudioObjectPropertyScope scope,
                         const Dice::StreamFmt *fmts, uint32_t n, uint32_t total)
{
    uint32_t ch = 1;
    for (uint32_t s = 0; s < n; s++) {
        const char *p = fmts[s].names;
        for (uint32_t k = 0; k < fmts[s].audio && ch <= total; k++, ch++) {
            char name[64]; uint32_t len = 0;
            while (*p == ' ') p++;
            while (*p && *p != '|' && len + 1 < sizeof(name)) name[len++] = *p++;
            while (len && name[len - 1] == ' ') len--;
            if (*p == '|') p++;
            name[len] = 0;
            if (len) dev->SetElementName(ch, scope, PFSTR(name));
        }
    }
}

// ---------------------------------------------------------------------------
// Device discovery and Core Audio device
// ---------------------------------------------------------------------------

/// Core Audio name: "ProFire 2626", plus the device nickname once the user has set one.
static void deviceName(ProFireOHCI_IVars *iv, char *out, size_t cap)
{
    const char *n = iv->dice.nick;
    bool custom = n[0] && strcmp(n, "FW2626") != 0;
    snprintf(out, cap, custom ? "ProFire 2626 (%s)" : "ProFire 2626", n);
}

static void createAudioDevice(ProFireOHCI *self, ProFireOHCI_IVars *iv)
{
    Dice &d = iv->dice;
    uint32_t nTx = d.numTx < uint32_t(iv->fw.numIR) ? d.numTx : uint32_t(iv->fw.numIR);
    uint32_t nRx = d.numRx < uint32_t(iv->fw.numIT) ? d.numRx : uint32_t(iv->fw.numIT);
    iv->inCh = 0; iv->outCh = 0;
    for (uint32_t i = 0; i < nTx; i++) iv->inCh += d.tx[i].audio;
    for (uint32_t i = 0; i < nRx; i++) iv->outCh += d.rx[i].audio;
    iv->rate = d.currentRate() ? d.currentRate() : 48000;

    // Stable UID: device GUID + this FireWire controller's GUID. ProFires can share a GUID
    // (seen: two units both 000d6c0404000002), and Core Audio drops a second device with the same UID.
    char uid[64] = "ProFire2626-0000000000000000-0000000000000000";
    FWController::RomInfo ri;
    if (iv->fw.readRomInfo(d.node, ri)) { hex32(uid + 12, ri.guidHi); hex32(uid + 20, ri.guidLo); }
    hex32(uid + 29, iv->fw.rd(ohci::GUIDHi)); hex32(uid + 37, iv->fw.rd(ohci::GUIDLo)); uid[45] = 0;
    char name[96]; deviceName(iv, name, sizeof(name));

    auto dev = OSSharedPtr<ProFireAudioDevice>(OSTypeAlloc(ProFireAudioDevice), OSNoRetain);
    if (!dev || !dev->init(self, false, PFSTR(uid), PFSTR("ProFire 2626"),
                           PFSTR("M-Audio"), kRingFrames)) {
        LOG("audio device init failed");
        return;
    }
    dev->SetName(PFSTR(name));
    dev->SetTransportType(IOUserAudioTransportType::FireWire);

    double rates[dice::kRateCount]; uint32_t nr = 0;
    IOUserAudioStreamBasicDescription inFmts[dice::kRateCount], outFmts[dice::kRateCount];
    for (uint32_t i = 0; i < 5; i++) {              // 32k .. 96k (176.4/192 need dual-wire handling)
        if (!(d.clockCaps & (1u << i)) || dice::kRates[i] < 44100) continue;
        rates[nr] = dice::kRates[i];
        inFmts[nr] = pcmFormat(rates[nr], iv->inCh);
        outFmts[nr] = pcmFormat(rates[nr], iv->outCh);
        nr++;
    }
    dev->SetAvailableSampleRates(rates, nr);
    dev->SetSampleRate(iv->rate);
    dev->SetCanBeDefaultInputDevice(true);
    dev->SetCanBeDefaultOutputDevice(true);
    dev->SetCanBeDefaultSystemOutputDevice(true);
    dev->SetInputSafetyOffset(256);
    dev->SetOutputSafetyOffset(64);
    dev->SetInputLatency(48);
    dev->SetOutputLatency(kTransferDelay * 6 + 48);
    dev->SetPreferredChannelsForStereo(1, 2);

    IOBufferMemoryDescriptor *ib = nullptr, *ob = nullptr;
    IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, kRingFrames * iv->inCh * 4, 0, &ib);
    IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, kRingFrames * iv->outCh * 4, 0, &ob);
    if (!ib || !ob) { LOG("ring buffer allocation failed"); OSSafeReleaseNULL(ib); OSSafeReleaseNULL(ob); return; }
    ib->SetLength(kRingFrames * iv->inCh * 4);
    ob->SetLength(kRingFrames * iv->outCh * 4);
    iv->inBuf = OSSharedPtr<IOBufferMemoryDescriptor>(ib, OSNoRetain);
    iv->outBuf = OSSharedPtr<IOBufferMemoryDescriptor>(ob, OSNoRetain);
    IOAddressSegment seg = {};
    iv->inBuf->GetAddressRange(&seg);  iv->inRing = reinterpret_cast<float *>(seg.address);
    iv->outBuf->GetAddressRange(&seg); iv->outRing = reinterpret_cast<float *>(seg.address);

    IOUserAudioStreamBasicDescription cur = pcmFormat(iv->rate, iv->inCh);
    iv->inStream = IOUserAudioStream::Create(self, IOUserAudioStreamDirection::Input, iv->inBuf.get());
    iv->inStream->SetName(PFSTR("ProFire 2626 In"));
    iv->inStream->SetAvailableStreamFormats(inFmts, nr);
    iv->inStream->SetCurrentStreamFormat(&cur);
    iv->inStream->SetTerminalType(IOUserAudioStreamTerminalType::Line);
    dev->AddStream(iv->inStream.get());

    cur = pcmFormat(iv->rate, iv->outCh);
    iv->outStream = IOUserAudioStream::Create(self, IOUserAudioStreamDirection::Output, iv->outBuf.get());
    iv->outStream->SetName(PFSTR("ProFire 2626 Out"));
    iv->outStream->SetAvailableStreamFormats(outFmts, nr);
    iv->outStream->SetCurrentStreamFormat(&cur);
    iv->outStream->SetTerminalType(IOUserAudioStreamTerminalType::Line);
    dev->AddStream(iv->outStream.get());

    nameChannels(dev.get(), IOUserAudioObjectPropertyScope::Input, d.tx, nTx, iv->inCh);
    nameChannels(dev.get(), IOUserAudioObjectPropertyScope::Output, d.rx, nRx, iv->outCh);

    kern_return_t ret = self->AddObject(dev.get());
    iv->device = dev;
    LOG("audio device \"ProFire 2626\" (%{public}s) published: %u in / %u out at %u Hz (AddObject 0x%x)",
        uid, iv->inCh, iv->outCh, uint32_t(iv->rate), ret);
}

static void findDice(ProFireOHCI *self, ProFireOHCI_IVars *iv)
{
    for (int i = 0; i < iv->fw.nRemote; i++) {
        uint16_t node = 0xFFC0 | iv->fw.remotePhy[i];
        FWController::RomInfo ri;
        if (!iv->fw.readRomInfo(node, ri)) continue;
        LOG("node 0x%04x: %{public}s %{public}s, GUID %08x%08x", node, ri.vendorName, ri.modelName, ri.guidHi, ri.guidLo);
        if ((ri.guidHi & 0xFF) != 0x04) continue;           // TCAT DICE category
        if (!iv->dice.probe(&iv->fw, node)) { LOG("DICE probe failed"); continue; }
        iv->dice.dump();
        iv->diceFound = true;
        if (iv->device) {
            iv->device->SetDeviceIsAlive(true);
            char name[96]; deviceName(iv, name, sizeof(name));
            iv->device->SetName(PFSTR(name));          // nickname may have changed
        } else createAudioDevice(self, iv);
        return;
    }
    if (iv->diceFound) LOG("ProFire no longer on the bus");
    iv->diceFound = false;
    if (iv->device) iv->device->SetDeviceIsAlive(false);
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

static void stopStreamingInternal(ProFireOHCI_IVars *iv)
{
    if (!iv->streaming) return;
    iv->streaming = false;
    iv->ioQueue->DispatchSync(^{ iv->engine.stop(); });
    Dice &d = iv->dice;
    if (iv->diceFound) {
        d.enable(false);
        for (uint32_t i = 0; i < d.numTx && i < uint32_t(Dice::kMaxStreams); i++) {
            d.setTxChannel(int(i), -1, 2);
            d.freeIso(iv->isoCh[i], iv->isoBw[i]);
        }
        for (uint32_t i = 0; i < d.numRx && i < uint32_t(Dice::kMaxStreams); i++) {
            d.setRxChannel(int(i), -1);
            d.freeIso(iv->isoCh[Dice::kMaxStreams + i], iv->isoBw[Dice::kMaxStreams + i]);
        }
        d.releaseOwnership();
    }
    LOG("streaming stopped");
}

static kern_return_t startStreamingInternal(ProFireOHCI_IVars *iv)
{
    if (iv->streaming) return kIOReturnSuccess;
    if (!iv->diceFound) { LOG("cannot start: ProFire not found"); return kIOReturnNoDevice; }
    Dice &d = iv->dice;
    if (!d.takeOwnership()) { LOG("cannot take DICE ownership"); return kIOReturnNotPermitted; }
    if (!d.setRate(uint32_t(iv->rate), true)) LOG("warning: clock not locked at %u Hz", uint32_t(iv->rate));
    d.readStreamFormats();
    if (!iv->routerLoaded) iv->routerLoaded = d.loadHostRouter();

    uint32_t sfc = rateIndex(iv->rate);
    uint32_t syti = iv->rate > 96000 ? 32 : iv->rate > 48000 ? 16 : 8;
    AmdtpEngine::Config cfg;
    cfg.rate = uint32_t(iv->rate);
    cfg.sfc = sfc;
    cfg.transferDelayCycles = iv->delayCycles;
    cfg.nIn = int(d.numTx < uint32_t(iv->fw.numIR) ? d.numTx : uint32_t(iv->fw.numIR));
    cfg.nOut = int(d.numRx < uint32_t(iv->fw.numIT) ? d.numRx : uint32_t(iv->fw.numIT));
    if (iv->noOut) cfg.nOut = 0;

    for (int i = 0; i < cfg.nIn; i++) {
        uint32_t midiSlots = (d.tx[i].midi + 7) / 8;
        int ch = -1; uint32_t bw = 0;
        d.allocIso(8 + syti * (d.tx[i].audio + midiSlots) * 4, &ch, &bw);
        iv->isoCh[i] = ch; iv->isoBw[i] = bw;
        d.setTxChannel(i, ch, 2);                              // S400
        cfg.in[i] = { i, ch, d.tx[i].audio, midiSlots };
    }
    for (int i = 0; i < cfg.nOut; i++) {
        uint32_t midiSlots = (d.rx[i].midi + 7) / 8;
        int ch = -1; uint32_t bw = 0;
        d.allocIso(8 + syti * (d.rx[i].audio + midiSlots) * 4, &ch, &bw);
        iv->isoCh[Dice::kMaxStreams + i] = ch; iv->isoBw[Dice::kMaxStreams + i] = bw;
        d.setRxChannel(i, ch);
        cfg.out[i] = { i, ch, d.rx[i].audio, midiSlots };
    }

    // Core Audio rings, or private ones for the self-test when no device exists yet.
    AmdtpEngine &e = iv->engine;
    uint32_t inCh = 0, outCh = 0;
    for (int i = 0; i < cfg.nIn; i++) inCh += cfg.in[i].pcm;
    for (int i = 0; i < cfg.nOut; i++) outCh += cfg.out[i].pcm;
    if (iv->inRing && iv->outRing) {
        e.inRing = iv->inRing; e.inChannels = iv->inCh;
        e.outRing = iv->outRing; e.outChannels = iv->outCh;
        bzero(iv->inRing, kRingFrames * iv->inCh * 4);
        bzero(iv->outRing, kRingFrames * iv->outCh * 4);
    } else {
        if (!iv->testIn) iv->testIn = static_cast<float *>(IOMallocZero(kRingFrames * 64 * 4));
        if (!iv->testOut) iv->testOut = static_cast<float *>(IOMallocZero(kRingFrames * 64 * 4));
        e.inRing = iv->testIn; e.inChannels = inCh;
        e.outRing = iv->testOut; e.outChannels = outCh;
    }
    e.ringFrames = kRingFrames;
    e.zts = iv->device ? ztsThunk : nullptr;
    e.ztsCtx = iv->device.get();

    e.outputSilent = !iv->ioActive;
    __block kern_return_t ret = kIOReturnSuccess;
    iv->ioQueue->DispatchSync(^{ ret = iv->engine.start(&iv->fw, cfg); });
    if (ret != kIOReturnSuccess) { LOG("engine start failed 0x%x", ret); d.releaseOwnership(); return ret; }
    iv->streaming = true;

    d.enable(true);
    bool rx = false;
    for (int i = 0; i < 100 && !rx; i++) { IOSleep(5); rx = e.receiving(); }
    LOG("streaming %{public}s: %d in streams / %d out streams at %u Hz",
        rx ? "started" : "enabled but NO packets received yet", cfg.nIn, cfg.nOut, cfg.rate);
    return kIOReturnSuccess;
}

kern_return_t ProFireOHCI::StartStreaming()
{
    auto *iv = ivars;
    iv->restartPending = false;
    iv->ioActive = true;
    if (iv->streaming) {
        // Already running (keep-streaming): start from a clean output ring, then play the app.
        if (iv->outRing) bzero(iv->outRing, kRingFrames * iv->outCh * 4);
        iv->engine.outputSilent = false;
        LOG("app joined the running stream");
        return kIOReturnSuccess;
    }
    kern_return_t r = startStreamingInternal(iv);
    if (r != kIOReturnSuccess) iv->ioActive = false;
    return r;
}

kern_return_t ProFireOHCI::StopStreaming()
{
    auto *iv = ivars;
    iv->ioActive = false;
    if (iv->keepStreaming && iv->streaming) {
        iv->engine.outputSilent = true;
        LOG("last app stopped: stream keeps running (silence)");
        return kIOReturnSuccess;
    }
    stopStreamingInternal(iv);
    return kIOReturnSuccess;
}

kern_return_t ProFireOHCI::ChangeRate(double rate)
{
    auto *iv = ivars;
    bool was = iv->streaming;
    stopStreamingInternal(iv);
    iv->rate = rate;
    if (iv->diceFound && iv->dice.takeOwnership()) {
        iv->dice.setRate(uint32_t(rate));
        iv->dice.releaseOwnership();
    }
    if (iv->inStream)  iv->inStream->DeviceSampleRateChanged(rate);
    if (iv->outStream) iv->outStream->DeviceSampleRateChanged(rate);
    if (was) startStreamingInternal(iv);
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------------------
// Timers
// ---------------------------------------------------------------------------

void IMPL(ProFireOHCI, HousekeepingFired)
{
    auto *iv = ivars;
    if (!iv->fwUp) return;
    if (!iv->fw.present()) {
        LOG("controller vanished (dock unplugged?)");
        iv->fwUp = false;
        if (iv->device) iv->device->SetDeviceIsAlive(false);
        return;
    }
    if (iv->fw.pollBusReset() && iv->fw.generation != iv->lastGen) {
        iv->lastGen = iv->fw.generation;
        bool was = iv->streaming;
        if (was) { LOG("bus reset while streaming, restarting streams"); stopStreamingInternal(iv); }
        bool wasThere = iv->diceFound;
        findDice(this, iv);
        // A plain bus reset keeps the DICE's router; only a power cycle (device gone and back)
        // drops it back to standalone routing.
        if (!wasThere || !iv->diceFound) iv->routerLoaded = false;
        if (was && iv->diceFound) startStreamingInternal(iv);
    }
    // Keep-streaming: start (and after a failure, retry every 5 s) once the ProFire is there.
    if (iv->keepStreaming && iv->diceFound && iv->device && !iv->streaming && nowNs() >= iv->keepRetryNs) {
        LOG("keep-streaming: starting stream");
        if (startStreamingInternal(iv) != kIOReturnSuccess) iv->keepRetryNs = nowNs() + 5000000000ull;
    }
    uint64_t delta = uint64_t(kHousekeepingMs) * 1000000;
    if (iv->hkTimer) iv->hkTimer->WakeAtTime(kIOTimerClockUptimeRaw, nowNs() + delta, delta / 4);
}

void IMPL(ProFireOHCI, PumpFired)
{
    auto *iv = ivars;
    iv->engine.pump();
    uint64_t delta = iv->engine.running() ? kPumpNs : 50000000;
    if (iv->pumpTimer) iv->pumpTimer->WakeAtTime(kIOTimerClockUptimeRaw, nowNs() + delta, delta / 8);
}

// ---------------------------------------------------------------------------
// Developer commands
// ---------------------------------------------------------------------------

static kern_return_t handleCommand(ProFireOHCI *self, ProFireOHCI_IVars *iv, const char *c);

kern_return_t IMPL(ProFireOHCI, SetProperties)
{
    OSString *cmd = OSDynamicCast(OSString, properties->getObject("ProFireCommand"));
    if (!cmd) return kIOReturnUnsupported;
    return handleCommand(this, ivars, cmd->getCStringNoCopy());
}

// ---------------------------------------------------------------------------
// Control panel access
// ---------------------------------------------------------------------------

void ProFireOHCI::ControlInfo(uint64_t *info, uint32_t count)
{
    auto *iv = ivars;
    uint64_t v[8] = { iv->diceFound ? 1u : 0u, iv->dice.node, uint64_t(iv->rate), iv->streaming ? 1u : 0u,
                      0, iv->keepStreaming ? 1u : 0u, iv->ioActive ? 1u : 0u,                 // [5] keep, [6] app IO
                      uint64_t(iv->fw.rd(ohci::GUIDHi)) << 32 | iv->fw.rd(ohci::GUIDLo) };   // [7] controller GUID
    if (iv->diceFound) v[4] = iv->dice.locked() ? 1 : 0;
    for (uint32_t i = 0; i < count && i < 8; i++) info[i] = v[i];
}

kern_return_t ProFireOHCI::ControlRead(uint32_t lo, uint8_t *buf, uint32_t bytes)
{
    auto *iv = ivars;
    if (!iv->diceFound) return kIOReturnNoDevice;
    if (bytes == 4) {
        uint32_t v = 0;
        if (!iv->fw.readQuadlet(iv->dice.node, 0xFFFF, lo, &v)) return kIOReturnIOError;
        buf[0] = uint8_t(v >> 24); buf[1] = uint8_t(v >> 16); buf[2] = uint8_t(v >> 8); buf[3] = uint8_t(v);
        return kIOReturnSuccess;
    }
    if (iv->fw.readBlock(iv->dice.node, 0xFFFF, lo, buf, bytes)) return kIOReturnSuccess;
    // Some DICE regions (e.g. the EAP mixer) don't answer block reads: fall back to quadlets.
    for (uint32_t off = 0; off < bytes; off += 4) {
        uint32_t v = 0;
        if (!iv->fw.readQuadlet(iv->dice.node, 0xFFFF, lo + off, &v)) return kIOReturnIOError;
        buf[off] = uint8_t(v >> 24); buf[off + 1] = uint8_t(v >> 16); buf[off + 2] = uint8_t(v >> 8); buf[off + 3] = uint8_t(v);
    }
    return kIOReturnSuccess;
}

kern_return_t ProFireOHCI::ControlWrite(uint32_t lo, const uint8_t *buf, uint32_t bytes)
{
    auto *iv = ivars;
    if (!iv->diceFound) return kIOReturnNoDevice;
    if (bytes == 4) {
        uint32_t v = (uint32_t(buf[0]) << 24) | (uint32_t(buf[1]) << 16) | (uint32_t(buf[2]) << 8) | buf[3];
        return iv->fw.writeQuadlet(iv->dice.node, 0xFFFF, lo, v) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (iv->fw.writeBlock(iv->dice.node, 0xFFFF, lo, buf, bytes)) return kIOReturnSuccess;
    for (uint32_t off = 0; off < bytes; off += 4) {
        uint32_t v = (uint32_t(buf[off]) << 24) | (uint32_t(buf[off + 1]) << 16) | (uint32_t(buf[off + 2]) << 8) | buf[off + 3];
        if (!iv->fw.writeQuadlet(iv->dice.node, 0xFFFF, lo + off, v)) return kIOReturnIOError;
    }
    return kIOReturnSuccess;
}

bool ProFireOHCI::ControlEAP(uint32_t opcode)
{
    auto *iv = ivars;
    if (!iv->diceFound) return false;
    bool ok = iv->dice.eapCommand(opcode);
    // A router change from the panel is what the device should keep using after a restart.
    if (ok && (opcode & 0xFFFF) == 0x0001) iv->routerLoaded = true;
    return ok;
}

kern_return_t IMPL(ProFireOHCI, NewUserClient)
{
    if (type == 0xFD000000) {
        IOService *client = nullptr;
        kern_return_t r = Create(this, "ProFireUserClientProperties", &client);
        if (r != kIOReturnSuccess) { LOG("control client create failed 0x%x", r); return r; }
        *userClient = OSDynamicCast(IOUserClient, client);
        if (!*userClient) { client->release(); return kIOReturnError; }
        return kIOReturnSuccess;
    }
    if ((type >> 24) != 0xFE) return NewUserClient(type, userClient, SUPERDISPATCH);
    char c = char((type >> 16) & 0xFF);
    uint32_t arg = type & 0xFFFF;
    char buf[32] = {}; uint32_t n = 0;
    const char *word = nullptr;
    switch (c) {
        case 'R': word = "restart"; break;
        case 'T': word = "tone"; break;
        case 'S': word = "stop"; break;
        case 'D': word = "dump"; break;
        case 'L': word = "levels"; break;
        case 'N': word = "notone"; break;
        case 'Y': word = "delay"; break;
        case 'O': word = "tone"; break;
        case 'A': word = "rate"; arg *= 10; break;
        case 'P': word = "keep"; break;
        case 'I': word = "itrestart"; break;
        case 'Q': word = "itdiag"; break;
        case 'F': word = "forceroot"; break;
        case 'K': word = "unforceroot"; break;
        case 'W': word = "raw"; break;
        case 'J': word = "zts"; break;
        case 'G': word = "busreset"; break;
        case 'E': word = "reenable"; break;
        case 'Z': word = "noout"; break;
        case 'U': word = "router"; break;
        case 'H': word = "loadrouter"; break;
        case 'B': word = "peekb"; break;
        case 'X': word = "peekx"; break;
        case 'M': word = "itcm"; break;
        default: return kIOReturnBadArgument;
    }
    for (const char *p = word; *p; p++) buf[n++] = *p;
    if (c == 'P' || c == 'Y' || c == 'O' || c == 'A' || c == 'M' || c == 'B' || c == 'X' || c == 'Z') {
        buf[n++] = ' ';
        char tmp[12]; uint32_t k = 0, v = arg;
        do { tmp[k++] = char('0' + v % 10); v /= 10; } while (v);
        while (k) buf[n++] = tmp[--k];
    }
    buf[n] = 0;
    kern_return_t r = handleCommand(this, ivars, buf);
    *userClient = nullptr;
    return r == kIOReturnSuccess ? kIOReturnAborted : r;     // "handled, no connection"
}

static kern_return_t handleCommand(ProFireOHCI *self, ProFireOHCI_IVars *iv, const char *c)
{
    LOG("command: %{public}s", c);
    auto eq = [c](const char *w) { uint32_t i = 0; while (w[i] && c[i] == w[i]) i++; return !w[i] && !c[i]; };

    if (eq("restart")) {
        // Clean shutdown, then exit: DriverKit relaunches the newest installed version.
        stopStreamingInternal(iv);
        if (iv->fwUp) iv->fw.stop();
        iv->fwUp = false;
        LOG("exiting for restart");
        IOSleep(50);
        abort();
    } else if (eq("tone")) {
        iv->engine.toneChannel = 7;      // output 8
        iv->engine.levelLog = true;
        return startStreamingInternal(iv);
    } else if (eq("stop")) {
        iv->engine.toneChannel = -1;
        iv->engine.levelLog = false;
        stopStreamingInternal(iv);
    } else if (eq("dump")) {
        if (iv->diceFound) iv->dice.dump();
    } else if (eq("levels")) {
        iv->engine.levelLog = !iv->engine.levelLog;
    } else if (eq("notone")) {
        iv->engine.toneChannel = -1;
    } else if (eq("loadrouter")) {
        if (iv->diceFound) iv->routerLoaded = iv->dice.loadHostRouter();
    } else if (eq("router")) {
        if (iv->diceFound) iv->dice.dumpRouter();
    } else if (eq("reenable")) {
        if (iv->diceFound) { iv->dice.enable(false); IOSleep(50); iv->dice.enable(true); LOG("DICE enable toggled"); }
    } else if (eq("forceroot")) {
        iv->fw.forceRoot(true); LOG("forcing local root");
    } else if (eq("unforceroot")) {
        iv->fw.forceRoot(false); LOG("releasing local root");
    } else if (eq("busreset")) {
        iv->fw.forceBusReset();
    } else if (eq("zts")) {
        gZtsLog = !gZtsLog;
    } else if (eq("itdiag")) {
        using namespace ohci;
        uint32_t c1 = iv->fw.cycleTimer(); IOSleep(3); uint32_t c2 = iv->fw.cycleTimer();
        LOG("itdiag: cycle timer %u.%u -> %u.%u, LinkControl 0x%08x, HCControl 0x%08x, NodeID 0x%08x, IsoXmitEvent 0x%08x",
            c1 >> 25, (c1 >> 12) & 0x1FFF, c2 >> 25, (c2 >> 12) & 0x1FFF, iv->fw.rd(LinkControlSet), iv->fw.rd(HCControlSet),
            iv->fw.rd(NodeID), iv->fw.rd(IsoXmitIntEventSet));
        for (uint32_t n = 0; n < 8; n++)
            LOG("itdiag: IT%u ctl 0x%08x cmd 0x%08x", n, iv->fw.rd(ITContextBase + 16 * n + CtxControlSet), iv->fw.rd(ITContextBase + 16 * n + CtxCommandPtr));
    } else if (eq("raw")) {
        iv->engine.rawDumps = 3;
    } else if (eq("itrestart")) {
        iv->engine.restartITRequested = true;
    } else {
        // "<word> <number>" commands
        uint32_t n = 0; const char *p = c;
        while (*p && *p != ' ') p++;
        const char *num = p; while (*num == ' ') num++;
        bool hasNum = *num >= '0' && *num <= '9';
        for (const char *q = num; *q >= '0' && *q <= '9'; q++) n = n * 10 + uint32_t(*q - '0');
        uint32_t wl = uint32_t(p - c);
        auto is = [&](const char *w) { uint32_t i = 0; while (w[i] && i < wl && w[i] == c[i]) i++; return !w[i] && i == wl; };
        if (hasNum && is("delay")) { iv->delayCycles = n; LOG("transfer delay -> %u cycles (applies on next start)", n); }
        else if (hasNum && is("tone")) { iv->engine.toneChannel = int(n) - 1; LOG("tone -> output %u", n); }
        else if (hasNum && is("peekb") && iv->diceFound) iv->dice.peek(dice::kBaseLo + n * 4, 16);
        else if (hasNum && is("peekx") && iv->diceFound) iv->dice.peek(dice::kExtBaseLo + n * 4, 16);
        else if (hasNum && is("noout")) { iv->noOut = n != 0; LOG("noout %u (applies on next start)", n); }
        else if (hasNum && is("itcm")) { iv->engine.itCycleMatch = n != 0; LOG("IT cycle match %{public}s", n ? "on" : "off"); }
        else if (hasNum && is("rate")) { self->ChangeRate(double(n)); }
        else if (hasNum && is("keep")) {
            iv->keepStreaming = n != 0;
            LOG("keep-streaming %{public}s", iv->keepStreaming ? "on" : "off");
            if (!iv->keepStreaming && iv->streaming && !iv->ioActive) stopStreamingInternal(iv);
            iv->keepRetryNs = 0;
        }
        else return kIOReturnUnsupported;
    }
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------------------
// IOService
// ---------------------------------------------------------------------------

bool ProFireOHCI::init()
{
    if (!super::init()) return false;
    ivars = new ProFireOHCI_IVars();
    return ivars != nullptr;
}

void ProFireOHCI::free()
{
    if (ivars) {
        if (ivars->testIn) IOFree(ivars->testIn, kRingFrames * 64 * 4);
        if (ivars->testOut) IOFree(ivars->testOut, kRingFrames * 64 * 4);
        delete ivars;
        ivars = nullptr;
    }
    super::free();
}

kern_return_t IMPL(ProFireOHCI, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) { LOG("IOUserAudioDriver::Start failed 0x%x", ret); return ret; }
    auto *iv = ivars;

    iv->pci = OSDynamicCast(IOPCIDevice, provider);
    if (!iv->pci) return kIOReturnNoDevice;
    iv->pci->retain();
    if ((ret = iv->pci->Open(this, 0)) != kIOReturnSuccess) { LOG("PCI open failed 0x%x", ret); return ret; }
    uint16_t cmd = 0;
    iv->pci->ConfigurationRead16(kIOPCIConfigurationOffsetCommand, &cmd);
    iv->pci->ConfigurationWrite16(kIOPCIConfigurationOffsetCommand, cmd | kIOPCICommandMemorySpace | kIOPCICommandBusMaster);

    SetName(PFSTR("ProFire 2626 Driver"));

    if ((ret = IODispatchQueue::Create("IO", 0, 0, &iv->ioQueue)) != kIOReturnSuccess) return ret;
    if ((ret = SetDispatchQueue("IO", iv->ioQueue)) != kIOReturnSuccess) { LOG("SetDispatchQueue failed 0x%x", ret); return ret; }

    if ((ret = iv->fw.start(iv->pci)) != kIOReturnSuccess) { LOG("controller start failed 0x%x", ret); return ret; }
    iv->fwUp = true;

    IODispatchQueue *defq = nullptr;
    CopyDispatchQueue(kIOServiceDefaultQueueName, &defq);
    IOTimerDispatchSource::Create(defq, &iv->hkTimer);
    OSSafeReleaseNULL(defq);
    CreateActionHousekeepingFired(0, &iv->hkAction);
    iv->hkTimer->SetHandler(iv->hkAction);
    IOTimerDispatchSource::Create(iv->ioQueue, &iv->pumpTimer);
    CreateActionPumpFired(0, &iv->pumpAction);
    iv->pumpTimer->SetHandler(iv->pumpAction);

    uint64_t t = nowNs();
    iv->hkTimer->WakeAtTime(kIOTimerClockUptimeRaw, t + 20000000, 5000000);
    iv->pumpTimer->WakeAtTime(kIOTimerClockUptimeRaw, t + 50000000, 5000000);

    RegisterService();
    LOG("started (ProFire audio driver)");
    return kIOReturnSuccess;
}

kern_return_t IMPL(ProFireOHCI, Stop)
{
    auto *iv = ivars;
    LOG("stopping");
    stopStreamingInternal(iv);
    // Release timers and actions only from the cancel handlers (avoids use-after-release).
    if (iv->hkTimer) {
        IOTimerDispatchSource *t = iv->hkTimer; OSAction *a = iv->hkAction;
        iv->hkTimer = nullptr; iv->hkAction = nullptr;
        t->Cancel(^{ t->release(); if (a) a->release(); });
    }
    if (iv->pumpTimer) {
        IOTimerDispatchSource *t = iv->pumpTimer; OSAction *a = iv->pumpAction;
        iv->pumpTimer = nullptr; iv->pumpAction = nullptr;
        t->Cancel(^{ t->release(); if (a) a->release(); });
    }
    if (iv->device) { RemoveObject(iv->device.get()); iv->device.reset(); }
    if (iv->fwUp) iv->fw.stop();
    iv->fwUp = false;
    OSSafeReleaseNULL(iv->ioQueue);
    if (iv->pci) { iv->pci->Close(this, 0); OSSafeReleaseNULL(iv->pci); }
    return Stop(provider, SUPERDISPATCH);
}
