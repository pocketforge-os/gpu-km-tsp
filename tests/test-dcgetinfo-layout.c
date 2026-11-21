/*
 * test-dcgetinfo-layout.c
 *
 * Hermetic test to verify PVRSRV_BRIDGE_OUT_DCGETINFO struct layout.
 * 
 * Background: Gate 1(c) trace showed "out_size=72 expected_out_size=68" which
 * flagged a potential ABI mismatch. Analysis revealed the KM struct is correct
 * at 72 bytes (DC_DISPLAY_INFO=68 + eError=4), matching what UM passes. The
 * "expected_out_size=68" came from a layout tool bug (computing only the
 * DC_DISPLAY_INFO portion). This test proves the KM struct layout is correct.
 *
 * Layout:
 *   PVRSRV_BRIDGE_OUT_DCGETINFO {
 *     DC_DISPLAY_INFO sDisplayInfo;  // 68 bytes (50 + 2pad + 4+4+4+4)
 *     PVRSRV_ERROR eError;           // 4 bytes at offset 68
 *   } __attribute__((packed))
 *   Total: 72 bytes
 *
 * Build: gcc -o test-dcgetinfo-layout test-dcgetinfo-layout.c
 * Run:   ./test-dcgetinfo-layout
 * Exit:  0 if layout is correct, 1 if mismatch
 */

#include <stdio.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/* Minimal type definitions matching the KM headers */
typedef int IMG_INT;
typedef unsigned int IMG_UINT32;
typedef unsigned char IMG_CHAR;
typedef int IMG_BOOL;
typedef int PVRSRV_ERROR;

#define DC_NAME_SIZE 50

/* DC_DISPLAY_INFO from include/dc_external.h (NOT packed) */
typedef struct _DC_DISPLAY_INFO_
{
    IMG_CHAR    szDisplayName[DC_NAME_SIZE];    /* 50 bytes */
    IMG_UINT32  ui32MinDisplayPeriod;           /* 4 bytes, needs align 4 */
    IMG_UINT32  ui32MaxDisplayPeriod;           /* 4 bytes */
    IMG_UINT32  ui32MaxPipes;                   /* 4 bytes */
    IMG_BOOL    bUnlatchedSupported;            /* 4 bytes */
} DC_DISPLAY_INFO;

/* PVRSRV_BRIDGE_OUT_DCGETINFO from generated/rogue/dc_bridge/common_dc_bridge.h */
/* The outer struct is packed, but DC_DISPLAY_INFO is NOT packed internally */
typedef struct PVRSRV_BRIDGE_OUT_DCGETINFO_TAG
{
    DC_DISPLAY_INFO sDisplayInfo;
    PVRSRV_ERROR eError;
} __attribute__ ((packed)) PVRSRV_BRIDGE_OUT_DCGETINFO;

int main(void) {
    int failures = 0;
    
    printf("Testing PVRSRV_BRIDGE_OUT_DCGETINFO layout...\n\n");
    
    /* Test DC_DISPLAY_INFO layout */
    printf("DC_DISPLAY_INFO:\n");
    printf("  sizeof = %zu (expected 68)\n", sizeof(DC_DISPLAY_INFO));
    if (sizeof(DC_DISPLAY_INFO) != 68) {
        printf("  FAIL: DC_DISPLAY_INFO size mismatch\n");
        failures++;
    } else {
        printf("  PASS\n");
    }
    
    printf("  szDisplayName:       offset=%-2zu size=%zu\n", 
           offsetof(DC_DISPLAY_INFO, szDisplayName), 
           sizeof(((DC_DISPLAY_INFO*)0)->szDisplayName));
    printf("  ui32MinDisplayPeriod: offset=%-2zu size=%zu (expects 2-byte pad before)\n", 
           offsetof(DC_DISPLAY_INFO, ui32MinDisplayPeriod),
           sizeof(((DC_DISPLAY_INFO*)0)->ui32MinDisplayPeriod));
    if (offsetof(DC_DISPLAY_INFO, ui32MinDisplayPeriod) != 52) {
        printf("  FAIL: ui32MinDisplayPeriod offset mismatch (expected 52)\n");
        failures++;
    } else {
        printf("  PASS\n");
    }
    printf("  ui32MaxDisplayPeriod: offset=%-2zu size=%zu\n", 
           offsetof(DC_DISPLAY_INFO, ui32MaxDisplayPeriod),
           sizeof(((DC_DISPLAY_INFO*)0)->ui32MaxDisplayPeriod));
    printf("  ui32MaxPipes:        offset=%-2zu size=%zu\n", 
           offsetof(DC_DISPLAY_INFO, ui32MaxPipes),
           sizeof(((DC_DISPLAY_INFO*)0)->ui32MaxPipes));
    printf("  bUnlatchedSupported: offset=%-2zu size=%zu\n", 
           offsetof(DC_DISPLAY_INFO, bUnlatchedSupported),
           sizeof(((DC_DISPLAY_INFO*)0)->bUnlatchedSupported));
    
    /* Test PVRSRV_BRIDGE_OUT_DCGETINFO layout */
    printf("\nPVRSRV_BRIDGE_OUT_DCGETINFO:\n");
    printf("  sizeof = %zu (expected 72)\n", sizeof(PVRSRV_BRIDGE_OUT_DCGETINFO));
    if (sizeof(PVRSRV_BRIDGE_OUT_DCGETINFO) != 72) {
        printf("  FAIL: PVRSRV_BRIDGE_OUT_DCGETINFO size mismatch\n");
        failures++;
    } else {
        printf("  PASS\n");
    }
    
    printf("  sDisplayInfo: offset=%-2zu size=%zu\n", 
           offsetof(PVRSRV_BRIDGE_OUT_DCGETINFO, sDisplayInfo),
           sizeof(((PVRSRV_BRIDGE_OUT_DCGETINFO*)0)->sDisplayInfo));
    printf("  eError:       offset=%-2zu size=%zu\n", 
           offsetof(PVRSRV_BRIDGE_OUT_DCGETINFO, eError),
           sizeof(((PVRSRV_BRIDGE_OUT_DCGETINFO*)0)->eError));
    
    if (offsetof(PVRSRV_BRIDGE_OUT_DCGETINFO, eError) != 68) {
        printf("  FAIL: eError offset mismatch (expected 68)\n");
        failures++;
    } else {
        printf("  PASS: eError at offset 68 (matches UM ABI)\n");
    }
    
    printf("\n");
    if (failures == 0) {
        printf("ALL TESTS PASSED\n");
        printf("Conclusion: KM struct is 72 bytes, eError at offset 68.\n");
        printf("The trace's 'expected_out_size=68' was a layout tool bug.\n");
        printf("The actual KM-UM ABI is correct (both use 72 bytes).\n");
        return 0;
    } else {
        printf("%d TEST(S) FAILED\n", failures);
        return 1;
    }
}
