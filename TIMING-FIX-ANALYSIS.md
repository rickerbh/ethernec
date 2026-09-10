# EtherNEC / NetUSBee timing fix — analysis

Working notes on why the STinG EtherNEC driver (`ENEC.STX` / `ENEC3.STX`) fails on the
Atari TT while the AssemSoft NE2000 driver works on the same hardware, and whether a
software fix is possible.

Source under analysis: the EtherNE(A/C) driver by Dr. **Thomas Redelberger** (ThR) and
Lyndon Amsdon (ROM-port hardware). Note: the "Dr Richard" driver referred to on the
forum is this one — the author is Thomas Redelberger, not "Richard".

Reference: exxosforum thread 780 (Stephen Usher, 2018).

---

## 1. Hardware / software stack

```
NetUSBee (RTL8019AS, NE2000-compatible)  ─IDE-40 ribbon─  ROM/cartridge-port adapter
        │                                                          │
   ISA /IOR //IOW  ◄── decoded from ROM3/ROM4 address strobes ─────┘
        │
   Atari cartridge port ($FA0000 = ROM4, $FB0000 = ROM3)
```

The cartridge port is **read-only** and has **no interrupt line**. The adapter fakes ISA
I/O cycles out of ROM address strobes:

- **Reading** ISA register `N`  → CPU reads byte at `ROM4 + (N<<9)` (`$FA0000` base).
  The ROM4 access strobe is decoded into ISA `/IOR`.
- **Writing** ISA register `N` with value `V` → CPU *reads* address
  `ROM3 + (((N<<8)|V)<<1)` (`$FB0000` base). The ROM3 strobe is decoded into ISA `/IOW`
  and the low address lines carry the data. **"Writing" is simulated by reading** — there
  is no write cycle on the cartridge port at all.

Because everything is a ROM read, the *width* of the resulting ISA `/IOR` // `/IOW` pulse
and the *spacing* between consecutive pulses are set entirely by the CPU/bus cycle timing
of the host machine. This is the crux of the whole problem.

Driver operates in **polling** mode (no IRQ line) — STinG calls the driver from its
timeslice; the driver reads the 8390 ISR register to discover RX/TX events.

---

## 2. Code map (SRC/)

| File | Lang | Role |
|------|------|------|
| `ENESTNG.C` | Turbo-C 2.0 | STinG glue: `install`, port struct, ARP, `my_send`/`my_receive`. Module entry point. |
| `NESTNG.S`  | DEVPAC asm | `rtrvPckt` / `rtrvStngDgram` — pull packet from card straight into a STinG datagram. |
| `NE.S`      | DEVPAC asm | Generic 8390/NE2000 core (from Linux `ne.c`/`8390.c`): probe, open/close, xmit, the polled "interrupt" handler, receive, reset. |
| `8390.I`    | asm inc    | DP8390 register + bit definitions. |
| `BUS.I`     | asm inc    | **Bus-access macros** — copied over from one of `BUSENE*.I` at build time. This is the hardware-specific layer. |
| `BUSENEC.I` | asm inc    | Cartridge-port bus macros, **68000** (uses `add.w`+`tst.b` addressing trick). → `ENEC.STX` |
| `BUSENEC3.I`| asm inc    | Cartridge-port bus macros, **68020+** (uses scaled index `*2`; 68030 variant emits raw opcode). → `ENEC3.STX` |
| `UTI.S/.I`  | asm        | Debug print + stack helpers. |
| `NETDEV.I`  | asm inc    | `struct device` (DVS) layout. |

Build (original): DEVPAC 2.0 assembles the `.S`; Turbo-C 2.0 compiles `ENESTNG.C`;
TLINK links them into a headerless TOS PRG renamed `.STX`, which `STING.PRG` loads.

The C↔asm boundary uses the **Turbo-C/Pure-C register calling convention** (args in
`d0/d1/a0/a1`), *not* the standard stack convention. This matters for the build tooling
(see §6).

---

## 3. The bus-access macros (the timing-critical code)

`BUSENEC.I` (68000 build):

```asm
getBUS  MACRO
        move.b  (\1)<<9(RdBUS),\2      ; RdBUS=a6=$FA0000 ; one ISA read = one move.b
        ENDM

putBUS  MACRO                          ; "write" = read of ROM3
        move.w  #(\2)<<8,RyBUS
        ...
        add.w   RyBUS,RyBUS
        tst.b   0(RcBUS,RyBUS.w)       ; RcBUS=a5=$FB0000 ; the "write" bus cycle
        ENDM
```

Bulk data uses `movep`:

```asm
NE2RAM: ...
        movep.l NE_DATAPORT<<9(RdBUS),d0   ; read 4 data-port bytes back-to-back
```

**There is no delay and no dummy/recovery cycle between accesses.** A register read is a
single `move.b`; the next access can begin on the very next bus cycle.

Compare Linux `ne.c`, the acknowledged source of this code, which uses `inb_p`/`outb_p`
— the **"pause" (`_p`) variants that insert a recovery delay** between I/O accesses. The
Atari port dropped the pauses and relies on the slow ST/Falcon bus to space accesses far
enough apart on its own. `ne_reset_8390` even warns:

```asm
* DON'T change these to inb_p/outb_p or reset will fail on clones
```

— i.e. the author was explicitly aware of paused I/O and deliberately omitted it.

---

## 4. Where delays *do* exist

Delays exist **only** around reset, driven by `ADelay` and a per-machine calibrated
`ticks2ms`:

- `ei_probe1` calibrates `ticks2ms` (busy-loop counts ≈ 2 ms) and waits ~2 ms after the
  reset strobe before reading the MAC PROM.
- `ne_reset_8390` waits `ticks2ms` after reset.
- `ei_rx_overrun` waits 2 ms (a genuine 8390 requirement).

**Every other chip access — every register read/write in xmit, receive, the polled ISR
scan, and the `movep` data loops — has no delay at all.**

---

## 5. Why it works on Falcon/ST but not TT

The RTL8019AS needs a minimum ISA read/write **recovery time** between consecutive I/O
accesses (and a minimum `/IOR`//`/IOW` pulse width). On an 8 MHz ST or a 16 MHz Falcon,
a ROM-space `move.b`/`movep` cycle is long enough — and the gap to the next one wide
enough — that the chip keeps up by luck of the slow bus.

The **TT runs the bus at ~32 MHz** (double the Falcon). ROM cycles and the gaps between
them shrink below what the RTL8019AS tolerates, so:

- Register reads latch **stale / not-yet-valid** data (e.g. the ISR read in the polled
  handler → the driver "sees" phantom RX events).
- `movep` back-to-back data reads run faster than the remote-DMA port can refill.
- Writes may not present a wide enough `/IOW`.

This matches Stephen Usher's 2018 findings exactly: after **only** increasing the
post-reset delay he got the **MAC address** read correctly (the PROM read is the one path
that already runs after a big delay), but **TX stayed broken** and he saw **"phantom
received packets when the hard disk is active"** — i.e. the un-delayed register/ISR path
was still being read too fast and returning garbage. He stopped there.

The AssemSoft driver works on the same TT + NetUSBee, which is strong evidence the
**hardware is capable** and the difference is purely in **software access timing** (the
AssemSoft driver almost certainly spaces its accesses — the equivalent of Linux's paused
I/O).

---

## 6. Verdict: is a software fix possible?

**Very likely yes.** The fix is to re-introduce a bounded **recovery delay between
consecutive chip accesses** (the paused-I/O the port dropped), specifically on the paths
that currently have none:

1. **Register access** (`getBUS`/`putBUS`/`getMore`/`putMore`, `putBUSi`) — add a short,
   tunable pad (a few dummy ROM reads / `nop`s, or a tiny calibrated spin) after each
   access. This is the path that produces the phantom ISR/RX reads and the broken xmit.
2. **Bulk data** (`NE2RAM`/`RAM2NE`) — the `movep` bursts can't be padded internally;
   on fast machines replace `movep` with spaced single `move.b` reads/writes (the
   `BUS.I`/Hades variant already uses single `move.b` loops and is a ready template).
3. Keep the existing reset delays; Usher already showed the reset path is fine.

Make the pad **tunable at build time** (and ideally auto-scaled off the `ticks2ms`
calibration already computed in `ei_probe1`) so we can dial it in against real hardware:
start generous (correctness first), then reduce for throughput.

**Residual risk (~30%).** Usher's "phantom packets *during disk activity*" *could*
instead point to cartridge-bus signal-integrity/EMI that timing can't fully cure. The
more likely reading is simply that his un-delayed ISR reads returned garbage; disk DMA
activity just changes bus timing enough to expose it. We won't know for certain until we
test padded register access on the real TT — which is exactly the loop the user can run.

The `ENEC3.STX` (68020+) build is the right base for the TT (the TT is 68030).

---

## 7. Not needed

- **No change to the STinG core** (this is entirely in the EtherNEC driver repo).
- **No migration to Pure C.** The timing-critical code *must* stay in assembler — you
  cannot control inter-access spacing reliably from C. Only the tooling question (how to
  build on Linux vs. under an emulator) touches the C↔asm ABI; see build notes.
