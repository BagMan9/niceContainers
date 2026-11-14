#!/usr/bin/env bash
# Re-bootstrap the SHAPE of the cfg type from the module's own option
# declarations, to help port big option changes into the NiceContainersConfig
# alias at the top of default.nix.
#
# That alias (and NiceContainersModel atop model.nix) is HAND-MAINTAINED —
# normally you just edit it directly. Run this only after a large options
# overhaul when you'd rather re-derive the structure: it writes
# types.generated.tix (a scratch file in tix's .tix stub syntax), which you then
# read and port BY HAND into the doc-comment `type` alias. Remember the alias
# must be self-contained (inline nested shapes — cross-file `import().Alias` does
# not carry sibling references), and fix opaque `{ ... }` leaves back to
# string/int as you port.
#
# `tix` should be on PATH; falls back to the nix store. Requires the flake to be
# locked (`nix flake lock`).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIX="$(command -v tix || ls -d /nix/store/*-tix-*/bin/tix 2>/dev/null | tail -1 || true)"
[ -n "$TIX" ] || { echo "error: no tix binary found" >&2; exit 1; }

"$TIX" stubs generate module \
  --name nice-containers \
  --max-depth 8 \
  --options-expr "(let f = builtins.getFlake \"path:$ROOT\"; in (f.inputs.nixpkgs.lib.nixosSystem { system = \"x86_64-linux\"; modules = [ f.nixosModules.default ]; }).options.niceContainers)" \
  --context-arg cfg \
  -o "$ROOT/types.generated.tix"

echo "Wrote types.generated.tix."
echo "Read it and port new/changed options into the NiceContainersConfig alias"
echo "atop default.nix (inline nested shapes; fix string/int leaves)."
