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
    dump of generated Metal source to stdout.
  - `MPVShaderTests.swift`: module renamed to `Anime4KMetalCore`, resources read via
    `Anime4KResources.bundle`; dropped the Denoise and Experimental-Effects cases
    (those shader folders are not vendored).

## Anime4K GLSL shaders (MIT)
- Upstream: https://github.com/bloc97/Anime4K
- Commit: `e6c0064069f15d3a772ca00d8ea0c51a6522cbe0` (the submodule commit pinned by Anime4KMetal)
- License: `ThirdPartyLicenses/Anime4K-LICENSE.txt`
- Copied unmodified into `Sources/Anime4KMetalCore/Resources/glsl/<category>/`:
  only the shaders used by the presets (Clamp_Highlights, Restore CNN S/M/L/VL/Soft,
  Restore GAN UUL, Upscale CNN x2 S/M/L/VL, Upscale+Denoise CNN x2 M/VL,
  AutoDownscalePre x2/x4, Deblur DoG).
