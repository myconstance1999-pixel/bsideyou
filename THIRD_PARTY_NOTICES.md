# Third-party notices

This curated source export retains the canonical project's recorded Atoll adaptations:

- Upstream: https://github.com/rutmehta/Atoll
- Reviewed upstream commit: `ea20f5541bb9ae8c300b20fb99a7b48665adb158`.
- License: MIT; complete copyright and permission notice below.
- `Sources/BSideControlApp/NotchControlView.swift`: `NotchShape` drawing path adapted from `Sources/Atoll/UI/NotchShape.swift`, with local radii/clamping and no independently animated shape.
- `Sources/BSideControlApp/NotchPanelController.swift`: public AppKit frame-constraint override and setting window level after `isFloatingPanel`, adapted from `Sources/Atoll/Core/NotchPanel.swift`. This is not a copy of the full Atoll implementation.

The canonical notice records GPL projects as architecture/behavior references only; their repositories, assets and source copies are excluded. This notice does not assign a license to original project code.

## External media catalog

`Sources/BSidePlatform/Resources/performance-manifest.v1.json` is retained unchanged because package loading and validated runtime tests require it. Its 129 tracks/480 variants describe external BSide media using titles, subtitles, relative paths, sizes, hashes and semantic metadata. It contains no media/artwork payload, lyrics/dialogue or personal absolute paths. This catalog grants no rights to the described media. No upstream catalog redistribution license has been established; this is not an official BSide distribution. The catalog is metadata for user-provided media, not a license to obtain or redistribute those media.

## MIT License (Atoll)

```
MIT License

Copyright (c) 2026 Rut Mehta

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
