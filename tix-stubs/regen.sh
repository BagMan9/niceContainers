#!/usr/bin/env bash
# Bootstrap the SHAPE of the cfg type from the module's own option declarations.
#
# The committed tix-stubs/nice-containers.tix is HAND-MAINTAINED — normally you
# just edit it directly. Run this only after a big options overhaul when you'd
# rather re-derive the structure: it writes nice-containers.generated.tix (a
# separate file), which you then diff against the hand file and port over,
# fixing the opaque `{ ... }` leaves back to string/int.
#
# `tix` is not on the global PATH (it lives in the Neovim-wrapped env); resolve
# from the nix store. Requires the flake to be locked (`nix flake lock`).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIX="$(command -v tix || ls -d /nix/store/*-tix-*/bin/tix 2>/dev/null | tail -1 || true)"
[ -n "$TIX" ] || { echo "error: no tix binary found" >&2; exit 1; }

"$TIX" stubs generate module \
  --name nice-containers \
  --max-depth 8 \
  --options-expr "(let f = builtins.getFlake \"path:$ROOT\"; in (f.inputs.nixpkgs.lib.nixosSystem { system = \"x86_64-linux\"; modules = [ f.nixosModules.default ]; }).options.niceContainers)" \
  --context-arg cfg \
  -o "$ROOT/tix-stubs/nice-containers.generated.tix"

echo "Wrote tix-stubs/nice-containers.generated.tix."
echo "Diff it against nice-containers.tix and port new options (fixing string/int leaves)."
