#!/bin/bash -ex
pushd $PUPPET_PATH
find $PATCH_DIR/puppet/ -maxdepth 1 -mindepth 1 -type d \
    | xargs -I{} bash -c "patch -Np3 < {}/patch"
popd
