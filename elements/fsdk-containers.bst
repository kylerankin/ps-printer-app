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
    ref: e7ef388a56db3c9377928d4c01a91352776e6799

  # The producer generates this gitignored include from its FSDK junction
  # before invoking bst; junction consumers must stage the same value.
  - kind: local
    path: junction-files/fsdk-containers/include
    directory: include

config:
  options:
    arch: '%{arch}'
