# Host-wide settings: forwarding, groups for container mounts, DNS, and the
# evaluated containers exported as `niceContainers.api.containers`.
{ config, lib, ... }:
let
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
in
{
  config = lib.mkIf cfg.enable {
    niceContainers.api.containers = model.evalContainers;
    users.groups =
      let
        allResource = lib.concatMap (c: c.mounts) (lib.attrValues model.enabledContainers);
      in
      lib.genAttrs (map (r: r.group) allResource) (_: { });
    # TODO: Move unbound to be containerized, and be the sole non-isolated container on egress vlans, such that it can function as the dns for everything on that VLAN (would allow future non-shared lookups by interface, etc)
    services.unbound = {
      enable = true;
      settings = {
        server = {
          access-control = [ "0.0.0.0/0 allow" ];
          interface = "10.10.0.0";
          interface-automatic = true;
          tls-cert-bundle = "/etc/ssl/certs/ca-certificates.crt";
        };
        forward-zone = [
          {
            name = ".";
            forward-tls-upstream = true;
            forward-addr = [
              "9.9.9.10@853#dns10.quad9.net"
              "149.112.112.10@853#dns10.quad9.net"
              "2620:fe::10@853#dns10.quad9.net"
              "2620:fe::fe:10@853#dns10.quad9.net"
            ];
          }
        ];
      };
    };

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

    boot.kernelModules = [ "wireguard" ]; # NOTE: Probably unnecessary
    networking.firewall.checkReversePath = false;
  };
}
