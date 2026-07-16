# Vendored fonts (subset)

All files are Latin/icon subsets generated with fonttools (pyftsubset).
Source upstreams and licenses:

- **SpaceGrotesk-Regular-subset.ttf / SpaceGrotesk-SemiBold-subset.ttf**
  Space Grotesk — SIL Open Font License 1.1.
  https://github.com/google/fonts/tree/main/ofl/spacegrotesk
- **IBMPlexMono-Regular-subset.ttf / IBMPlexMono-SemiBold-subset.ttf**
  IBM Plex Mono — SIL Open Font License 1.1.
  https://github.com/google/fonts/tree/main/ofl/ibmplexmono
- **MaterialSymbolsRounded-subset.ttf**
  Material Symbols Rounded — Apache License 2.0 (instanced FILL0/wght400/GRAD0/opsz24,
  subset to icons listed in icons.txt).
  https://github.com/google/material-design-icons

Subsets contain only the glyphs the Windows shell UI renders; regenerate by
re-running the subset pipeline if new icons/characters are needed.
