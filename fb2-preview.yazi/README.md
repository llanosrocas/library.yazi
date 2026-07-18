# fb2-preview.yazi

A Yazi plugin to preview FB2 files with cover art and metadata.

<img src="https://github.com/llanosrocas/library.yazi/blob/main/.github/images/fb2-preview-banner.png" width="800" />

## Requirements

- yazi version >= [26.5.6](https://github.com/sxyazi/yazi/releases/tag/v26.5.6).
- `ImageMagick` for covers

## Installation

Using yazi package manager

```sh
ya pkg add llanosrocas/library.yazi:fb2-preview
```

_Or manually copy `main.lua` to the `~/.config/yazi/plugins/fb2-preview.yazi/main.lua`_

## Usage

Add preview and spotter rules in `yazi.toml`:

```toml
prepend_previewers = [
  { url = "*.{fb2,fb2.zip,fbz}", run = "fb2-preview" },
]

# optinal: add this to use custom spotter to copy metadata fields via `cc`
prepend_spotters = [
  { url = "*.{fb2,fb2.zip,fbz}", run = "fb2-preview" },
]
```

## What is included?

- Standart fb2 fields
  - [x] Title
  - [x] Author
  - [x] ISBN
  - [x] Date
  - [x] Publisher
  - [x] Language
  - [x] Subject
