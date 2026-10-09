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
