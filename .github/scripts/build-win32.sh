#!/bin/sh

set -e

SYSTEM="$1"
BRANCH="$2"
CPU_CORES="$3"
IS_ROLLING_RELEASE="$4"
IS_RELEASE="$5"
GITHUB_SHA="$6"

OPAM_PREFIX="$(opam var prefix)"
VERSION="$(opam show -f version ./liquidsoap.opam | cut -d'-' -f 1)"
PWD="$(dirname "$0")"
BASE_DIR="$(cd "${PWD}/../.." && pwd)"
COMMIT_SHORT="$(echo "${GITHUB_SHA}" | cut -c-7)"

if [ -n "${IS_ROLLING_RELEASE}" ]; then
  TAG="${COMMIT_SHORT}-"
elif [ -n "${IS_RELEASE}" ]; then
  TAG=""
else
  TAG="${BRANCH}-"
fi

if [ "${SYSTEM}" = "x64" ]; then
  HOST="x86_64-w64-mingw32.static"
  BUILD="${TAG}${VERSION}-win64"
  PKG_CONFIG_PATH="/usr/src/mxe/usr/x86_64-w64-mingw32.static/lib/pkgconfig/"
else
  # shellcheck disable=SC2034
  HOST="i686-w64-mingw32.static"
  BUILD="${TAG}-${VERSION}-win32"
  # shellcheck disable=SC2034
  PKG_CONFIG_PATH="/usr/src/mxe/usr/i686-w64-mingw32.static/lib/pkgconfig/"
fi

export OPAMSOLVERTIMEOUT=480
export OPAMJOBS="$CPU_CORES"
export CC=""

echo "::group::Installing deps"

eval "$(opam config env)"
opam repository set-url default https://github.com/ocaml/opam-repository.git
cd /home/opam/opam-cross-windows/
# shellcheck disable=SC2046
opam remove -y ppx_tools_versioned-windows $(echo "$OPAM_DEPS" | sed -e 's#,# #g')
# shellcheck disable=SC2046
opam upgrade -y $(echo "$OPAM_DEPS" | sed -e 's#,# #g') ffmpeg-windows ffmpeg-avutil-windows

echo "::endgroup::"

echo "::group::Install liquidsoap-windows"
opam install -y liquidsoap-windows
echo "::endgroup::"

wine "${OPAM_PREFIX}/windows-sysroot/bin/liquidsoap" --build-config

echo "::group::Bundling executable"

cd ~
cp -rf "${BASE_DIR}/.github/win32" "liquidsoap-$BUILD"
cp -rf "${BASE_DIR}/src/libs" "liquidsoap-$BUILD"
cd "liquidsoap-$BUILD"
cp "${OPAM_PREFIX}"/windows-sysroot/bin/liquidsoap ./liquidsoap.exe
cp -rf "$(ocamlfind -toolchain windows ocamlc -where)/../../share/camomile" .
cd ..
zip -r "liquidsoap-$BUILD.zip" "liquidsoap-$BUILD"

mv "liquidsoap-$BUILD.zip" "/tmp/${GITHUB_RUN_NUMBER}/win32/dist"

echo "##[set-output name=basename;]liquidsoap-${BUILD}"

echo "::endgroup::"
