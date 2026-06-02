# Grammarless

Grammarless is an experimental native macOS writing assistant. It reads the active text context through Accessibility APIs, shows local proofreading suggestions in an overlay, and can use a user-configured OpenAI-compatible endpoint for higher-level rewriting, long-form editing, and ghost text.

Grammarless is independent and is not affiliated with Grammarly, Microsoft, OpenAI, or any other referenced product or vendor.

## Status

- Stage: pre-alpha / developer preview
- Platform: macOS 14+
- Stack: Swift, AppKit, SwiftUI settings, Xcode project
- Default API config: `http://127.0.0.1:8317/v1`, model `gpt-5.4-mini`, empty API key
- API keys are not bundled. Configure your own endpoint and key before using LLM features.

## Features

- Native text-context detection through macOS Accessibility.
- Overlay proofreading UI with underlines, hover cards, suggestion cards, VBar, launcher, and action panels.
- Offline proofreading resources for Chinese and English:
  - Chinese typo/confusion lexicons, punctuation checks, grammar-pattern checks, date/amount/sequence/proper-noun detectors.
  - English system spell checking plus local confusion and grammar-pattern checks.
- Optional OpenAI-compatible LLM review for non-CJK text and AI actions.
- Automatic CJK proofreading stays offline-only.
- Long-form sidebar with writing memory, structured patch preview/apply, rollback, and ghost text.
- Verified replacement flow with range validation and native paste/type fallbacks.

## Requirements

- macOS 14 or newer
- Xcode or Xcode Command Line Tools
- Accessibility permission for the built app
- Optional: an OpenAI-compatible `/v1/chat/completions` endpoint and API key

## Quick start

```bash
git clone https://github.com/yxp934/grammarless-public.git
cd grammarless-public

xcodebuild test \
  -project Grammarless.xcodeproj \
  -scheme Grammarless \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData

xcodebuild build \
  -project Grammarless.xcodeproj \
  -scheme Grammarless \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData

open .build/DerivedData/Build/Products/Debug/Grammarless.app
```

On first launch, grant Accessibility permission in macOS System Settings so the app can read and update the active text field.

## Configure the API

Open Grammarless Settings and set:

- Base URL: your OpenAI-compatible endpoint, for example `http://127.0.0.1:8317/v1`
- API Key: your own key; it is stored through Keychain by default
- Model: the model name supported by your endpoint

For local development only, you can bypass Keychain with an environment key:

```bash
open -n .build/DerivedData/Build/Products/Debug/Grammarless.app \
  --env GRAMMARLESS_DISABLE_KEYCHAIN=1 \
  --env GRAMMARLESS_DEV_API_KEY='your-local-dev-key'
```

## Project structure

```text
Grammarless.xcodeproj/       Xcode project
GrammarlessApp/              macOS app, Accessibility integration, overlay UI, settings, replacement flow
GrammarlessCore/             Models, configuration, local proofreading, LLM client, agents, memory, parsing
GrammarlessCoreTests/        Unit tests for core behavior
scripts/                     Project-generation and ad-hoc signing helpers
```

## Development

Regenerate the Xcode project when source layout changes:

```bash
ruby scripts/generate_xcodeproj.rb
```

Run tests:

```bash
xcodebuild test \
  -project Grammarless.xcodeproj \
  -scheme Grammarless \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData
```

Build the app:

```bash
xcodebuild build \
  -project Grammarless.xcodeproj \
  -scheme Grammarless \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData
```

Debug logs in development builds are written under `${TMPDIR}`.

## Privacy and security

- No API key is included in this repository.
- User API keys should be stored through Keychain.
- Offline proofreading uses bundled Swift-native rules and lexicons.
- Automatic CJK proofreading stays local and does not call the configured LLM endpoint.
- LLM features send selected text/context only to the endpoint configured by the user.

## Known limitations

- This is an early developer preview and has not been notarized for distribution.
- Accessibility behavior can vary by host application.
- Microsoft Word and other rich editors may require additional validation for production use.
- Offline proofreading is intentionally conservative and lexicon/rule based.
- No open-source license has been selected yet; unless a license is added, all rights are reserved.
