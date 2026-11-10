//
//  OHCI.h
//  IEEE 1394 Open Host Controller Interface 1.1 register map and bit fields.
//  Reference: 1394 OHCI 1.1 spec, Linux drivers/firewire/ohci.h.
//

#ifndef OHCI_h
#define OHCI_h

#include <stdint.h>

namespace ohci {

// ---- Registers (offsets into BAR0) ----
enum : uint32_t {
    Version               = 0x000,
    GUID_ROM              = 0x004,
    ATRetries             = 0x008,
    CSRReadData           = 0x00C,
    CSRCompareData        = 0x010,
    CSRControl            = 0x014,
    ConfigROMhdr          = 0x018,
    BusID                 = 0x01C,
    BusOptions            = 0x020,
    GUIDHi                = 0x024,
    GUIDLo                = 0x028,
    ConfigROMmap          = 0x034,
    PostedWriteAddressLo  = 0x038,
    PostedWriteAddressHi  = 0x03C,
    VendorID              = 0x040,
    HCControlSet          = 0x050,
    HCControlClear        = 0x054,
    SelfIDBuffer          = 0x064,
    SelfIDCount           = 0x068,
    IntEventSet           = 0x080,
    IntEventClear         = 0x084,
    IntMaskSet            = 0x088,
    IntMaskClear          = 0x08C,
    IsoXmitIntEventClear  = 0x094,
    IsoXmitIntMaskClear   = 0x09C,
    IsoRecvIntEventClear  = 0x0A4,
    IsoRecvIntMaskClear   = 0x0AC,
    FairnessControl       = 0x0DC,
    LinkControlSet        = 0x0E0,
    LinkControlClear      = 0x0E4,
    NodeID                = 0x0E8,
    PhyControl            = 0x0EC,
    IsochronousCycleTimer = 0x0F0,
    AsReqFilterHiSet      = 0x100,
    AsReqFilterHiClear    = 0x104,
    AsReqFilterLoSet      = 0x108,
    AsReqFilterLoClear    = 0x10C,
    PhyReqFilterHiSet     = 0x110,
    PhyReqFilterHiClear   = 0x114,
    PhyReqFilterLoSet     = 0x118,
    PhyReqFilterLoClear   = 0x11C,
    PhyUpperBound         = 0x120,

    // Asynchronous DMA context register blocks.
    // Each block: +0 ContextControlSet, +4 ContextControlClear, +0xC CommandPtr
    ATReqContextBase      = 0x180,
    ATRspContextBase      = 0x1A0,
    ARReqContextBase      = 0x1C0,
    ARRspContextBase      = 0x1E0,
};

enum : uint32_t {
    CtxControlSet   = 0x0,
    CtxControlClear = 0x4,
    CtxCommandPtr   = 0xC,
};

// ---- HCControl ----
enum : uint32_t {
    HCControl_BIBimageValid     = 1u << 31,
    HCControl_noByteSwapData    = 1u << 30,
    HCControl_ackTardyEnable    = 1u << 29,
    HCControl_programPhyEnable  = 1u << 23,
    HCControl_aPhyEnhanceEnable = 1u << 22,
    HCControl_LPS               = 1u << 19,
    HCControl_postedWriteEnable = 1u << 18,
    HCControl_linkEnable        = 1u << 17,
    HCControl_softReset         = 1u << 16,
};

// ---- IntEvent / IntMask ----
enum : uint32_t {
    Int_reqTxComplete      = 1u << 0,
    Int_respTxComplete     = 1u << 1,
    Int_ARRQ               = 1u << 2,
    Int_ARRS               = 1u << 3,
    Int_RQPkt              = 1u << 4,
    Int_RSPkt              = 1u << 5,
    Int_isochTx            = 1u << 6,
    Int_isochRx            = 1u << 7,
    Int_postedWriteErr     = 1u << 8,
    Int_lockRespErr        = 1u << 9,
    Int_selfIDComplete2    = 1u << 15,
    Int_selfIDComplete     = 1u << 16,
    Int_busReset           = 1u << 17,
    Int_regAccessFail      = 1u << 18,
    Int_phy                = 1u << 19,
    Int_cycleSynch         = 1u << 20,
    Int_cycle64Seconds     = 1u << 21,
    Int_cycleLost          = 1u << 22,
    Int_cycleInconsistent  = 1u << 23,
    Int_unrecoverableError = 1u << 24,
    Int_cycleTooLong       = 1u << 25,
    Int_phyRegRcvd         = 1u << 26,
    Int_ackTardy           = 1u << 27,
    Int_masterIntEnable    = 1u << 31,
};

// ---- LinkControl ----
enum : uint32_t {
    LinkControl_rcvSelfID        = 1u << 9,
    LinkControl_rcvPhyPkt        = 1u << 10,
    LinkControl_cycleTimerEnable = 1u << 20,
    LinkControl_cycleMaster      = 1u << 21,
    LinkControl_cycleSource      = 1u << 22,
};

// ---- NodeID ----
enum : uint32_t {
    NodeID_idValid = 1u << 31,
    NodeID_root    = 1u << 30,
    NodeID_cps     = 1u << 27,
};

// ---- PhyControl ----
enum : uint32_t {
    PhyControl_rdDone = 1u << 31,
    PhyControl_rdReg  = 1u << 15,
    PhyControl_wrReg  = 1u << 14,
};

// ---- SelfIDCount ----
enum : uint32_t {
    SelfIDCount_error = 1u << 31,
};

// ---- ContextControl ----
enum : uint32_t {
    Ctx_run    = 1u << 15,
    Ctx_wake   = 1u << 12,
    Ctx_dead   = 1u << 11,
    Ctx_active = 1u << 10,
};

// ---- DMA descriptor control field (upper 16 bits of descriptor quadlet 0) ----
enum : uint16_t {
    Desc_OUTPUT_MORE   = 0 << 12,
    Desc_OUTPUT_LAST   = 1 << 12,
    Desc_INPUT_MORE    = 2 << 12,
    Desc_INPUT_LAST    = 3 << 12,
    Desc_STATUS        = 1 << 11,
    Desc_KEY_IMMEDIATE = 2 << 8,
    Desc_PING          = 1 << 7,
    Desc_YY            = 1 << 6,
    Desc_IRQ_ERROR     = 1 << 4,
    Desc_IRQ_ALWAYS    = 3 << 4,
    Desc_BRANCH_ALWAYS = 3 << 2,
    Desc_WAIT          = 3 << 0,
};

// OHCI DMA descriptor, little-endian, 16 bytes.
struct Descriptor {
    uint16_t reqCount;
    uint16_t control;
    uint32_t dataAddress;
    uint32_t branchAddress;
    uint16_t resCount;
    uint16_t transferStatus;
};
static_assert(sizeof(Descriptor) == 16, "OHCI descriptor must be 16 bytes");

// ---- 1394 transaction codes ----
enum : uint32_t {
    TCode_WriteQuadletRequest = 0x0,
    TCode_WriteBlockRequest   = 0x1,
    TCode_WriteResponse       = 0x2,
    TCode_ReadQuadletRequest  = 0x4,
    TCode_ReadBlockRequest    = 0x5,
    TCode_ReadQuadletResponse = 0x6,
    TCode_ReadBlockResponse   = 0x7,
    TCode_CycleStart          = 0x8,
    TCode_LockRequest         = 0x9,
    TCode_StreamData          = 0xA,
    TCode_LockResponse        = 0xB,
    TCode_LinkInternal        = 0xE,
};

// ---- Event / ack codes found in transferStatus[4:0] ----
enum : uint32_t {
    Evt_NoStatus     = 0x00,
    Evt_LongPacket   = 0x02,
    Evt_MissingAck   = 0x03,
    Evt_Underrun     = 0x04,
    Evt_Overrun      = 0x05,
    Evt_DescriptorRead = 0x06,
    Evt_DataRead     = 0x07,
    Evt_DataWrite    = 0x08,
    Evt_BusReset     = 0x09,
    Evt_Timeout      = 0x0A,
    Evt_TCodeErr     = 0x0B,
    Evt_Unknown      = 0x0E,
    Evt_Flushed      = 0x0F,
    Ack_Complete     = 0x11,
    Ack_Pending      = 0x12,
    Ack_BusyX        = 0x14,
    Ack_BusyA        = 0x15,
    Ack_BusyB        = 0x16,
    Ack_Tardy        = 0x1B,
    Ack_DataError    = 0x1D,
    Ack_TypeError    = 0x1E,
};

// ---- 1394 response codes ----
enum : uint32_t {
    RCode_Complete     = 0x0,
    RCode_ConflictErr  = 0x4,
    RCode_DataErr      = 0x5,
    RCode_TypeErr      = 0x6,
    RCode_AddressErr   = 0x7,
};

// CSR / config ROM addresses (48-bit, split into hi16 + lo32).
static constexpr uint16_t CSRRegisterSpaceHi = 0xFFFF;
static constexpr uint32_t CSRConfigROMLo     = 0xF0000400;

} // namespace ohci

#endif /* OHCI_h */
