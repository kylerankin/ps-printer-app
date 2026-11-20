kind: junction
# fsdk-containers owns the one shared printing base (printing/base.bst): the
# patched FSDK CUPS, cups-filters, libcupsfilters, libppd, ghostscript,
# mutool, avahi-printing, PAPPL and pappl-retrofit. Reach FSDK only through
# fsdk-containers.bst:freedesktop-sdk.bst:... and add no patches, overrides
# or options here; see fsdk-containers docs/skills/printing-base.md.
sources:
  - kind: git_repo
    url: github:projectbluefin/fsdk-containers.git
    track: main
    ref: 195014c93e7332f008acc6aff97a59ad6cdf8377

  # The producer generates this gitignored include from its FSDK junction
  # before invoking bst; junction consumers must stage the same value.
  - kind: local
    path: junction-files/fsdk-containers/include
    directory: include

config:
  options:
    arch: '%{arch}'
