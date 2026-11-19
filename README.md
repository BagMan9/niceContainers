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
  # egress, groupConfig, ...
  containers.sabnzbd = {
    egress = "nyc";
    groups = [ "download" ];
  };
};

# A container wraps the systemd service of the same name (`matchSystemd`
# picks another). Its single-valued settings sit between a service module's
# and mkForce, so opting out of one is an ordinary override on the unit:
systemd.services.sabnzbd.serviceConfig.PrivateDevices = lib.mkForce false;
```

## What a container is at run time

Two units. `nice-netns-<name>.service` creates the network namespace
`/run/netns/<name>`, its veth pairs to the bridge and its VLAN interfaces. The
wrapped service joins that namespace (`NetworkNamespacePath=`) and is bound to
the unit, so the namespace survives a restart of the service and the service
stops if the namespace goes away. `ip netns exec <name> ip -br addr` looks
inside one.

## Layout

- `default.nix` — the NixOS module: the `niceContainers` options schema + config wiring.
- `model.nix` — derives the network model (vlans, egress, per-container eval) from `cfg`.
- `lib.nix` — pure helpers (IP/subnet math, hashing).
- `networkd.nix` / `systemd.nix` / `activation.nix` — emit systemd-networkd, units, and activation scripts from the model.

## Typing (tix)

tix can't infer `cfg` / `model` on its own (it doesn't evaluate the NixOS module
system), so their shapes live as doc-comment `type` aliases in the files that own
them — `NiceContainersConfig` atop `default.nix`, `NiceContainersModel` atop
`model.nix` — and each module file references them with inline annotations on its
parameters, e.g. `# type: cfg :: import("./default.nix").NiceContainersConfig`.
No `.tix` stub, no `[context]` — just `[project]` background inference in
`tix.toml`. The aliases are hand-maintained: edit them when you change the
`default.nix` options / `model.nix` return (they must be self-contained — inline
nested shapes, since cross-file `import().Alias` drops sibling references).
`regen-types.sh` re-derives the shape to help port big option changes.
