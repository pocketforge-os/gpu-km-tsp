/*************************************************************************/ /*!
@File           pvr_vmap.h
@Title          PowerVR vmap compatibility header
@Copyright      Copyright (c) Imagination Technologies Ltd. All Rights Reserved
@License        Dual MIT/GPLv2

SPDX-License-Identifier: (MIT OR GPL-2.0)
*/ /**************************************************************************/

#ifndef __PVR_VMAP_H__
#define __PVR_VMAP_H__

#include <linux/version.h>
#include <linux/vmalloc.h>

/*
 * pvr_vmap / pvr_vmap_cached - thin wrappers around kernel vmap().
 * On kernels < 5.8 the API is identical; on >= 5.8 the vm_flags
 * argument was removed from vmap(). pvr_vmap_cached is for pages
 * that are already in the CPU cache; on 4.9 there is no difference.
 */
static inline void *pvr_vmap(struct page **pages, unsigned int count,
			     unsigned long flags, pgprot_t prot)
{
	return vmap(pages, count, flags, prot);
}

static inline void *pvr_vmap_cached(struct page **pages, unsigned int count,
				    unsigned long flags, pgprot_t prot)
{
	return vmap(pages, count, flags, prot);
}

static inline void pvr_vunmap(const void *addr, unsigned int count,
			      pgprot_t prot)
{
	(void)count;
	(void)prot;
	vunmap(addr);
}

#endif /* __PVR_VMAP_H__ */
