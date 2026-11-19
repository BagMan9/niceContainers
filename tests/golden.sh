#!/usr/bin/env bash
# Usage: tests/golden.sh [REF]   (REF defaults to master)
#
# Evaluates tests/fixture.nix against the module as of REF and as in the
# working tree, with the same nixpkgs (from flake.lock), and diffs the two.
# An empty diff means the change gives the host the same system. Eval only:
# nothing is built, so it runs on any platform.
set -euo pipefail
root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ref="${1:-master}"
rev="$(jq -r .nodes.nixpkgs.locked.rev "$root/flake.lock")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir "$work/base"
git -C "$root" archive "$ref" | tar -x -C "$work/base"

evalAt() {
  nix eval --json --impure --expr "
    import $root/tests/golden.nix {
      nixpkgs = builtins.getFlake \"github:nixos/nixpkgs/$rev\";
      module = $1/default.nix;
    }" | jq -S . >"$2"
}
evalAt "$work/base" "$work/base.json"
evalAt "$root" "$work/head.json"

diff -u --label "$ref" --label "working tree" "$work/base.json" "$work/head.json"
echo "golden: identical to $ref"
