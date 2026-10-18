# Third-party licences

## swift-vocal-isolation (stem separation)
Pluck includes `DemucsSeparator.swift` and `DemucsSTFT.swift` from
[swift-vocal-isolation](https://github.com/arraypress/swift-vocal-isolation) v1.2.0, lightly adapted.

```
MIT License

Copyright (c) 2026 David Sherlock (ArrayPress)

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

## HTDemucs model (downloaded on first use)
The stem separation model, [arraypress/stems-demucs](https://huggingface.co/arraypress/stems-demucs)
(`stems-htdemucs-float32.aimodel`), is a Core AI conversion of Hybrid Transformer Demucs by Simon Rouard,
Francisco Massa and Alexandre Défossez (Meta), [facebookresearch/demucs](https://github.com/facebookresearch/demucs),
MIT licence. It isn't part of the app; Pluck downloads it when stems are first used.

> S. Rouard, F. Massa, A. Défossez. "Hybrid Transformers for Music Source Separation." ICASSP 2023.

## FluidAudio (speaker labels)
Pluck uses [FluidAudio](https://github.com/FluidInference/FluidAudio) v0.17.7, © FluidInference,
Apache License 2.0, to tell speakers apart. Its optional prebuilt text normalizer isn't included.
The full licence and the notices FluidAudio ships for code it includes (fastcluster, VBx, Kokoro
and its text frontends) are in [ThirdPartyLicenses/FluidAudio](ThirdPartyLicenses/FluidAudio).

## Sortformer speaker model (downloaded on first use)
The speaker model, [FluidInference/diar-streaming-sortformer-coreml](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml)
(pinned to revision `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`), is a Core ML conversion of NVIDIA's
[Streaming Sortformer](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1) diarization model,
released under the NVIDIA Open Model License (the conversion is published as CC BY 4.0). It isn't part
of the app; Pluck downloads it when speakers are first labelled.

## spektrafilm and darktable (film, Pluck Studio)
Pluck Studio's film engine, `pluck-spektra`, is a separate program under the GNU GPL version 3
or later, built from [darktable](https://github.com/darktable-org/darktable)'s native port of
[spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea Volpato (© darktable
developers, GPL-3.0-or-later). Its source is in [Helpers/PluckSpektra](Helpers/PluckSpektra).
The film and paper data is downloaded on request from
[darktable-spektrafilm](https://github.com/darktable-org/darktable-spektrafilm), CC BY-SA 4.0 ©
Andrea Volpato, with its licence.

## Depth Anything V2 Small (depth and sky masks, Pluck Studio; downloaded on request)

Depth Anything V2 by Lihe Yang, Bingyi Kang, Zilong Huang, Zhen Zhao, Xiaogang Xu, Jiashi Feng and
Hengshuang Zhao; the Small model and its Core ML conversion by Apple
(https://huggingface.co/apple/coreml-depth-anything-v2-small), licensed under the Apache License 2.0
(https://www.apache.org/licenses/LICENSE-2.0). Pluck downloads the model only when asked, checks it,
and runs it on the Mac; it is not part of Pluck's download.

## RED R3D SDK (Raw Player, Pluck Studio)
Pluck Studio's raw decoder, `pluck-raw`, uses the R3D SDK, © 2008-2026 RED Digital Cinema. All
rights reserved. Its runtime libraries (REDR3D, REDMetal) are included unchanged in Pluck's own
folder, for Pluck's use only, under RED's R3D SDK License Agreement. They may not be copied,
reverse engineered or used by other programs. The SDK itself isn't part of this repository.

## Blackmagic RAW SDK (Raw Player, Pluck Studio)
`pluck-raw` uses the Blackmagic RAW SDK, © Blackmagic Design Pty. Ltd. Its API library
(BlackmagicRawAPI.framework) is included unchanged under the Blackmagic RAW SDK License
Agreement. The SDK itself isn't part of this repository.
