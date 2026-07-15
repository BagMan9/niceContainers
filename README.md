# niceContainers

Declarative isolated container networking for NixOS — per-container VLANs, VRF
egress routing, systemd-networkd + nftables plumbing, driven by a single
`niceContainers` option tree.

## Use

```nix
# flake.nix inputs
niceContainers.url = "path:/Users/isaac/Dev/niceContainers";
niceContainers.inputs.nixpkgs.follows = "nixpkgs";

# in a NixOS host
imports = [ inputs.niceContainers.nixosModules.default ];
niceContainers = {
  enable = true;
  hostWan = "enp42s0";
  # egress, groupConfig, containers, ...
};
```

## Layout

- `default.nix` — the NixOS module: the `niceContainers` options schema + config wiring.
- `model.nix` — derives the network model (vlans, egress, per-container eval) from `cfg`.
- `lib.nix` — pure helpers (IP/subnet math, hashing).
- `networkd.nix` / `systemd.nix` / `activation.nix` — emit systemd-networkd, units, and activation scripts from the model.

## Typing (tix)

`tix.toml` + `tix-stubs/nice-containers.tix` give the tix LSP types for `cfg` /
`model` / `config` (which it can't infer, since it doesn't evaluate the module
system). The stub is hand-maintained — edit it when you change `default.nix`
options. See the stub header and `tix-stubs/regen.sh`.
