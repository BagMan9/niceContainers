{
  description = "niceContainers — declarative isolated container networking (systemd-networkd + nftables)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    {
      # The NixOS module. Import as inputs.niceContainers.nixosModules.default.
      nixosModules.default = import ./default.nix;
      nixosModules.niceContainers = import ./default.nix;
    };
}
