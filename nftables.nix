# nftables: masquerade out of each egress, and the DNAT maps for
# `forwardPorts` and `hostBinds`.
{ config, lib, ... }:
let
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
  net = import ./net.nix { inherit lib; };
  inherit (lib) concatMap concatStringsSep;
  inherit (model) sviList names;
  containers = lib.attrValues model.evalContainers;

  # One element of a DNAT map: "<proto> . <in-iface> . <port> : <addr> . <port>".
  mapElement =
    ifname: addr: spec:
    let
      p = net.parsePortSpec spec;
    in
    "${p.proto} . ${ifname} . ${p.outer} : ${addr} . ${p.inner}";

  vrfFwds = concatMap (
    c:
    map (mapElement (c.egressVlan.svi.wan or cfg.hostWan
    ) c.trunkConfig.isolated.addr.noMask) c.forwardPorts
  ) containers;

  # `addrOf` picks the family: the host-binds leg's `addr` or its `addr6`.
  hostBindFwds =
    addrOf:
    concatMap (
      c:
      concatMap (
        spec:
        map (
          ifname: mapElement ifname (addrOf c.groupVlans.${model.hostBinds.name}).noMask spec
        ) cfg.forwardInterfaces
      ) c.hostBinds
    ) containers;
  hostFwds = hostBindFwds (leg: leg.addr);
  hostFwds6 = hostBindFwds (leg: leg.addr6);

  egressPairs = lib.concatMapStringsSep ", " (
    s: ''${s.subnet} . "${s.svi.wan or cfg.hostWan}"''
  ) sviList;

  hostBindsIface = names.svi model.hostBinds.name;
  # Past prerouting the kernel names the VRF, not the interface enslaved to
  # it, as where a packet came in.
  hostBindsIn = ''{ "${hostBindsIface}", "${model.hostBinds.svi.vrf}" }'';
in
{
  config = lib.mkIf cfg.enable {
    networking.nftables = {
      enable = true;
      tables = {
        hostRouting = {
          enable = sviList != [ ];
          family = "inet";
          content = ''
            set egress_msq {
              type ipv4_addr . ifname
              flags interval
              elements = {${egressPairs}}
            }
            chain postrouting {
              type nat hook postrouting priority srcnat;
              ip saddr . oifname @egress_msq masquerade
            }'';
        };

        vrfPortForwards = {
          enable = vrfFwds != [ ];
          content = ''
            map vrf_fwd_map {
            type inet_proto . ifname . inet_service : ipv4_addr . inet_service
            elements = { ${concatStringsSep ", " vrfFwds} }
            }

            chain prerouting {
            type nat hook prerouting priority -100;
            fib daddr type local dnat ip to meta l4proto . iifname . th dport map @vrf_fwd_map
            }
          '';
          family = "inet";
        };

        hostBinds = {
          family = "inet";
          enable = hostFwds != [ ];
          content = ''
            map host_bind_map {
              type inet_proto . ifname . inet_service : ipv4_addr . inet_service
              elements = { ${concatStringsSep ", " hostFwds} }
            }
            map host_bind_map6 {
              type inet_proto . ifname . inet_service : ipv6_addr . inet_service
              elements = { ${concatStringsSep ", " hostFwds6} }
            }

            chain prerouting {
              type nat hook prerouting priority -100;
              fib daddr type local dnat ip to meta l4proto . iifname . th dport map @host_bind_map
              fib daddr type local dnat ip6 to meta l4proto . iifname . th dport map @host_bind_map6
            }
            # Drop coming out
            chain forward {
              type filter hook forward priority filter - 10; policy accept;
              iifname ${hostBindsIn} ct direction original drop
            }

            chain input {
              type filter hook input priority filter - 10; policy accept;
              iifname ${hostBindsIn} ct direction original drop
            }

            # Conditional ip rule-able jump
            chain mark_in {
              type filter hook prerouting priority mangle;
              ct status dnat ct mark set 0x1
              iifname "${hostBindsIface}" meta mark set ct mark
            }
          '';
        };
      };
    };
  };
}
