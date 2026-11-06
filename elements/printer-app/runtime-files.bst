kind: manual
description: Install the OCI appliance launcher and runtime filesystem.

sources:
  - kind: local
    path: files

build-depends:
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

# container-entrypoint sources /usr/libexec/printer-app/entrypoint-common.sh,
# the shared startup library; printing/base.bst does not install it.
depends:
  - fsdk-containers.bst:printing/entrypoint-common.bst

config:
  install-commands:
    - install -D -m 755 container-entrypoint.sh "%{install-root}/usr/libexec/ps-printer-app/container-entrypoint"
    - install -d -m 0777 "%{install-root}/var/lib/ps-printer-app" "%{install-root}/var/spool/ps-printer-app"
