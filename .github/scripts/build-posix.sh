#!/bin/sh

set -e

CPU_CORES="$1"
PLATFORM="$2"

export CPU_CORES

eval "$(opam config env)"

echo "::group::Preparing bindings"

cd /tmp/liquidsoap-full

git remote set-url origin https://github.com/savonet/liquidsoap-full.git
git fetch --recurse-submodules=no && git checkout origin/master -- Makefile.git
git reset --hard
git pull

git pull
make clean
make public
make update

echo "::endgroup::"

echo "::group::Setting up specific dependencies"

cd /tmp/liquidsoap-full/liquidsoap

./.github/scripts/checkout-deps.sh

cd /tmp/liquidsoap-full

sed -e 's@ocaml-gstreamer@#ocaml-gstreamer@' -i PACKAGES

export PKG_CONFIG_PATH=/usr/share/pkgconfig/pkgconfig

echo "::endgroup::"

echo "::group::Checking out CI commit"

cd /tmp/liquidsoap-full/liquidsoap

git fetch origin "$GITHUB_SHA"
git checkout "$GITHUB_SHA"
mv .github /tmp
rm -rf ./*
mv /tmp/.github .
git reset --hard

echo "::endgroup::"

echo "::group::Compiling"

cd /tmp/liquidsoap-full

# Workaround
touch liquidsoap/configure

./configure --prefix=/usr \
  --includedir="\${prefix}/include" \
  --mandir="\${prefix}/share/man" \
  --infodir="\${prefix}/share/info" \
  --sysconfdir=/etc \
  --localstatedir=/var \
  --with-camomile-data-dir=/usr/share/liquidsoap/camomile \
  CFLAGS=-g

# Workaround
rm liquidsoap/configure

OCAMLPATH="$(cat .ocamlpath)"
export OCAMLPATH

cd /tmp/liquidsoap-full/liquidsoap
dune build

echo "::endgroup::"

if [ "${PLATFORM}" = "armhf" ]; then
  exit 0
fi

echo "::group::Print build config"

dune exec -- liquidsoap --build-config

echo "::endgroup::"

echo "::group::Basic tests"

cd /tmp/liquidsoap-full/liquidsoap

dune exec -- liquidsoap --version
dune exec -- liquidsoap --check 'print("hello world")'

echo "::endgroup::"
