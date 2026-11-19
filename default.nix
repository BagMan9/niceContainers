# The niceContainers NixOS module. Each imported file sets one part of the
# host's config; all of them derive it from the same model (model.nix).
# TODO: Add inline defs, nspawn / vm / multihost semantics
{
  imports = [
    ./options.nix
    ./host.nix
    ./networkd.nix
    ./services.nix
    ./nftables.nix
    ./activation.nix
  ];
}
