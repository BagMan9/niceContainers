# Everything the niceContainers module at `module` makes of tests/fixture.nix.
# `toplevel` is the whole system's derivation, so two versions of the module
# with the same `toplevel` give the host the same system; the other attributes
# only say where a difference is.
{ nixpkgs, module }:
let
  inherit (nixpkgs) lib;
  inherit
    (lib.nixosSystem {
      modules = [
        module
        ./fixture.nix
      ];
    })
    config
    ;
  units = [
    "sabnzbd.service"
    "jellyfin.service"
    "helper-daemon.service"
    "rule-config.service"
    "unbound.service"
  ];
in
{
  toplevel = config.system.build.toplevel.drvPath;
  units = lib.mapAttrs (_: u: u.text) (
    lib.filterAttrs (n: _: lib.hasPrefix "nice-netns-" n || lib.elem n units) config.systemd.units
  );
  networkd = lib.mapAttrs (_: u: u.text) config.systemd.network.units;
  networkdConfig = config.environment.etc."systemd/networkd.conf".text;
  nftables = config.networking.nftables.tables;
  sysctl = lib.filterAttrs (n: _: lib.hasPrefix "net." n) config.boot.kernel.sysctl;
  groups = lib.attrNames config.users.groups;
  activation = config.system.activationScripts.niceContainers-netdevs.text;
  inherit (config.boot) kernelModules;
  inherit (config.networking.firewall) checkReversePath;
  unbound = config.services.unbound.settings;
  api = config.niceContainers.api.containers;
}
