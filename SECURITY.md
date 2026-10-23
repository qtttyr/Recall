# Security

Recall is a local-first macOS app that reads the clipboard. That makes its
threat model small but sharp.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use GitHub's private
vulnerability reporting for the repository (Security → Report a vulnerability)
so the maintainers can investigate before details are public.

Include:

- the affected version or commit;
- macOS version and architecture;
- a minimal reproduction;
- what data or permission boundary is crossed;
- whether the issue requires Accessibility, clipboard access, or a malicious
  model download.

This is a pre-1.0 project maintained on a best-effort basis. Please allow a
reasonable window before disclosure; coordinated disclosure is appreciated.

## What is in scope

- Unauthorized clipboard capture or persistence
- Bypassing concealed, transient, secure-input, excluded-app, or self-write
  protections
- Reading or writing data outside the intended storage location
- Model download integrity, path traversal, or checksum bypass
- A crafted model or tokenizer causing code execution or data exfiltration
- Privilege escalation through Accessibility or the hot key
- Logging or transmitting clipboard contents, embeddings, or source-app data

## What is out of scope

- The inherent ability of a process with Accessibility to synthesize input
- Vulnerabilities in macOS, Core ML, or Apple's `NLContextualEmbedding`
- A user choosing to exclude no apps and copying a secret manually
- Denial of service from an intentionally enormous clipboard payload
- Model quality, bias, or retrieval mistakes (please open a normal issue)

## Data and network

- Clipboard history lives in
  `~/Library/Application Support/Recall/recall.sqlite`.
- Images live in `~/Library/Application Support/Recall/Images`.
- The embedding model lives in
  `~/Library/Application Support/Recall/Models/embeddinggemma-2-coreml`.
- Recall has no accounts, telemetry, analytics, or sync.
- The only app-initiated network request is the optional, pinned model download
  from Hugging Face.
- Auto-paste requires Accessibility and only posts `⌘V`; clipboard read access
  is separate.

## Model integrity

The model is pinned by revision and by a SHA-256 digest for every asset. A file
is installed only after its digest matches. The compiled `.mlmodelc` is stamped
with the revision and moved into place atomically. The app does not execute
downloaded code; Core ML compiles the model package under the system's model
compilation rules.

## Supported versions

Recall is pre-1.0. Security fixes target the latest `main` branch and the latest
published build, when one exists. Older commits may not receive backports.
