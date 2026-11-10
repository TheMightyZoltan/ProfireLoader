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
#include "Common.h"
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
    uint32_t delayCycles = 48;
    int  isoCh[2 * Dice::kMaxStreams] = {};
    uint32_t isoBw[2 * Dice::kMaxStreams] = {};
    float *testIn = nullptr, *testOut = nullptr;
};

// ---------------------------------------------------------------------------

static void ztsThunk(void *ctx, uint64_t sampleTime, uint64_t hostTime)
{
    auto *dev = static_cast<ProFireAudioDevice *>(ctx);
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

static void createAudioDevice(ProFireOHCI *self, ProFireOHCI_IVars *iv)
{
    Dice &d = iv->dice;
    uint32_t nTx = d.numTx < uint32_t(iv->fw.numIR) ? d.numTx : uint32_t(iv->fw.numIR);
    uint32_t nRx = d.numRx < uint32_t(iv->fw.numIT) ? d.numRx : uint32_t(iv->fw.numIT);
    iv->inCh = 0; iv->outCh = 0;
    for (uint32_t i = 0; i < nTx; i++) iv->inCh += d.tx[i].audio;
    for (uint32_t i = 0; i < nRx; i++) iv->outCh += d.rx[i].audio;
    iv->rate = d.currentRate() ? d.currentRate() : 48000;

    // Stable UID from the device GUID.
    char uid[48] = "ProFire2626-0000000000000000";
    FWController::RomInfo ri;
    if (iv->fw.readRomInfo(d.node, ri)) { hex32(uid + 12, ri.guidHi); hex32(uid + 20, ri.guidLo); uid[28] = 0; }

    auto dev = OSSharedPtr<ProFireAudioDevice>(OSTypeAlloc(ProFireAudioDevice), OSNoRetain);
    if (!dev || !dev->init(self, false, PFSTR(uid), PFSTR("ProFire 2626"),
                           PFSTR("M-Audio"), kRingFrames)) {
        LOG("audio device init failed");
        return;
    }
    dev->SetName(PFSTR("ProFire 2626"));
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
    dev->SetInputSafetyOffset(128);
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
        if (iv->device) iv->device->SetDeviceIsAlive(true);
        else createAudioDevice(self, iv);
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
    if (d.currentRate() != uint32_t(iv->rate) || !d.locked()) {
        if (!d.setRate(uint32_t(iv->rate))) LOG("warning: clock not locked at %u Hz", uint32_t(iv->rate));
    }
    d.readStreamFormats();

    uint32_t sfc = rateIndex(iv->rate);
    uint32_t syti = iv->rate > 96000 ? 32 : iv->rate > 48000 ? 16 : 8;
    AmdtpEngine::Config cfg;
    cfg.rate = uint32_t(iv->rate);
    cfg.sfc = sfc;
    cfg.transferDelayCycles = iv->delayCycles;
    cfg.nIn = int(d.numTx < uint32_t(iv->fw.numIR) ? d.numTx : uint32_t(iv->fw.numIR));
    cfg.nOut = int(d.numRx < uint32_t(iv->fw.numIT) ? d.numRx : uint32_t(iv->fw.numIT));

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
    ivars->restartPending = false;
    return startStreamingInternal(ivars);
}

kern_return_t ProFireOHCI::StopStreaming()
{
    stopStreamingInternal(ivars);
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
        findDice(this, iv);
        if (was && iv->diceFound) startStreamingInternal(iv);
    }
    uint64_t delta = uint64_t(kHousekeepingMs) * 1000000;
    iv->hkTimer->WakeAtTime(kIOTimerClockUptimeRaw, nowNs() + delta, delta / 4);
}

void IMPL(ProFireOHCI, PumpFired)
{
    auto *iv = ivars;
    iv->engine.pump();
    uint64_t delta = iv->engine.running() ? kPumpNs : 50000000;
    iv->pumpTimer->WakeAtTime(kIOTimerClockUptimeRaw, nowNs() + delta, delta / 8);
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

kern_return_t IMPL(ProFireOHCI, NewUserClient)
{
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
        default: return kIOReturnBadArgument;
    }
    for (const char *p = word; *p; p++) buf[n++] = *p;
    if (c == 'Y' || c == 'O' || c == 'A') {
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
        else if (hasNum && is("rate")) { self->ChangeRate(double(n)); }
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
    if (iv->hkTimer) { iv->hkTimer->Cancel(^{}); OSSafeReleaseNULL(iv->hkTimer); }
    if (iv->pumpTimer) { iv->pumpTimer->Cancel(^{}); OSSafeReleaseNULL(iv->pumpTimer); }
    OSSafeReleaseNULL(iv->hkAction);
    OSSafeReleaseNULL(iv->pumpAction);
    if (iv->device) { RemoveObject(iv->device.get()); iv->device.reset(); }
    if (iv->fwUp) iv->fw.stop();
    iv->fwUp = false;
    OSSafeReleaseNULL(iv->ioQueue);
    if (iv->pci) { iv->pci->Close(this, 0); OSSafeReleaseNULL(iv->pci); }
    return Stop(provider, SUPERDISPATCH);
}
