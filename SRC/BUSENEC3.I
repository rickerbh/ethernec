*********************************************************************************
* Bus access macros for ST/TT/Falcon Cartridge Port for register base hardware	*
* Version for Lyndon Amsdon's and mine NE2000 interface hardware for the	*
* Cartridge Port. This hardware supports only fast "newer" NE2000 (clone) cards	*
*										*
* Version to use only CP address line and avoids /UDS	(slower, arrgh!)	*
*										*
* This version supports only machines with 68020 processor or higher!		*
*										*
*	Copyright 2002 Mariusz Buras, Dr. Thomas Redelberger			*
*	Use it under the terms of the GNU General Public License		*
*	(See file COPYING.TXT)							*
*										*
* processor registers are used as follows:					*
*	d6.w:	will be used temporarily;  do not use it!			*
*	d7.w:	will be used temporarily;  do not use it!			*
*										*
*	a5:	will point to ROM3 at $FB0000;	do not change it!		*
*	a6:	will point to ROM4 at $FA0000;	do not change it!		*
*										*
*										*
* Tabsize 8, developed with DEVPAC assembler 2.0.				*
*										*
*********************************************************************************
* $Id: busenec3.i 1.1 2002/06/08 16:26:52 Thomas Exp Thomas $
*

*
* manifest constants
*

BUGGY_HW	EQU	1		; if defined enables code to handle buggy hardware

*
* hardware addresses
*

rom4		EQU	$00fa0000	; ROM4 base address
rom3		EQU	$00fb0000	; ROM3 base address

*
* macros
*

lockBUS		MACRO
		moveq	#-1,d0			; preset error code
		tas	DVS+lcl_irqlock		; check for race about Cartrige Port and
		bne	.doNothing		; if somebody owns the bus we quit
		ENDM


lockBUSWait	MACRO
* there should be a timeout based on _hz_200 (and then branch to .doNothing)

.lt1\@		tas	DVS+lcl_irqlock		; check for race about Cartrige Port and
		beq.b	.lc1\@			; if somebody owns the bus we *wait*

		bsr	_appl_yield		; wait
		bra.b	.lt1\@

.lc1\@						; proceed
		ENDM


unlockBUS	MACRO
		sf	DVS+lcl_irqlock		; let other tasks access Cartridge Port
		ENDM


unlockBUSWait	MACRO
		sf	DVS+lcl_irqlock		; let other tasks access Cartridge Port
		ENDM


RxBUS		EQUR	d6
RyBUS		EQUR	d7
RcBUS		EQUR	a5
RdBUS		EQUR	a6


ldBUSRegs	MACRO				; for faster access to hardware
		lea	rom3,RcBUS
		lea	rom4,RdBUS
		ENDM


*
* 68030 cache handling for the cartridge port.
*
* The EtherNEC data/register ports are decoded in the cartridge ROM window
* ($FA0000/$FB0000). ROM space is cacheable, so on a 68030 (TT, Falcon):
*
* 1) The DATA cache satisfies repeated reads of the fixed data-port address from
*    its first value -- the remote-DMA pointer never advances and every read
*    returns the same byte (observed on the TT as a constant $3e MAC). A data
*    cache hit ignores timing, so inter-access delay cannot help.
*
* 2) With the data cache off but the INSTRUCTION cache on, the tight read loop
*    still runs at cache-hit speed, and the exact timing of the back-to-back
*    data-port reads then depends on where the loop lands in the I-cache. On the
*    TT that margin decides whether the RTL8019 has presented the next byte in
*    time: two builds differing only in code alignment read the MAC correctly vs.
*    return junk. So there is a residual read-recovery sensitivity once the data
*    cache no longer masks it.
*
* Fix (two parts, both needed):
* - disable + clear the DATA cache around each cartridge access block, so reads
*   reach the bus at all (clearing is required: RAM writes made while the cache
*   is disabled do not update pre-existing lines, which would then be served
*   stale on re-enable -- seen as wrong data and 3-bomb crashes from stale stack
*   lines). The instruction cache is deliberately left on: disabling it makes
*   things worse (every ISA access then has instruction fetches interleaved).
* - pad each access with a recovery gap (RECOVER below), so first-access timing
*   does not depend on alignment luck.
*
* Call cacheOff at the top of an entry point *before* acquiring the bus and
* cacheOn after releasing it. This is the 68020+/030 bus variant, so movec is
* always legal here; the plain 68000 BUSENEC.I variant has no caches and needs
* none of this.
*
* cacheOff saves the caller's CACR on the stack; cacheOn restores it. The pair
* must bracket a region with balanced stack use, and d0 is clobbered (as in the
* proven HT2 test). Only the data cache is disabled (ED, bit 8) and cleared
* (CD, bit 11); the instruction cache stays on -- disabling it makes things
* worse on the TT (every ISA access then has instruction fetches interleaved).
*
cacheOff	MACRO
		movec	CACR,d0
		move.l	d0,-(sp)		; save caller's CACR
		bclr	#8,d0			; ED=0 : disable data cache
		bset	#11,d0			; CD=1 : clear data cache
		movec	d0,CACR
		ENDM

* cacheOn restores the CACR saved by cacheOff. Optional argument: scratch data
* register to use instead of d0 (for exit paths where d0 holds the return code).
cacheOn		MACRO
	IFEQ	NARG
		move.l	(sp)+,d0
		movec	d0,CACR			; restore caller's CACR
	ELSEIF
		move.l	(sp)+,\1
		movec	\1,CACR			; restore caller's CACR
	ENDC
		ENDM


*
* Per-access recovery pad.
*
* Even with the data cache off, whether the RTL8019 tolerates the ISA cycles
* depends on how closely they follow each other -- which back-to-back access
* macros and (on the first, uncached loop iteration) instruction-fetch
* interleaving decide. A first mis-timed /IOR wedges the chip's remote-DMA
* state machine and every subsequent read returns a constant. Pad after every
* access so the gap to the next one never depends on code alignment.
* NE_RECOVER = number of nops (~62ns each at 32MHz); default 4, override with
* vasm -DNE_RECOVER=<n>. 0 = no pad.
*
	IFND	NE_RECOVER
NE_RECOVER	EQU	4
	ENDC

RECOVER		MACRO
	IFNE	NE_RECOVER
		REPT	NE_RECOVER
		nop
		ENDR
	ENDC
		ENDM


*
* Writes ("write by reading" ROM3) carry the data on cartridge address lines
* A1-A8. On the TT the lines do not settle to the new value before the write
* strobe latches them: all-ones data lost bits, all-zero data picked up bits
* left over from the preceding (RAM fetch) bus cycle. Observed as every byte
* of a transmitted frame scrambled while the byte COUNT stayed exact, and as
* occasional single-bit register-write errors (CMD reading $23 after a $22
* write). Inter-access delay cannot help; the violation is at the start of
* the write cycle itself.
*
* Countermeasure: precondition the lines. Immediately before each ROM3 write,
* read the chip's command register via ROM4 with the data value in A1-A8
* (register select ignores A1-A8; reading CMD has no side effects). That
* settles the data lines to their final state, so the real write only flips
* the ROM3-select and register-select bits and the latch captures clean data.
* Still exactly one write pulse per byte. The preconditioning read's own value
* is discarded, so it needs no timing margin of its own.
*
* REGISTER writes are additionally issued TWICE: the first write's strobe may
* still mis-sample the register-select lines (A9-A13 / ROM3 select transition
* at the strobe -- seen as config writes landing nowhere: TXCR/RXCR not taking
* effect, leaving the chip in loopback/monitor after open). The second write
* targets the identical full address, so every line is already settled and it
* latches deterministically. All the driver's register sequences are idempotent
* under an immediate doubled write (verified per site: stop/start/page switch,
* DMA setup before any data transfer, TX trigger while TXP is ignored).
* The DATA PORT must never be double-written (each pulse is a DMA transfer):
* use putBUSD/putMore for it, which issue exactly one pulse.
*
putBUS		MACRO				; register write, doubled
		move.w	#(\2)<<8,RyBUS		; move ISA address to bits 8-15
		move.b	\1,RyBUS		; merge in data
		moveq	#0,RxBUS
		move.b	RyBUS,RxBUS		; isolate the data byte
		tst.b	0(RdBUS,RxBUS.w*2)	; precondition A1-A8 (reads CMD, harmless)
		tst.b	0(RcBUS,RyBUS.w*2)	; write by reading
		tst.b	0(RcBUS,RyBUS.w*2)	; and again: identical address, settled lines
		RECOVER
		ENDM


putBUSi		MACRO				; register write, immediate, doubled
		tst.b	((\1)&$ff)<<1(RdBUS)	; precondition A1-A8 (reads CMD, harmless)
		tst.b	((\2<<8)!(\1))<<1(RcBUS)	; write by reading
		tst.b	((\2<<8)!(\1))<<1(RcBUS)	; and again: identical address, settled lines
		RECOVER
		ENDM


putBUSD		MACRO				; DATA PORT write: exactly one pulse
		move.w	#(\2)<<8,RyBUS		; move ISA address to bits 8-15
		move.b	\1,RyBUS		; merge in data
		moveq	#0,RxBUS
		move.b	RyBUS,RxBUS		; isolate the data byte
		tst.b	0(RdBUS,RxBUS.w*2)	; precondition A1-A8 (reads CMD, harmless)
		tst.b	0(RcBUS,RyBUS.w*2)	; write by reading
		RECOVER
		ENDM


putMore		MACRO				; DATA PORT write: exactly one pulse
		move.b	\1,RyBUS		; merge in data
		moveq	#0,RxBUS
		move.b	RyBUS,RxBUS		; isolate the data byte
		tst.b	0(RdBUS,RxBUS.w*2)	; precondition A1-A8 (reads CMD, harmless)
		tst.b	0(RcBUS,RyBUS.w*2)	; write by reading
		RECOVER
		ENDM


getBUS		MACRO
		move.b	(\1)<<9(RdBUS),\2	; read from CP
		RECOVER
		ENDM


getMore		MACRO
		move.b	(\1)<<9(RdBUS),\2	; read from CP
		RECOVER
		ENDM

*
* macro to deselect an interface
*
deselBUS	MACRO
* empty as the cartridge port does not need deselecting
		ENDM



******** RAM2NE *****************************************************************
* This is a macro for speed
* put # of bytes in register arg2 to NE from location pointed to by arg1.
*
* in:	arg1	address register source address
*	arg2	data register (w) # of bytes to put; must not be d0!
*
* both registers plus d0 get destroyed.
* Assembler inst. REPT does not work inside a macro, we repeate explicitly
	
RAM2NE		MACRO
		ext.l	\2			; clear upper word
		subq.w	#2,\2			; first two puts are outside loop
		ble	.doNothing\@		; nothing to do?
		putBUSD	(\1)+,NE_DATAPORT
		putMore	(\1)+,NE_DATAPORT

* put the packet; optimized for speed, we do 8 bytes at once
		ror.l	#3,\2			; store remainder in upper word
		bra	.Rb1\@

.Rt1\@		putMore	(\1)+,NE_DATAPORT
		putMore	(\1)+,NE_DATAPORT
		putMore	(\1)+,NE_DATAPORT
		putMore	(\1)+,NE_DATAPORT
		putMore	(\1)+,NE_DATAPORT
		putMore	(\1)+,NE_DATAPORT
		putMore	(\1)+,NE_DATAPORT
		putMore	(\1)+,NE_DATAPORT
.Rb1\@		dbra	\2,.Rt1\@

		clr.w	\2			; prepare for remainder
		rol.l	#3,\2			; restore remainder bits
		bra	.Rb2\@

.Rt2\@		putMore	(\1)+,NE_DATAPORT	; put the remaining bytes
.Rb2\@		dbra	\2,.Rt2\@

.doNothing\@
		ENDM



******** NE2RAM *****************************************************************
* This is a macro for speed
* get # of bytes in register arg2 to RAM location pointed to by arg1.
*
* in:	arg1	address register destination address; MUST be even
*	arg2	data register (w) # of bytes to get; must not be d0!
*		MUST be even!
*
* both registers plus d0 get destroyed.
* Assembler inst. REPT does not work inside a macro, we repeate explicitly

NE2RAM		MACRO
		ext.l	\2			; clear upper word
		ble.b	.doNothing\@		; nothing to do?

* get the Packet; optimized for speed, we do 16 bytes at once.
		ror.l	#4,\2			; store remainder in upper word
		bra	.Nb1\@

		CNOP	2,4			; pin to addr%4==2: cartridge reads fail at %4==0 (hw-verified)
.Nt1\@		movep.l	NE_DATAPORT<<9(RdBUS),d0	; four bytes at once
		move.l	d0,(\1)+
		movep.l	NE_DATAPORT<<9(RdBUS),d0
		move.l	d0,(\1)+
		movep.l	NE_DATAPORT<<9(RdBUS),d0	; four bytes at once
		move.l	d0,(\1)+
		movep.l	NE_DATAPORT<<9(RdBUS),d0
		move.l	d0,(\1)+
.Nb1\@		dbra	\2,.Nt1\@

		clr.w	\2				; prepare for remainder
* rol.l #3 instead of #4 because we write a WORD at once not a byte
* thus the lowest significant bit (which shall be 0 anyway) is not used
		rol.l	#3,\2				; restore remainder bits
		bra	.Nb2\@

		CNOP	2,4			; pin to addr%4==2: cartridge reads fail at %4==0 (hw-verified)
.Nt2\@		movep.w	NE_DATAPORT<<9(RdBUS),d0
		move.w	d0,(\1)+
.Nb2\@		dbra	\2,.Nt2\@

.doNothing\@
		ENDM



*********************************************************************************

