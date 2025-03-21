#!/bin/sh

set -e

cd /tmp/liquidsoap-full/liquidsoap
eval "$(opam config env)"
OCAMLPATH="$(cat ../.ocamlpath)"
export OCAMLPATH

printf "Memory usage before loading all libraries: "
dune exec --display=quiet -- src/bin/liquidsoap.exe --no-stdlib --check 'print(runtime.mem_usage.prettify_bytes(runtime.mem_usage().process_physical_memory))'

printf "Memory usage after loading all libraries: "
dune exec --display=quiet -- src/bin/liquidsoap.exe --check 'print(runtime.memory().pretty.process_physical_memory)'

printf "Number of core functions: "
dune exec --display=quiet -- src/bin/liquidsoap.exe --no-stdlib --list-functions | wc -l
echo
printf "Number of functions: "
./liquidsoap --list-functions | wc -l
