# Model notes

Recall's semantic search is only as good as the distance function underneath
it. This document records the choices that are easy to lose: the pinned model,
the prompts, the provider switch, and the calibration that keeps the panel
small.

## Why EmbeddingGemma 2

Clipboard items are short, messy, and often bilingual. A keyword index is good
at exact identifiers and bad at “the note about the thing from Tuesday.” A
multilingual sentence embedding gives both languages one shared space, so a
Russian query can retrieve an English code snippet and vice versa.

EmbeddingGemma 2 was chosen for three practical reasons:

1. **One multilingual space.** No per-language query routing is needed for the
   primary path.
2. **A strong Core ML conversion.** The
   [FluidInference conversion](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
   keeps the text encoder on the Neural Engine and exposes fixed-shape
   functions plus a packed short-text function.
3. **A credible fallback.** Apple's `NLContextualEmbedding` is already on macOS,
   so the product remains useful before the download completes.

## Pinned assets

The model is not bundled with the app. The app downloads six files from the
pinned revision and verifies each one before installing it:

| Asset | Bytes |
| --- | ---: |
| `config.json` | 2,845 |
| `tokenizer.json` | 32,170,510 |
| `embeddings.bf16` | 268,435,456 |
| `EmbeddingGemma2Text.mlpackage/Manifest.json` | 617 |
| `EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel` | 7,323,423 |
| `EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin` | 276,815,424 |
| **Total** | **584,748,275** |

- Repository: `FluidInference/embeddinggemma-2-coreml`
- Revision: `70fcf18f32c8cffc173fea982d5652d0bd1de8ea`
- Output: 768-dimensional, L2-normalized vectors
- Compute units: `.cpuAndNeuralEngine`
- Cache: `~/Library/Application Support/Recall/Models/embeddinggemma-2-coreml`

The download is asset-level resumable: a file that is already complete and
matches its checksum is kept, and the remaining files are fetched again. Each
download lands in a temporary sibling file, is hashed with SHA-256, and is
renamed into place only after the digest matches. The `.mlpackage` is compiled
once, stamped with the revision, and moved into place atomically.

The cache is trusted at launch when the `.verified-<revision>` marker, the
compiled bundle, its revision stamp, and the asset names are present. Verifying
every byte is an explicit action in Settings because it takes a few seconds.

## Prompts

EmbeddingGemma is trained with task prefixes. Recall uses the text-only search
prompts from the model's configuration:

| Use | Prompt |
| --- | --- |
| Query | `task: search result \| query: <text>` |
| Document | `title: none \| text: <text>` |

- Query text is trimmed to 2,000 characters before tokenization.
- The tokenizer caps a document at 512 tokens; longer clipboard items are
  truncated for embedding but remain searchable in full through FTS.
- Documents are embedded as `title: none` because clipboard items rarely have a
  meaningful title. A future version could use the source app or a page title
  when one is available.

## Similarity and cutoff

Vectors are normalized before they enter the matrix, so a dot product is
cosine similarity. The model's usable range is compressed. In a seeded
English/Russian check, the query

> тот SQL запрос к базе данных про пользователей за последнюю неделю

produced approximately:

| Document | Score |
| --- | ---: |
| Russian note about a users query from the last seven days | 0.850 |
| English `SELECT ... WHERE created_at > now() - interval '7 days'` | 0.804 |
| Russian interface quote | 0.648 |
| Russian meeting notes | 0.634 |
| Russian groceries | 0.610 |

An absolute threshold of 0.8 would reject useful paraphrases; a threshold of
0.55 would keep groceries. Recall therefore uses two gates:

```text
cutoff = max(absoluteFloor, topScore - relativeMargin)
```

| Provider | Floor | Margin |
| --- | ---: | ---: |
| EmbeddingGemma 2 | 0.58 | 0.10 |
| Apple contextual | 0.55 | 0.10 |

The floor rejects an entirely unrelated history. The margin removes the long
tail relative to the best match. The resulting set is capped at five items.

This is intentionally conservative. If the model finds only two genuinely
close matches, the panel shows two and says “Only the closest matches.” It does
not fill the remaining rows with keyword-only items.

## Semantic authority and keyword precision

Keyword search and vector search answer different questions:

- BM25 is excellent for `raycast`, `func greet`, a URL, or an exact identifier.
- Vectors are excellent for “that note about the thing from Tuesday.”

Recall runs both, but the vector set is authoritative when it is non-empty.
Keyword hits are intersected with the vector set before reciprocal-rank fusion.
This preserves the precision of an exact identifier without letting a shared
function word pull in an unrelated note. If the vector set is empty, the
keyword list becomes the result set.

Keyword FTS also drops short function words and joins meaningful tokens with
`AND`, so a natural-language query is allowed to produce zero keyword matches.
That is a feature: the semantic path is responsible for meaning.

## Provider switch

Every vector is stored with an `embedding_provider` and an
`embedding_language`:

- EmbeddingGemma 2 uses the single bucket `multi`.
- Apple contextual uses `en` or `ru`, because its vectors are per-script.

When the provider changes, `AppState` restarts the index loop, rebuilds the
vector matrix from only the active provider's rows, and re-embeds items whose
provider does not match. Old vectors are never compared with new ones, even if
their dimensions happen to agree.

If the model is removed from Settings, Recall deactivates it, reindexes with
Apple's contextual embeddings, and keeps the clipboard history untouched.

## Apple fallback

`NLContextualEmbedding` is loaded lazily per language. The app:

- asks the system for assets if they are not installed;
- loads the English or Russian model;
- mean-pools token vectors and L2-normalizes the result;
- unloads idle system models after five minutes.

The fallback is 512-dimensional and per-script, so it is not cross-lingual in
the way EmbeddingGemma is. It keeps exact and same-language meaning search
working before the download finishes, and it remains available if the user
chooses not to install the larger model.

## Runtime shape

The Core ML package exposes fixed-shape functions `embed_32`, `embed_48`,
`embed_64`, `embed_128`, `embed_256`, `embed_512`, and `pack_256`. Fixed shapes
are what keep the graph on the Neural Engine.

The runtime supports packing up to eight short texts into one 256-token call,
with block-diagonal attention and restarting positions. The current app index
embeds one item at a time; the batch API is available for a future indexing
optimization.

## Failure behavior

- Download or checksum failure → `ModelManager.phase = .failed`; semantic search
  falls back to Apple's model.
- Compile failure → the downloaded package is kept; the user can retry or
  verify.
- Load failure after a valid cache → “installed but could not be loaded” with a
  Settings path to verify or remove.
- Semantic embedding failure at query time → keyword results, with
  `semanticUsed = false`.
- A model removed while indexing → the in-flight write is rejected by provider
  check; the loop restarts on the fallback provider.

## Calibration checklist

If the model or prompt changes:

1. Run the cross-language seed set (English SQL, Russian query, unrelated
   groceries, interface quotes, meeting notes).
2. Record the top scores, not just the ranking.
3. Check the floor against the highest unrelated score.
4. Check the margin against the gap between the best and the fifth result.
5. Verify that a semantic query with no close matches shows keyword fallback
   rather than padding.
6. Verify that Russian and English versions of the same query retrieve the same
   core item.

The bounds live in `SemanticEngine.relevanceBounds()`; they are deliberately
not exposed as user settings.
