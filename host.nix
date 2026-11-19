# Host-wide settings: forwarding, groups for container mounts, and the
# evaluated containers exported as `niceContainers.api.containers`.
{ config, lib, ... }:
let
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
  forwardsIn = lib.any (
    c: c.forwardPorts != [ ] || (c.hostBinds != [ ] && cfg.forwardInterfaces != [ ])
  ) (lib.attrValues model.evalContainers);
in
{
  config = lib.mkIf cfg.enable {
    niceContainers.api.containers = model.evalContainers;
    users.groups =
      let
        allResource = lib.concatMap (c: c.mounts) (lib.attrValues model.enabledContainers);
      in
      lib.genAttrs (map (r: r.group) allResource) (_: { });
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv4.conf.default.forwarding" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    }
    # A packet forwarded into the host-binds VRF has its source address
    # looked up in that VRF's table, which holds no route back to it. With
    # reverse-path filtering on the interface it arrived on, in either mode,
    # the kernel drops it. systemd's stock sysctl.d turns the filter on for
    # every interface, and again each time systemd-sysctl restarts, so the
    # exception has to live in sysctl.d as well.
    // lib.genAttrs (map (i: "net.ipv4.conf.${i}.rp_filter") cfg.forwardInterfaces) (_: 0);

    # Off only while the host forwards connections into containers
    # (forwardPorts, hostBinds): with it on, hostBinds connections fail.
    networking.firewall.checkReversePath = lib.mkIf forwardsIn false;
  };
}
