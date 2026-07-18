# epub.yazi

A Yazi plugin to preview EPUB files with cover art and metadata.

<img src="https://github.com/llanosrocas/library.yazi/blob/main/.github/images/epub-preview-banner.png" width="800" />

## Requirements

- yazi version >= [26.5.6](https://github.com/sxyazi/yazi/releases/tag/v26.5.6).
- `unzip` for metadata
- `ImageMagick` for covers

## Installation

Using yazi package manager

```sh
ya pkg add llanosrocas/library.yazi:epub-preview
```

_Or manually copy `main.lua` to the `~/.config/yazi/plugins/epub-preview.yazi/main.lua`_

## Usage

Add preview and spotter rules in `yazi.toml`:

```toml
prepend_previewers = [
  # make sure to put preview rule on top of conflicting previewers such as "ouch"
  { mime = "application/epub+zip", run = "epub-preview" },
  # { mime = "application/{*zip,tar,bzip2,7z*,rar,xz,zstd,java-archive}", run = "ouch" },
]

# optinal: add this to use custom spotter to copy metadata fields via `cc`
prepend_spotters = [
  { mime = "application/epub+zip", run = "epub-preview" },
]
```

## What is included?

- Standart EPUB fields
  - [x] Title
  - [x] Author
  - [x] Date
  - [x] Publisher
  - [x] Language
  - [x] ISBN
  - [x] Subject

- Calibre fields
  - [x] Series
  - [x] Rating

<img src="https://github.com/llanosrocas/library.yazi/blob/main/.github/images/epub-preview-card-full.png" width="300" />
