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
