/*************************************************************************/ /*!
@File
@Title          OS PMR functions
@Copyright      Copyright (c) Imagination Technologies Ltd. All Rights Reserved
@Description    OS specific PMR functions
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

#if !defined(PMR_OS_H)
#define PMR_OS_H

#include "pmr_impl.h"

/* SYSPORT_MEM_OFFSET: on the DeepComputing sf_7110 (RISC-V SiFive) platform the
 * GPU reaches DRAM through a "system port" aperture, so uncached PMR mappings are
 * aliased +16GB (0x4_0000_0000) to hit the uncached system-port view of the same
 * RAM (see pmr_os.c _OSMMapPMR: riscv_cached ? addr : addr+SYSPORT_MEM_OFFSET).
 * On ARM64 / sunxi_a133 there is NO such aperture — the GPU sees CPU physical
 * addresses 1:1 (vendor pvrsrvkm.ko confirmed: UMA Cpu<->Dev translation is a pure
 * copy, no offset). Applying the RISC-V offset here put every UNCACHED userspace
 * PMR mapping 16GB past the top of DRAM -> external-abort SError on first GPU/
 * firmware-context buffer write (tsp-cv7.4.3). Gate the offset to RISC-V builds so
 * ARM64 always maps 1:1; the sf_7110 build is unaffected. */
#if defined(__riscv)
#define SYSPORT_MEM_OFFSET   0x400000000
#else
#define SYSPORT_MEM_OFFSET   0x0
#endif

/*************************************************************************/ /*!
@Function       OSMMapPMRGeneric
@Description    Implements a generic PMR mapping function, which is used
                to CPU map a PMR where the PMR does not have a mapping
                function defined by the creating PMR factory.
@Input          psPMR               the PMR to be mapped
@Output         pOSMMapData         pointer to any private data
                                    needed by the generic mapping function
@Return         PVRSRV_OK on success, a failure code otherwise.
*/ /**************************************************************************/
PVRSRV_ERROR
OSMMapPMRGeneric(PMR *psPMR, PMR_MMAP_DATA pOSMMapData);

#endif /* !defined(PMR_OS_H) */
