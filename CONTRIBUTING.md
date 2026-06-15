# Contributing to gpu-km-tsp

## Branch strategy

| Branch | Purpose |
|--------|---------|
| `main` | Current development HEAD. All changes land via PR. |
| `upstream` | Passive tracking of `DC-DeepComputing/fml13v01-linux:fm7110-6.6`. Fetch-only; never commit directly. |
| `release/<tag>` | Signed release tags. Format: `tsp-ddk1.19-<YYYY.MM.DD>-<short-sha>`. |

## Pull request requirements

- PRs to `main` require CI to pass (build verification).
- PRs require at least 1 reviewer.
- All commits must be signed (`git commit -S`).
- Force-push is prohibited on `main` and `release/*` branches.

## Commit messages

Use clear, imperative-mood commit messages. Prefix with a scope when
applicable:

```
sunxi_a133: port SysDevInit to DDK 1.19 API
build: add aarch64-none-linux-gnu compiler config
hwdefs: no changes (upstream import)
```

## Build verification

Before submitting a PR, verify the module builds:

```sh
# Inside the pocketforge/build container:
export ARCH=arm64
export CROSS_COMPILE=aarch64-none-linux-gnu-
export PVR_BUILD_DIR=sunxi_a133_linux
export WINDOW_SYSTEM=nullws
export BUILD=release
export KERNELDIR=/work/out/kernel  # from kernel-tsp build

make -j$(nproc)
```

The output `pvrsrvkm.ko` should appear in
`binary_sunxi_a133_linux_nullws_release/target_aarch64/`.

## License convention

All new files must carry the dual MIT/GPLv2 license header matching the
upstream Imagination convention:

```c
/*************************************************************************/ /*!
@File           <filename>
@Title          <brief description>
@Copyright      Copyright (c) Imagination Technologies Ltd. All Rights Reserved
@Description    <description>
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
the GNU General Public License Version 2 ("GPL") in which case the
provisions of GPL are applicable instead of those above.

If you wish to allow use of your version of this file only under the terms
of GPL, and not to allow others to use your version of this file under the
terms of the MIT license, indicate your decision by deleting the provisions
above and replace them with the notice and other provisions required by GPL
as set out in the file called "GPL-COPYING" included in this distribution.
If you do not delete the provisions above, a recipient may use your version
of this file under the terms of either the MIT license or GPL.

This License is also included in this distribution in the file called
"MIT-COPYING".

EXCEPT AS OTHERWISE STATED IN A NEGOTIATED AGREEMENT: (A) THE SOFTWARE IS
PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR
A PARTICULAR PURPOSE AND NONINFRINGEMENT; AND (B) IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/ /**************************************************************************/
```

For PocketForge-authored files, replace the `@Copyright` line with:

```
@Copyright      Copyright (c) PocketForge contributors. All Rights Reserved.
```

## Reporting issues

File issues in [pocketforge-os/gpu-km-tsp](https://github.com/pocketforge-os/gpu-km-tsp/issues)
or in the parent project tracker.
