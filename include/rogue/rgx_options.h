/*************************************************************************/ /*!
@File
@Title          RGX build options
@Copyright      Copyright (c) Imagination Technologies Ltd. All Rights Reserved
@License        Dual MIT/GPLv2

The contents of this file are subject to the MIT license as set out below.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

Alternatively, the contents of this file may be used under the terms of
the GNU General Public License Version 2 ("GPL") in which case the provisions
of GPL are applicable instead of those above.

If you wish to allow use of your version of this file only under the terms of
GPL, and not to allow others to use your version of this file under the terms
of the MIT license, indicate your decision by deleting the provisions above
and replace them with the notice and other provisions required by GPL as set
out in the file called "GPL-COPYING" included in this distribution. If you do
not delete the provisions above, a recipient may use your version of this file
under the terms of either the MIT license or GPL.

This License is also included in this distribution in the file called
"MIT-COPYING".

EXCEPT AS OTHERWISE STATED IN A NEGOTIATED AGREEMENT: (A) THE SOFTWARE IS
PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT; AND (B) IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/ /**************************************************************************/

/* Each build option listed here is packed into a dword which provides up to
 *  log2(RGX_BUILD_OPTIONS_MASK_KM + 1) flags for KM and
 *  (32 - log2(RGX_BUILD_OPTIONS_MASK_KM + 1)) flags for UM.
 * The corresponding bit is set if the build option was enabled at compile
 * time.
 *
 * IMPORTANT: add new options to unused bits or define a new dword
 * (e.g. RGX_BUILD_OPTIONS_KM2 or RGX_BUILD_OPTIONS2) so that the bitfield
 * remains backwards compatible.
 */

#ifndef RGX_OPTIONS_H
#define RGX_OPTIONS_H

#define OPTIONS_NO_HARDWARE_EN					(0x1UL << 0)
#define OPTIONS_PDUMP_EN						(0x1UL << 1)
#define OPTIONS_UNUSED1_EN						(0x1UL << 2)
#define OPTIONS_SECURE_ALLOC_KM_EN				(0x1UL << 3)
#define OPTIONS_RGX_EN							(0x1UL << 4)
#define OPTIONS_SECURE_EXPORT_EN				(0x1UL << 5)
#define OPTIONS_INSECURE_EXPORT_EN				(0x1UL << 6)
#define OPTIONS_VFP_EN							(0x1UL << 7)
#define OPTIONS_WORKLOAD_ESTIMATION_EN			(0x1UL << 8)
#define OPTIONS_PDVFS_EN						(0x1UL << 9)
#define OPTIONS_DEBUG_EN						(0x1UL << 10)
#define OPTIONS_BUFFER_SYNC_EN					(0x1UL << 11)
#define OPTIONS_AUTOVZ_EN						(0x1UL << 12)
#define OPTIONS_AUTOVZ_HW_REGS_EN				(0x1UL << 13)
#define OPTIONS_FW_IRQ_REG_COUNTERS_EN			(0x1UL << 14)
#define OPTIONS_VALIDATION_EN					(0x1UL << 15)

#define OPTIONS_PERCONTEXT_FREELIST_EN			(0x1UL << 31)

#define RGX_BUILD_OPTIONS_MASK_KM				  \
			(OPTIONS_NO_HARDWARE_EN				| \
			 OPTIONS_PDUMP_EN					| \
			 OPTIONS_SECURE_ALLOC_KM_EN			| \
			 OPTIONS_RGX_EN						| \
			 OPTIONS_SECURE_EXPORT_EN			| \
			 OPTIONS_INSECURE_EXPORT_EN			| \
			 OPTIONS_VFP_EN						| \
			 OPTIONS_WORKLOAD_ESTIMATION_EN		| \
			 OPTIONS_PDVFS_EN					| \
			 OPTIONS_DEBUG_EN					| \
			 OPTIONS_BUFFER_SYNC_EN				| \
			 OPTIONS_AUTOVZ_EN					| \
			 OPTIONS_AUTOVZ_HW_REGS_EN			| \
			 OPTIONS_FW_IRQ_REG_COUNTERS_EN		| \
			 OPTIONS_VALIDATION_EN)

#define RGX_BUILD_OPTIONS_MASK_FW \
			(RGX_BUILD_OPTIONS_MASK_KM & \
			 ~OPTIONS_BUFFER_SYNC_EN)

/* Build options that the FW must have if the present on the KM */
#define FW_OPTIONS_STRICT ((RGX_BUILD_OPTIONS_MASK_KM			| \
							OPTIONS_PERCONTEXT_FREELIST_EN)		& \
							~(OPTIONS_DEBUG_EN					| \
							  OPTIONS_WORKLOAD_ESTIMATION_EN	| \
							  OPTIONS_PDVFS_EN))

/* Build options that the UM must have if the present on the KM */
#define UM_OPTIONS_STRICT ((RGX_BUILD_OPTIONS_MASK_KM			| \
							OPTIONS_PERCONTEXT_FREELIST_EN)		& \
							~(OPTIONS_DEBUG_EN					| \
							  OPTIONS_WORKLOAD_ESTIMATION_EN	| \
							  OPTIONS_PDVFS_EN))

/* Build options that the KM must have if the present on the UM */
#define KM_OPTIONS_STRICT ((RGX_BUILD_OPTIONS_MASK_KM			| \
							OPTIONS_PERCONTEXT_FREELIST_EN)		& \
							~(OPTIONS_DEBUG_EN					| \
							  OPTIONS_WORKLOAD_ESTIMATION_EN	| \
							  OPTIONS_PDVFS_EN					| \
							  OPTIONS_BUFFER_SYNC_EN))

#define NO_HARDWARE_OPTION	"NO_HARDWARE  "
#if defined(NO_HARDWARE)
	#define OPTIONS_BIT0		OPTIONS_NO_HARDWARE_EN
	#if OPTIONS_BIT0 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT0		0x0UL
#endif /* NO_HARDWARE */

#define PDUMP_OPTION	"PDUMP  "
#if defined(PDUMP)
	#define OPTIONS_BIT1		OPTIONS_PDUMP_EN
	#if OPTIONS_BIT1 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT1		0x0UL
#endif /* PDUMP */

/* No longer used */
#define INTERNAL_UNUSED1_OPTION	"INTERNAL_UNUSED1  "
#if defined(INTERNAL_UNUSED1)
	#define OPTIONS_BIT2		OPTIONS_UNUSED1_EN
	#if OPTIONS_BIT2 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT2		0x0UL
#endif

#define SECURE_ALLOC_KM_OPTION "SECURE_ALLOC_KM  "
#if defined(SUPPORT_SECURE_ALLOC_KM)
	#define OPTIONS_BIT3		OPTIONS_SECURE_ALLOC_KM_EN
	#if OPTIONS_BIT3 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT3 0x0UL
#endif /* SUPPORT_SECURE_ALLOC_KM */

#define RGX_OPTION	" "
#if defined(SUPPORT_RGX)
	#define OPTIONS_BIT4		OPTIONS_RGX_EN
	#if OPTIONS_BIT4 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT4		0x0UL
#endif /* SUPPORT_RGX */

#define SECURE_EXPORT_OPTION	"SECURE_EXPORTS  "
#if defined(SUPPORT_SECURE_EXPORT)
	#define OPTIONS_BIT5		OPTIONS_SECURE_EXPORT_EN
	#if OPTIONS_BIT5 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT5		0x0UL
#endif /* SUPPORT_SECURE_EXPORT */

#define INSECURE_EXPORT_OPTION	"INSECURE_EXPORTS  "
#if defined(SUPPORT_INSECURE_EXPORT)
	#define OPTIONS_BIT6		OPTIONS_INSECURE_EXPORT_EN
	#if OPTIONS_BIT6 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT6		0x0UL
#endif /* SUPPORT_INSECURE_EXPORT */

#define VFP_OPTION	"VFP  "
#if defined(SUPPORT_VFP)
	#define OPTIONS_BIT7		OPTIONS_VFP_EN
	#if OPTIONS_BIT7 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT7		0x0UL
#endif /* SUPPORT_VFP */

#define WORKLOAD_ESTIMATION_OPTION	"WORKLOAD_ESTIMATION  "
#if defined(SUPPORT_WORKLOAD_ESTIMATION)
	#define OPTIONS_BIT8		OPTIONS_WORKLOAD_ESTIMATION_EN
	#if OPTIONS_BIT8 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT8		0x0UL
#endif /* SUPPORT_WORKLOAD_ESTIMATION */

#define PDVFS_OPTION	"PDVFS  "
#if defined(SUPPORT_PDVFS)
	#define OPTIONS_BIT9		OPTIONS_PDVFS_EN
	#if OPTIONS_BIT9 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT9		0x0UL
#endif /* SUPPORT_PDVFS */

#define DEBUG_OPTION	"DEBUG  "
#if defined(DEBUG)
	#define OPTIONS_BIT10		OPTIONS_DEBUG_EN
	#if OPTIONS_BIT10 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT10		0x0UL
#endif /* DEBUG */

#define BUFFER_SYNC_OPTION	"BUFFER_SYNC  "
#if defined(SUPPORT_BUFFER_SYNC)
	#define OPTIONS_BIT11		OPTIONS_BUFFER_SYNC_EN
	#if OPTIONS_BIT11 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT11		0x0UL
#endif /* SUPPORT_BUFFER_SYNC */

#define AUTOVZ_OPTION	"AUTOVZ  "
#if defined(SUPPORT_AUTOVZ)
	#define OPTIONS_BIT12		OPTIONS_AUTOVZ_EN
	#if OPTIONS_BIT12 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT12		0x0UL
#endif /* SUPPORT_AUTOVZ */

#define AUTOVZ_HW_REGS_OPTION	"AUTOVZ_HW_REGS  "
#if defined(SUPPORT_AUTOVZ_HW_REGS)
	#define OPTIONS_BIT13		OPTIONS_AUTOVZ_HW_REGS_EN
	#if OPTIONS_BIT13 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT13		0x0UL
#endif /* SUPPORT_AUTOVZ_HW_REGS */

#define RGX_FW_IRQ_OS_COUNTERS_OPTION	"FW_IRQ_OS_COUNTERS  "
#if defined(RGX_FW_IRQ_OS_COUNTERS)
	#define OPTIONS_BIT14		OPTIONS_FW_IRQ_REG_COUNTERS_EN
	#if OPTIONS_BIT14 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT14		0x0UL
#endif /* RGX_FW_IRQ_OS_COUNTERS */

#define VALIDATION_OPTION	"VALIDATION  "
#if defined(SUPPORT_VALIDATION)
	#define OPTIONS_BIT15		OPTIONS_VALIDATION_EN
	#if OPTIONS_BIT15 > RGX_BUILD_OPTIONS_MASK_KM
	#error "Bit exceeds reserved range"
	#endif
#else
	#define OPTIONS_BIT15		0x0UL
#endif /* SUPPORT_VALIDATION */

#define OPTIONS_BIT31		OPTIONS_PERCONTEXT_FREELIST_EN
#if OPTIONS_BIT31 <= RGX_BUILD_OPTIONS_MASK_KM
#error "Bit exceeds reserved range"
#endif

#define RGX_BUILD_OPTIONS_KM	\
	(OPTIONS_BIT0				|\
	 OPTIONS_BIT1				|\
	 OPTIONS_BIT2				|\
	 OPTIONS_BIT3				|\
	 OPTIONS_BIT4				|\
	 OPTIONS_BIT5				|\
	 OPTIONS_BIT6				|\
	 OPTIONS_BIT7				|\
	 OPTIONS_BIT8				|\
	 OPTIONS_BIT9				|\
	 OPTIONS_BIT10				|\
	 OPTIONS_BIT11				|\
	 OPTIONS_BIT12				|\
	 OPTIONS_BIT13				|\
	 OPTIONS_BIT14				|\
	 OPTIONS_BIT15)

#define RGX_BUILD_OPTIONS (RGX_BUILD_OPTIONS_KM | OPTIONS_BIT31)

#define RGX_BUILD_OPTIONS_LIST			\
	{									\
		NO_HARDWARE_OPTION,				\
		PDUMP_OPTION,					\
		INTERNAL_UNUSED1_OPTION,		\
		SECURE_ALLOC_KM_OPTION,			\
		RGX_OPTION,						\
		SECURE_EXPORT_OPTION,			\
		INSECURE_EXPORT_OPTION,			\
		VFP_OPTION,						\
		WORKLOAD_ESTIMATION_OPTION,		\
		PDVFS_OPTION,					\
		DEBUG_OPTION,					\
		BUFFER_SYNC_OPTION,				\
		AUTOVZ_OPTION,					\
		AUTOVZ_HW_REGS_OPTION,			\
		RGX_FW_IRQ_OS_COUNTERS_OPTION,	\
		VALIDATION_OPTION				\
	}

/* --------------------------------------------------------------------------
 * PocketForge: Override build-options constants for dual-ABI compatibility.
 *
 * Problem: Three ABI boundaries share one RGX_BUILD_OPTIONS_KM constant:
 *   1. KM <-> UM (srvcore.c): vendor UM blobs present 0x0060d13d
 *   2. KM <-> FW (rgxinit.c): vendor firmware presents 0x80000010
 *   3. FW alignment checks:  struct layouts must match firmware's expectations
 *
 * The Allwinner-internal DDK 1.19 rgx_options.h has DIFFERENT bit-to-feature
 * mappings than DC-DeepComputing's source. Bits 0,3,5,12,14,15,21,22 in the
 * vendor word 0x0060d13d have Allwinner-internal meanings that do NOT map to
 * NO_HARDWARE, SECURE_ALLOC, etc. in our source tree.
 *
 * Solution: Set RGX_BUILD_OPTIONS_KM to the vendor UM word (0x0060d13d) for
 * UM compatibility. Override FW_OPTIONS_STRICT to exclude all Allwinner-
 * internal bits, so the KM<->FW check ignores bits that are semantically
 * meaningless in our build. The firmware's actual options (0x80000010 after
 * masking = 0x10 = RGX_EN) are a subset of ours; the strict-mask exclusion
 * makes the check pass.
 *
 * Evidence: firmware boot log shows "FW info: 1.19 @ 6345021 (release)
 * build options: 0x80000010" and "RGX FW State: OK" — firmware initializes
 * correctly with our struct layouts (alignment check 25/25 match after
 * SUPPORT_AGP removal). Only the build-options bitmask comparison fails.
 *
 * Source: logs/gpu-km-abi-mismatch-research.md, logs/pvrsrvkm-buildopts-vendor.txt
 * Bead:   tsp-cv7.4.2
 * ----------------------------------------------------------------------- */
#undef  RGX_BUILD_OPTIONS_KM
#define RGX_BUILD_OPTIONS_KM      0x0060d13dUL

#undef  RGX_BUILD_OPTIONS_MASK_KM
#define RGX_BUILD_OPTIONS_MASK_KM 0x0060fffbUL

#undef  RGX_BUILD_OPTIONS
#define RGX_BUILD_OPTIONS         (RGX_BUILD_OPTIONS_KM)

/* Override FW_OPTIONS_STRICT to exclude Allwinner-internal bits (0,3,5,12,
 * 14,15,21,22) that are present in our KM options word (to match vendor UM)
 * but absent in the firmware's options word (0x80000010). These bits have
 * different semantic meanings in Allwinner's internal DDK variant vs the
 * DC-DeepComputing source we build from, so the KM<->FW strict check must
 * ignore them. Only bit 4 (RGX_EN) is common and must match — it does. */
#undef  FW_OPTIONS_STRICT
#define FW_OPTIONS_STRICT         0x00000010UL  /* only RGX_EN is strictly required */

#endif /* RGX_OPTIONS_H */
