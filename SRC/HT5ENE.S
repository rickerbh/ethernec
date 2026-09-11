*********************************************************************************
* HT5ENE.S									*
*	EtherNEC/TT reliability self-test: quantify cartridge access errors	*
*	without touching the wire.						*
*	- register write/readback matrix: 3 write modes x bit patterns x reps	*
*	- remote-DMA loopback: pattern data written to and read back from the	*
*	  card's buffer RAM							*
*	Software Copyright 2026, GPL (see COPYING.TXT). Builds on Dr. Thomas	*
*	Redelberger's EtherNE package.						*
*********************************************************************************

		OPT	O+
		OPT	W-
		OPT	M+

		INCLUDE	UTI.I
		INCLUDE	BUS.I
		INCLUDE	8390.I

NPATT		EQU	12
NREPS		EQU	8		; per pattern -> 96 writes per mode
NDMA		EQU	64		; bytes per DMA loop pass
NDMAPASS	EQU	4

		SECTION	TEXT

myStart		move.l	4(sp),a0
		move.l	$18(a0),d0
		add.l	$1c(a0),d0
		add.l	#512,d0			; stack
		move.l	d0,sp
		sub.l	a0,d0
		move.l	d0,-(sp)
		move.l	a0,-(sp)
		clr	-(sp)
		move	#$4a,-(sp)		; Mshrink
		trap	#1
		lea	12(sp),sp

		PrS	.m1(pc)

		pea	test5(pc)
		move.w	#$26,-(sp)		; Supexec
		trap	#14
		addq.l	#6,sp

		PrS	.m2(pc)
		WaitKey

		clr	-(sp)
		trap	#1
		illegal

.m1		DC.B	$1b,"pEtherNEC/TT access reliability self-test",$1b,"q",13,10,0
.m2		DC.B	13,10,"done - press any key",13,10,0
		EVEN

*********************************************************************************

test5		cacheOff
		ldBUSRegs

* ---- reset + settle ----
		getBUS	NE_RESET,d1
		putBUSD	d1,NE_RESET
		move.l	#240000,d0		; generous settle (~60ms)
.t0		subq.l	#1,d0
		bne.b	.t0

		PrA	<"ISR after reset (expect 80): ">
		getBUS	EN0_ISR,d1
		PrB	d1
		PrS	crlf(pc)

* ---- minimal init ----
		putBUSi	$ff,EN0_ISR
		putBUSi	E8390_NODMA+E8390_PAGE0+E8390_STOP,E8390_CMD
		putBUSi	$48,EN0_DCFG
		moveq	#0,d1
		putBUS	d1,EN0_RCNTLO
		putBUS	d1,EN0_RCNTHI
		putBUSi	E8390_RXOFF,EN0_RXCR
		putBUSi	E8390_TXOFF,EN0_TXCR

* ---- register write/readback matrix on BNRY (page0, R/W) ----
* mode 1: raw single write (no precondition, no double)
		PrA	<"BNRY raw    errs: ">
		moveq	#0,d5			; error count
		lea	patterns(pc),a2
		moveq	#NPATT-1,d4
.m1t1		move.b	(a2)+,d3
		moveq	#NREPS-1,d2
.m1t2		move.w	#(EN0_BOUNDARY)<<8,RyBUS
		move.b	d3,RyBUS
		tst.b	0(RcBUS,RyBUS.w*2)	; raw write
		RECOVER
		PIN24
		getBUS	EN0_BOUNDARY,d1
		cmp.b	d3,d1
		beq.b	.m1c1
		addq.w	#1,d5
.m1c1		dbra	d2,.m1t2
		dbra	d4,.m1t1
		bsr	prErrs

* mode 2: preconditioned single write
		PrA	<"BNRY precond errs: ">
		moveq	#0,d5
		lea	patterns(pc),a2
		moveq	#NPATT-1,d4
.m2t1		move.b	(a2)+,d3
		moveq	#NREPS-1,d2
.m2t2		putBUSD	d3,EN0_BOUNDARY
		PIN24
		getBUS	EN0_BOUNDARY,d1
		cmp.b	d3,d1
		beq.b	.m2c1
		addq.w	#1,d5
.m2c1		dbra	d2,.m2t2
		dbra	d4,.m2t1
		bsr	prErrs

* mode 3: preconditioned double write
		PrA	<"BNRY dbl    errs: ">
		moveq	#0,d5
		lea	patterns(pc),a2
		moveq	#NPATT-1,d4
.m3t1		move.b	(a2)+,d3
		moveq	#NREPS-1,d2
.m3t2		putBUS	d3,EN0_BOUNDARY
		PIN24
		getBUS	EN0_BOUNDARY,d1
		cmp.b	d3,d1
		beq.b	.m3c1
		addq.w	#1,d5
.m3c1		dbra	d2,.m3t2
		dbra	d4,.m3t1
		bsr	prErrs

* ---- alternating-target writes, instrumented ----
* separate counters: d0 = page-switch failures (CMD readback, page-independent),
* d5 = register value failures. A failed switch is re-issued once so a value
* check that follows is meaningful.
		PrA	<"ALT sw/val errs: ">
		moveq	#0,d0			; switch errors
		moveq	#0,d5			; value errors
		lea	patterns(pc),a2
		moveq	#NPATT-1,d4
.a1t1		move.b	(a2)+,d3
		moveq	#NREPS-1,d2
.a1t2		putBUSi	E8390_NODMA+E8390_PAGE1+E8390_STOP,E8390_CMD
		PIN24
		getBUS	E8390_CMD,d1
		and.b	#$c0,d1
		cmp.b	#E8390_PAGE1,d1		; PS bits = 01 ?
		beq.b	.aok1
		addq.w	#1,d0
		putBUSi	E8390_NODMA+E8390_PAGE1+E8390_STOP,E8390_CMD	; retry once
.aok1		putBUS	d3,EN1_CURPAG
		PIN24
		getBUS	EN1_CURPAG,d1
		cmp.b	d3,d1
		beq.b	.aok2
		addq.w	#1,d5
.aok2		putBUSi	E8390_NODMA+E8390_PAGE0+E8390_STOP,E8390_CMD
		PIN24
		getBUS	E8390_CMD,d1
		and.b	#$c0,d1
		beq.b	.aok3			; PS bits = 00 ?
		addq.w	#1,d0
		putBUSi	E8390_NODMA+E8390_PAGE0+E8390_STOP,E8390_CMD	; retry once
.aok3		putBUS	d3,EN0_BOUNDARY
		PIN24
		getBUS	EN0_BOUNDARY,d1
		cmp.b	d3,d1
		beq.b	.aok4
		addq.w	#1,d5
.aok4		dbra	d2,.a1t2
		dbra	d4,.a1t1
		move	d0,-(sp)
		bsr	prntWord
		addq.l	#2,sp
		PrA	<"/">
		bsr	prErrs

* ---- remote-DMA loopback: write pattern to buffer RAM, read back ----
* ---- read discriminator: same loop, page 0 (PROM) vs page $40 (buffer) ------
* If page-0 read returns the MAC but page-$40 returns a constant, buffer-RAM
* remote-read is the problem. If BOTH are constant, this test's read loop/
* alignment is broken (not the driver). Chip fresh + stopped, like the probe.
		putBUSi	$ff,EN0_ISR

		PrA	<"page0 (MAC): ">
		moveq	#0,d4			; RSARHI = 0
		bsr	dmaRead
		bsr	dmaHead8

		PrA	<"page40 buf : ">
		moveq	#$40,d4			; RSARHI = $40
		bsr	dmaRead
		bsr	dmaHead8

* write page $40 then read it back
		moveq	#0,d4
		bsr	dmaFill
		moveq	#$40,d4
		bsr	dmaWrite
		PrA	<"page40 wrrd: ">
		bsr	dmaRead
		bsr	dmaHead8
		PrA	<"   wrote   : ">
		lea	srcBuf,a0
		bsr	head8raw
		bra	dmaDone

dmaHead8	lea	dstBuf,a0
head8raw	moveq	#7,d2
.hh		PrB	(a0)+
		PrA	<" ">
		dbra	d2,.hh
		PrS	crlf(pc)
		rts

dmaFill		lea	srcBuf,a0
		move.b	d4,d3
		mulu	#7,d3
		move	#NDMA-1,d2
.f1		move.b	d3,(a0)+
		add.b	#13,d3
		dbra	d2,.f1
		rts

dmaWrite	putBUSi	$ff,EN0_ISR
		move.b	d4,d6			; save page
		putBUSi	NDMA,EN0_RCNTLO
		moveq	#0,d1
		putBUS	d1,EN0_RCNTHI
		putBUS	d1,EN0_RSARLO
		putBUS	d6,EN0_RSARHI
		putBUSi	E8390_RWRITE+E8390_START,E8390_CMD
		lea	srcBuf,a0
		move	#NDMA,d2
		RAM2NE	a0,d2
		move.l	#100000,d3
.wd1		getBUS	EN0_ISR,d1
		btst	#6,d1
		bne.b	.wd2
		subq.l	#1,d3
		bne.b	.wd1
.wd2		putBUSi	ENISR_RDC,EN0_ISR
		rts

dmaRead		move.b	d4,d6
		putBUSi	NDMA,EN0_RCNTLO
		moveq	#0,d1
		putBUS	d1,EN0_RCNTHI
		putBUS	d1,EN0_RSARLO
		putBUS	d6,EN0_RSARHI
		putBUSi	E8390_RREAD+E8390_START,E8390_CMD
		lea	dstBuf,a0
		move	#NDMA-1,d2
		PIN24
.r1		getBUS	NE_DATAPORT,d1
		move.b	d1,(a0)+
		dbra	d2,.r1
		putBUSi	ENISR_RDC,EN0_ISR
		rts

dmaCmp		moveq	#0,d5
		lea	srcBuf,a0
		lea	dstBuf,a1
		move	#NDMA-1,d2
.c1		cmpm.b	(a0)+,(a1)+
		beq.b	.c2
		addq.w	#1,d5
.c2		dbra	d2,.c1
		rts

dmaDone
* dump first 16 readback bytes of the last pass for eyeballing
		PrA	<"last readback: ">
		lea	dstBuf,a0
		moveq	#15,d2
.d2t1		PrB	(a0)+
		PrA	<" ">
		dbra	d2,.d2t1
		PrS	crlf(pc)
		PrA	<"expected:      ">
		lea	srcBuf,a0
		moveq	#15,d2
.d2t2		PrB	(a0)+
		PrA	<" ">
		dbra	d2,.d2t2
		PrS	crlf(pc)

		putBUSi	E8390_NODMA+E8390_PAGE0+E8390_STOP,E8390_CMD
		cacheOn
		rts


prErrs		move	d5,-(sp)
		bsr	prntWord
		addq.l	#2,sp
		PrS	crlf(pc)
		rts

patterns	DC.B	$00,$ff,$55,$aa,$01,$02,$04,$08,$10,$20,$40,$47
crlf		DC.B	13,10,0
		EVEN

		INCLUDE	UTI.S

		SECTION	BSS
srcBuf		DS.B	NDMA
dstBuf		DS.B	NDMA

******** end of HT5ENE.S ********************************************************
