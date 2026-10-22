// ns3fb - ReXGlue Recompiled Project
//
// Game-specific hooks go in this file. main.cpp is the entry point; see
// docs/TROUBLESHOOTING.md for the shape of a working patch.

#include <chrono>
#include <thread>

#include "generated/default/ns3fb_init.h"

#include "ns3fb_app.h"

// ---------------------------------------------------------------------------
// Patches applied on top of the recompiled game code.
//
// Nothing here yet: the hooks below are the two that MCX360 needed on day one
// and that almost every 360 title benefits from. Keep them, and add yours as
// the game reveals them (see docs/TROUBLESHOOTING.md).
// ---------------------------------------------------------------------------

// Direct3D's spin-wait step. Every loop that waits on the GPU (fences, ring
// buffer space) calls it between checks. On the console db16cyc actually paused
// the hardware thread; recompiled it does nothing, so a core spins at full
// power - which on a phone means thermal throttling within minutes. Sleep
// briefly instead; GPU progress is still noticed within a fraction of a ms.
//
// The address is title-specific. Find it with `rexglue analyze --scan-calls`
// once you know which function the sum of all waits lands in, or leave it out
// until the game demonstrably needs it.
#if 0
extern "C" REX_FUNC(sub_XXXXXXXX) {
  std::this_thread::sleep_for(std::chrono::microseconds(50));
  __imp__sub_XXXXXXXX(ctx, base);
}
#endif

// The Xbox 360 SDK's PIX named-event call is compiled into retail titles. It
// formats the event text on every call and then drops it unless a PIX capture
// registered a callback, which never happens here. Some titles call it tens of
// thousands of times per frame.
#if 0
extern "C" REX_FUNC(sub_YYYYYYYY) {
  const uint32_t pix_callbacks = REX_LOAD_U32(0x82000A04);
  if (!pix_callbacks || !REX_LOAD_U32(pix_callbacks)) {
    return;
  }
  __imp__sub_YYYYYYYY(ctx, base);
}
#endif

REX_DEFINE_APP(ns3fb, Ns3fbApp::Create)
