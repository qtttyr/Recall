# Third-party notices

Recall's own source code is released under the MIT License (see `LICENSE`).
Recall also includes or downloads the following third-party work.

## EmbeddingGemma 2 Core ML

- **Model:** EmbeddingGemma 2
- **Base model:** [google/embeddinggemma-2](https://huggingface.co/google/embeddinggemma-2), Google DeepMind
- **Core ML conversion:** [FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
- **Pinned revision:** `70fcf18f32c8cffc173fea982d5652d0bd1de8ea`
- **License:** Apache License 2.0, as declared by the conversion's model card.
- **Base-model terms:** Google's [Gemma Terms of Use](https://ai.google.dev/gemma/terms) may also apply to the underlying model.

Recall does not redistribute the model weights. The app downloads the
pinned text package (about 585 MB), verifies each asset's SHA-256 digest, and
compiles it for Core ML on the user's Mac. The model is stored under:

`~/Library/Application Support/Recall/Models/embeddinggemma-2-coreml`

## FluidUse EmbeddingGemma runtime

Parts of Recall's EmbeddingGemma runtime are adapted from
[FluidInference/FluidUse](https://github.com/FluidInference/FluidUse).

- Copyright (c) FluidInference contributors
- License: Apache License 2.0
- Adapted files: `EmbeddingGemmaManager.swift`, `EmbeddingGemmaTokenizer.swift`,
  `EmbeddingGemmaModelStore.swift`, and `EmbeddingGemmaTypes.swift`.
- Modifications for Recall: provider lifecycle, download and verification
  policy, cache layout, app-facing errors, and integration with Recall's
  semantic engine.

The original copyright headers are retained in those files.

## SQLite

Recall uses SQLite and FTS5 through the system library.

- SQLite is in the public domain.
- <https://www.sqlite.org/copyright.html>

## Apple frameworks

Recall uses Apple's system frameworks, including AppKit, SwiftUI, Core ML,
NaturalLanguage, Accelerate, Carbon, and Security. These frameworks are
provided by macOS and are not distributed with Recall.

## Apache License 2.0

A full copy of the Apache License 2.0 is included at
[`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt).

---

If you believe a notice is missing or inaccurate, please open an issue so it
can be corrected before the next release.
