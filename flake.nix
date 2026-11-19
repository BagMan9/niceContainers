{
  description = "niceContainers — declarative isolated container networking (systemd-networkd + nftables)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = _: {
    # The NixOS module. Import as inputs.niceContainers.nixosModules.default.
    # A path, not `import ./default.nix`: the module system then knows the
    # file (for errors and option docs) and imports it once even when both
    # names are imported.
    nixosModules.default = ./default.nix;
    nixosModules.niceContainers = ./default.nix;
  };
}
