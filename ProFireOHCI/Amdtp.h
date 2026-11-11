//
//  Amdtp.h
//  IEC 61883-6 (AM824) isochronous streaming over OHCI IR/IT contexts.
//
//  Device -> Mac streams are received on IR contexts; Mac -> device streams are
//  transmitted on IT contexts by replaying the received packet sequence (same
//  data-block counts and SYT, shifted by a fixed transfer delay), which keeps
//  the outgoing streams locked to the device's media clock.
//

#ifndef Amdtp_h
#define Amdtp_h

#include "FWController.h"

class AmdtpEngine {
public:
    static constexpr int kMaxStreams = 4;
    static constexpr uint32_t kSlots = 256;          // packets per ring (32 ms)
    static constexpr uint32_t kSlotSize = 2048;      // bytes per packet slot

    struct StreamCfg { int ctx = -1; int channel = -1; uint32_t pcm = 0, midiSlots = 0; };
    struct Config {
        uint32_t rate = 48000;
        uint32_t sfc = 2;                // AM824 sampling frequency code
        int nIn = 0, nOut = 0;
        StreamCfg in[kMaxStreams];       // IR (device -> Mac)
        StreamCfg out[kMaxStreams];      // IT (Mac -> device)
        uint32_t transferDelayCycles = 48;
    };

    // Audio rings shared with Core Audio (interleaved float32), set by the driver.
    float   *inRing = nullptr;  uint32_t inChannels = 0;
    float   *outRing = nullptr; uint32_t outChannels = 0;
    uint32_t ringFrames = 0;

    // Zero timestamp callback (sample time, host time in mach ticks).
    void (*zts)(void *ctx, uint64_t sampleTime, uint64_t hostTime) = nullptr;
    void *ztsCtx = nullptr;

    // Self-test: sine on one output channel (0-based, -1 = off), input level logging.
    int  toneChannel = -1;
    bool levelLog = false;
    volatile bool outputSilent = false;   // keep-streaming mode with no app playing: send silence
    bool itCycleMatch = false;       // start IT with cycleMatch (off: start now, measure the start cycle)
    bool restartITRequested = false;
    int  rawDumps = 0;               // log raw contents of the next N data packets (stream 0)

    kern_return_t start(FWController *fw, const Config &cfg);
    void stop();
    void pump();                         // call every ~1 ms while running

    bool running() const { return active; }
    bool receiving() const { return gotFirst; }
    uint64_t sampleTime() const { return inSample; }

private:
    struct Ring { DmaBuf desc, data; };
    FWController *fw = nullptr;
    Config cfg;
    HostClock clock;
    Ring ir[kMaxStreams], it[kMaxStreams];
    bool active = false;

    // receive state
    uint32_t irRead[kMaxStreams] = {};
    bool     gotFirst = false;
    uint64_t lastAbs = 0;            // absolute cycle of the newest stream-0 packet
    uint64_t inSample = 0;
    int      layout = -1;            // 0: [hdr][payload][trailer], 1: [trailer][hdr][payload]

    // transmit state
    bool     itStarted = false;
    uint64_t itStartAbs = 0;         // absolute cycle transmitted by IT slot 0 (stream 0)
    uint64_t itStart[kMaxStreams] = {};  // per output stream: cycle of its slot 0 (measured)
    uint64_t itNextAbs = 0;          // next IT cycle not yet written
    uint32_t delay = 0;              // actual transfer delay in cycles
    uint8_t  dbc[kMaxStreams] = {};

    // host time mapping
    uint64_t refHost = 0;            // mach ticks at refCycle
    double   refCycle = 0;           // absolute cycle (fractional) at refHost

    // stats
    uint64_t statLate = 0, statEmpty = 0, statPackets = 0, statResync = 0, statLastLog = 0;
    uint64_t statMiss[kMaxStreams] = {}, statAhead[kMaxStreams] = {}, statBehind[kMaxStreams] = {}, statForced = 0;
    uint64_t statNbShort[kMaxStreams] = {};

    // SYT-based alignment of secondary receive streams to stream 0.
    struct SytHist { uint16_t syt; uint64_t cycle; uint64_t frame; };
    static constexpr int kHist = 64;
    SytHist hist[kHist] = {};
    int histPos = 0;
    bool synced[kMaxStreams] = {};
    uint64_t frameS[kMaxStreams] = {};
    uint64_t statResyncS[kMaxStreams] = {};
    void pumpSecondary(int s);
    static uint64_t sytTicks(uint16_t syt, uint64_t cycleAbs);
    bool impliedFrame(uint16_t syt, uint64_t cs, int64_t *frame);
    uint32_t disagree[kMaxStreams] = {};
    void writeInput(int s, const volatile uint32_t *payload, uint32_t dbs, uint32_t blocks, uint64_t firstFrame);
    float    peak[64] = {};
    double   tonePhase = 0;

    bool  allocRing(Ring &r, uint32_t descBytes);
    void  freeRing(Ring &r);
    void  programIR(int s);
    void  programIT(int s);
    bool  peekIR(int s, uint32_t *cycle16, const volatile uint32_t **payload, uint32_t *payloadBytes);
    void  releaseIR(int s);
    uint64_t unwrap(uint32_t cycle16, uint64_t near) const;
    uint64_t hostOfCycle(uint64_t absCycle) const;
    void  writeIT(int s, uint64_t absCycle, uint32_t blocks, uint16_t syt, uint64_t firstFrame);
    void  startIT(uint64_t firstIRAbs);
    void  logStats();
    void  checkITDead();
    void  beginIT(uint64_t firstIRAbs, uint64_t nowAbs);
    uint64_t measureITStart(int o, uint64_t near);
    bool  itDeadLogged = false;
};

#endif /* Amdtp_h */
