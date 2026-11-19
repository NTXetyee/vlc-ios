# Vendored third-party code

## Anime4KMetal (Apache-2.0)
- Upstream: https://github.com/imxieyi/Anime4KMetal
- Commit: `c46b8652a203d259ffbc3d39f21aa54263e11584` (2024-06-06)
- License: `ThirdPartyLicenses/Anime4KMetal-LICENSE.txt`
- Files copied from `Shared/` into `Sources/Anime4KMetalCore/`:
  `Anime4K.swift`, `MPVShader.swift`, `Average.swift`, `CenterResize.metal`;
  and `Tests Shared/MPVShaderTests.swift` into `Tests/Anime4KMetalCoreTests/`.
- Local modifications (files carry a "Modified for vlc-ios Anime4K fork" notice):
  - `Anime4K.swift`: load GLSL and the Metal library from the SwiftPM bundle
    (`Bundle.module`) instead of `Bundle(for:)` / `.main`; removed the per-pass
    dump of generated Metal source to stdout; public API for the Anime4KPlayer target;
    the per-frame "output" texture is reused instead of allocated every frame.
  - `MPVShader.swift`: generated kernels sample at pixel centres (`(gid + 0.5) / size`
    instead of `gid / (size - 1)`, the cause of upstream's "not subpixel-aligned" known
    issue) and skip threads outside the output texture.
  - `MPVShaderTests.swift`: module renamed to `Anime4KMetalCore`, resources read via
    `Anime4KResources.bundle`; dropped the Denoise and Experimental-Effects cases
    (those shader folders are not vendored).

## Anime4K GLSL shaders (MIT)
- Upstream: https://github.com/bloc97/Anime4K
- Commit: `e6c0064069f15d3a772ca00d8ea0c51a6522cbe0` (the submodule commit pinned by Anime4KMetal)
- License: `ThirdPartyLicenses/Anime4K-LICENSE.txt`
- Copied unmodified into `Sources/Anime4KMetalCore/Resources/glsl/<category>/`:
  the shaders used by modes A/B/C (+ doubled) at every size: Clamp_Highlights,
  Restore CNN S/M/L/VL/UL and Soft S/M/L/VL/UL, Upscale CNN x2 S/M/L/VL/UL,
  Upscale+Denoise CNN x2 S/M/L/VL/UL, AutoDownscalePre x2/x4, Deblur DoG.
