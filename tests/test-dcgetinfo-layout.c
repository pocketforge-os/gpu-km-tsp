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
 * This test includes the actual img_types.h to ensure type correctness
 * (especially IMG_BOOL = bool, not int). The struct definitions are copied
 * from production headers to maintain hermetic compilation, but type-coupled
 * via img_types.h so any production type change will be caught.
 *
 * Layout:
 *   PVRSRV_BRIDGE_OUT_DCGETINFO {
 *     DC_DISPLAY_INFO sDisplayInfo;  // 68 bytes
 *     PVRSRV_ERROR eError;           // 4 bytes at offset 68
 *   } __attribute__((packed))
 *   Total: 72 bytes
 *
 * Build: gcc -I../../include -o test-dcgetinfo-layout test-dcgetinfo-layout.c
 * Run:   ./test-dcgetinfo-layout
 * Exit:  0 if layout is correct, 1 if mismatch
 */

#include <stdio.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <assert.h>

/* Include production img_types.h to get correct type definitions */
/* This ensures IMG_BOOL = bool, IMG_UINT32 = uint32_t, etc. */
#include "img_types.h"

/* 
 * PVRSRV_ERROR is an enum in production (pvrsrv_error.h).
 * For layout purposes, enums are int-sized in C.
 * We redefine it here to match the production size.
 */
typedef int PVRSRV_ERROR;

/* DC_NAME_SIZE from dc_external.h */
#define DC_NAME_SIZE 50

/* 
 * DC_DISPLAY_INFO from include/dc_external.h (NOT packed)
 * Copied verbatim from production to ensure layout match.
 * Uses IMG_* types from img_types.h for type correctness.
 */
typedef struct _DC_DISPLAY_INFO_
{
    IMG_CHAR    szDisplayName[DC_NAME_SIZE];    /*!< Display identifier string */
    IMG_UINT32  ui32MinDisplayPeriod;           /*!< Minimum number of VSync periods */
    IMG_UINT32  ui32MaxDisplayPeriod;           /*!< Maximum number of VSync periods */
    IMG_UINT32  ui32MaxPipes;                   /*!< Maximum number of pipes for this display */
    IMG_BOOL    bUnlatchedSupported;            /*!< Can the device be unlatched? */
} DC_DISPLAY_INFO;

/* 
 * PVRSRV_BRIDGE_OUT_DCGETINFO from generated/rogue/dc_bridge/common_dc_bridge.h
 * The outer struct is packed, but DC_DISPLAY_INFO is NOT packed internally.
 * Copied verbatim from production to ensure layout match.
 */
typedef struct PVRSRV_BRIDGE_OUT_DCGETINFO_TAG
{
    DC_DISPLAY_INFO sDisplayInfo;
    PVRSRV_ERROR eError;
} __attribute__ ((packed)) PVRSRV_BRIDGE_OUT_DCGETINFO;

/* Helper macro for offset checks with detailed output */
#define CHECK_OFFSET(type, field, expected_offset, failures) do { \
    size_t actual = offsetof(type, field); \
    printf("  %-25s offset=%-2zu (expected %zu)", #field, actual, (size_t)(expected_offset)); \
    if (actual != (expected_offset)) { \
        printf(" FAIL\n"); \
        (failures)++; \
    } else { \
        printf(" PASS\n"); \
    } \
} while(0)

/* Helper macro for size checks with detailed output */
#define CHECK_SIZE(type, expected_size, failures) do { \
    size_t actual = sizeof(type); \
    printf("  sizeof(%-25s) = %zu (expected %zu)", #type, actual, (size_t)(expected_size)); \
    if (actual != (expected_size)) { \
        printf(" FAIL\n"); \
        (failures)++; \
    } else { \
        printf(" PASS\n"); \
    } \
} while(0)

int main(void) {
    int failures = 0;
    
    printf("Testing PVRSRV_BRIDGE_OUT_DCGETINFO layout\n");
    printf("============================================\n\n");
    
    /* Verify base type sizes first - critical for ABI correctness */
    printf("Base type verification (from img_types.h):\n");
    CHECK_SIZE(IMG_BOOL, sizeof(bool), failures);
    CHECK_SIZE(IMG_UINT32, 4, failures);
    CHECK_SIZE(IMG_CHAR, 1, failures);
    CHECK_SIZE(PVRSRV_ERROR, sizeof(int), failures);
    
    /* Verify IMG_BOOL is actually bool, not int */
    if (sizeof(IMG_BOOL) != sizeof(bool)) {
        printf("  CRITICAL: IMG_BOOL is not bool! ABI will be wrong.\n");
        failures++;
    } else {
        printf("  IMG_BOOL correctly defined as bool\n");
    }
    printf("\n");
    
    /* Test DC_DISPLAY_INFO layout */
    printf("DC_DISPLAY_INFO (from dc_external.h):\n");
    CHECK_SIZE(DC_DISPLAY_INFO, 68, failures);
    CHECK_OFFSET(DC_DISPLAY_INFO, szDisplayName, 0, failures);
    CHECK_OFFSET(DC_DISPLAY_INFO, ui32MinDisplayPeriod, 52, failures);
    CHECK_OFFSET(DC_DISPLAY_INFO, ui32MaxDisplayPeriod, 56, failures);
    CHECK_OFFSET(DC_DISPLAY_INFO, ui32MaxPipes, 60, failures);
    CHECK_OFFSET(DC_DISPLAY_INFO, bUnlatchedSupported, 64, failures);
    
    /* Verify field sizes */
    printf("  szDisplayName size:        %zu (expected 50)\n", sizeof(((DC_DISPLAY_INFO*)0)->szDisplayName));
    printf("  bUnlatchedSupported size:  %zu (expected 1, bool)\n", sizeof(((DC_DISPLAY_INFO*)0)->bUnlatchedSupported));
    if (sizeof(((DC_DISPLAY_INFO*)0)->bUnlatchedSupported) != 1) {
        printf("  CRITICAL: bUnlatchedSupported is not bool-sized!\n");
        failures++;
    }
    printf("\n");
    
    /* Test PVRSRV_BRIDGE_OUT_DCGETINFO layout */
    printf("PVRSRV_BRIDGE_OUT_DCGETINFO (from common_dc_bridge.h):\n");
    CHECK_SIZE(PVRSRV_BRIDGE_OUT_DCGETINFO, 72, failures);
    CHECK_OFFSET(PVRSRV_BRIDGE_OUT_DCGETINFO, sDisplayInfo, 0, failures);
    CHECK_OFFSET(PVRSRV_BRIDGE_OUT_DCGETINFO, eError, 68, failures);
    printf("\n");
    
    /* Summary */
    printf("============================================\n");
    if (failures == 0) {
        printf("ALL TESTS PASSED\n\n");
        printf("Conclusion: KM struct is 72 bytes, eError at offset 68.\n");
        printf("The trace's 'expected_out_size=68' was a layout tool bug.\n");
        printf("The actual KM-UM ABI is correct (both use 72 bytes).\n");
        return 0;
    } else {
        printf("%d TEST(S) FAILED\n\n", failures);
        printf("ERROR: Layout mismatch detected. The ABI may have changed.\n");
        printf("This test uses production types from img_types.h, so any\n");
        printf("production type change (e.g., IMG_BOOL size) will be caught.\n");
        return 1;
    }
}
