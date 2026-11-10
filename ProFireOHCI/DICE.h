//
//  Dice.h
//  TCAT DICE protocol on top of FWController.
//

#ifndef Dice_h
#define Dice_h

#include "FWController.h"

class Dice {
public:
    static constexpr int kMaxStreams = 4;
    struct StreamFmt { uint32_t audio = 0, midi = 0; char names[300] = {}; };

    bool probe(FWController *fw, uint16_t node);     // reads section table and stream formats
    void dump();                                      // log everything (stage 2a output)

    bool takeOwnership();
    void releaseOwnership();

    uint32_t currentRate();                           // Hz from CLOCK_SELECT
    bool setRate(uint32_t hz, bool force = false);    // waits for clock accepted + lock
    bool readStreamFormats();
    uint32_t clockCaps = 0;

    // Isochronous resources at the IRM (falls back to fixed channels if the IRM refuses).
    bool allocIso(uint32_t payloadBytes, int *channel, uint32_t *bandwidth);
    void freeIso(int channel, uint32_t bandwidth);

    bool setTxChannel(int i, int channel, int speed);
    bool setRxChannel(int i, int channel);
    bool enable(bool on);
    bool locked();

    // TCAT extended application space (EAP): router and stream configuration.
    bool readExt();
    void dumpRouter();
    void peek(uint32_t lo, uint32_t count);
    bool loadHostRouter();          // activate the stored host routing (EAP LD_ROUTER)
    bool eapCommand(uint32_t opcode);
    uint32_t ext[18] = {};
    bool haveExt = false;

    uint32_t numTx = 0, numRx = 0;
    StreamFmt tx[kMaxStreams], rx[kMaxStreams];
    uint16_t node = 0xFFFF;
    char nick[80] = {};

private:
    FWController *fw = nullptr;
    uint32_t sec[10] = {};
    uint32_t global() const;
    uint32_t txBase() const;
    uint32_t rxBase() const;
    uint32_t txSize = 0, rxSize = 0;
    bool owned = false;
    bool rd(uint32_t lo, uint32_t *v);
    bool wr(uint32_t lo, uint32_t v);
    void readString(uint32_t lo, uint32_t bytes, char *out, uint32_t outSize);
};

#endif /* Dice_h */
