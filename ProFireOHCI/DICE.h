//
//  DICE.h
//  TC Applied Technologies DICE register layout (DICE II / Jr / Mini).
//  Reference: Linux sound/firewire/dice/dice-interface.h, FFADO dice_defines.h.
//
//  All addresses are in the 0xFFFF'E000'0000 private space of the device.
//  Section offsets and sizes in the section table are in quadlets.
//

#ifndef DICE_h
#define DICE_h

#include <stdint.h>

namespace dice {

static constexpr uint16_t kAddrHi       = 0xFFFF;
static constexpr uint32_t kBaseLo       = 0xE0000000;   // section table + sections
static constexpr uint32_t kExtBaseLo    = 0xE0200000;   // TCAT extended application space (DICE II/Jr/Mini)

// Section table: 5 x (offset, size), quadlets.
enum Section : int { Global = 0, Tx, Rx, ExtSync, Unused2, SectionCount };

// ---- Global section (byte offsets) ----
enum : uint32_t {
    GlobalOwnerHi          = 0x00,
    GlobalOwnerLo          = 0x04,
    GlobalNotification     = 0x08,
    GlobalNickName         = 0x0C,     // 64 bytes
    GlobalClockSelect      = 0x4C,
    GlobalEnable           = 0x50,
    GlobalStatus           = 0x54,
    GlobalExtendedStatus   = 0x58,
    GlobalSampleRate       = 0x5C,
    GlobalVersion          = 0x60,
    GlobalClockCaps        = 0x64,     // version >= 1.0.4
    GlobalClockSourceNames = 0x68,     // 256 bytes, version >= 1.0.4
};

static constexpr uint64_t kOwnerNoOwner = 0xFFFF000000000000ull;

// CLOCK_SELECT / STATUS fields
static constexpr uint32_t kRateShift    = 8;
static constexpr uint32_t kRateMask     = 0xFF00;
static constexpr uint32_t kSourceMask   = 0x00FF;
static constexpr uint32_t kStatusLocked = 1u << 0;

// Clock source indices (CLOCK_SELECT low byte; capability bit = 16 + index)
enum : uint32_t {
    SrcAES1 = 0, SrcAES2, SrcAES3, SrcAES4, SrcAESAny, SrcADAT, SrcTDIF, SrcWordClock,
    SrcARX1, SrcARX2, SrcARX3, SrcARX4, SrcInternal, SrcCount
};

// Rate indices (CLOCK_SELECT bits 15:8; capability bit = index)
static constexpr uint32_t kRates[] = { 32000, 44100, 48000, 88200, 96000, 176400, 192000 };
static constexpr uint32_t kRateCount = 7;

// NOTIFICATION bits (written by the device to the owner's notification address)
enum : uint32_t {
    NotifyRxCfgChange   = 1u << 0,
    NotifyTxCfgChange   = 1u << 1,
    NotifyDupIsoc       = 1u << 2,
    NotifyBWErr         = 1u << 3,
    NotifyLockChange    = 1u << 4,
    NotifyClockAccepted = 1u << 5,
    NotifyInterfaceChg  = 1u << 6,
};

// ---- TX / RX sections ----
enum : uint32_t {
    StreamNumber   = 0x00,   // number of streams
    StreamSize     = 0x04,   // quadlets per stream entry
    StreamEntries  = 0x08,
};
// TX stream entry (byte offsets)
enum : uint32_t {
    TxIsoChannel   = 0x00,
    TxNumAudio     = 0x04,
    TxNumMIDI      = 0x08,
    TxSpeed        = 0x0C,
    TxNames        = 0x10,   // 256 bytes
    TxAC3Caps      = 0x110,
    TxAC3Enable    = 0x114,
};
// RX stream entry (byte offsets)
enum : uint32_t {
    RxIsoChannel   = 0x00,
    RxSeqStart     = 0x04,
    RxNumAudio     = 0x08,
    RxNumMIDI      = 0x0C,
    RxNames        = 0x10,   // 256 bytes
    RxAC3Caps      = 0x110,
    RxAC3Enable    = 0x114,
};

// ---- EXT_SYNC section ----
enum : uint32_t {
    ExtSyncClockSource = 0x00,
    ExtSyncLocked      = 0x04,
    ExtSyncRate        = 0x08,
    ExtSyncADATUser    = 0x0C,
};

// ---- TCAT extended application space: section table of 9 x (offset, size) ----
enum ExtSection : int {
    ExtCaps = 0, ExtCmd, ExtMixer, ExtPeak, ExtRouter, ExtStreamConfig,
    ExtCurrentConfig, ExtStandaloneConfig, ExtApplication, ExtSectionCount
};

} // namespace dice

#endif /* DICE_h */
