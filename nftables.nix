# nftables: masquerade out of each egress, and the DNAT maps for
# `forwardPorts` and `hostBinds`.
{ config, lib, ... }:
let
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
  inherit (lib) mapAttrsToList concatMap concatStringsSep;
  inherit (builtins) filter match;
  inherit (model) sviList;
in
{
  config = lib.mkIf cfg.enable {
    networking.nftables = {
      enable = true;
      tables = {
        hostRouting =
          let
            pairs = lib.concatMapStringsSep ", " (s: ''${s.subnet} . "${s.svi.wan or cfg.hostWan}"'') (
              filter ({ svi, ... }: svi != null) sviList
            );
          in
          {
            enable = sviList != [ ];
            family = "inet";
            content = ''
              set egress_msq {
                type ipv4_addr . ifname
                flags interval
                elements = {${pairs}}
              }
              chain postrouting {
                type nat hook postrouting priority srcnat;
                ip saddr . oifname @egress_msq masquerade
              }'';
          };
        vrfPortForwards =
          let
            parsePortForward =
              def:
              let
                idxParse = builtins.elemAt (match "([[:digit:]]+):([[:digit:]]+)(/tcp|/udp)?" def);
              in
              {
                egressSide = idxParse 0;
                containerSide = idxParse 1;
                proto =
                  let
                    pro = idxParse 2;
                  in
                  if (pro != null) then lib.removePrefix "/" pro else "tcp";
              };
            getMeta =
              container:
              let
                egressVlan = container.egressVlan;
                svi = if egressVlan != null then egressVlan.svi else null;
              in
              {
                ifname = if svi != null then svi.wan or cfg.hostWan else cfg.hostWan;
                ip = container.trunkConfig.isolated.addr.noMask;
              };
            entryToString =
              entry:
              "${entry.proto} . ${entry.ifname} . ${entry.egressSide} : ${entry.ip} . ${entry.containerSide}";
            mkContainerEntry =
              container:
              let
                meta = getMeta container;
              in
              map (p: entryToString ((parsePortForward p) // meta)) cfg.containers.${container.name}.forwardPorts;
            fwds = concatMap mkContainerEntry (mapAttrsToList (n: v: v // { name = n; }) model.evalContainers);
          in
          {
            enable = fwds != [ ];
            content = ''
              map vrf_fwd_map {
              type inet_proto . ifname . inet_service : ipv4_addr . inet_service
              elements = { ${concatStringsSep ", " fwds} }
              }

              chain prerouting {
              type nat hook prerouting priority -100;
              fib daddr type local dnat ip to meta l4proto . iifname . th dport map @vrf_fwd_map
              }
            '';
            family = "inet";
          };
        hostBinds =
          let
            hostBindsIface = model.names.svi "host-binds";
            # Past prerouting the kernel names the VRF, not the interface
            # enslaved to it, as where a packet came in.
            hostBindsIn = ''{ "${hostBindsIface}", "${model.names.vrf "host-binds"}" }'';
            parseForwardPartial =
              def:
              let
                idxParse = builtins.elemAt (match "([[:digit:]]+):([[:digit:]]+)(/tcp|/udp)?" def);
              in
              map (iface: {
                hostSide = idxParse 0;
                containerSide = idxParse 1;
                proto =
                  let
                    pro = idxParse 2;
                  in
                  if (pro != null) then lib.removePrefix "/" pro else "tcp";
                ifname = iface;
              }) cfg.forwardInterfaces;
            entryToString =
              entry:
              "${entry.proto} . ${entry.ifname} . ${entry.hostSide} : ${entry.ip} . ${entry.containerSide}";
            # `pick` chooses the family: the leg's `addr` or its `addr6`.
            mkContainerEntries =
              pick: container:
              map (e: entryToString (e // { ip = (pick container.groupVlans."host-binds").noMask; })) (
                concatMap (p: parseForwardPartial p) cfg.containers.${container.name}.hostBinds
              );
            fwdsOf =
              pick:
              concatMap (mkContainerEntries pick) (
                mapAttrsToList (n: v: v // { name = n; }) model.evalContainers
              );
            fwds = fwdsOf (leg: leg.addr);
            fwds6 = fwdsOf (leg: leg.addr6);
          in
          {
            family = "inet";
            enable = fwds != [ ];
            content = ''
              map host_bind_map {
                type inet_proto . ifname . inet_service : ipv4_addr . inet_service
                elements = { ${concatStringsSep ", " fwds} }
              }
              map host_bind_map6 {
                type inet_proto . ifname . inet_service : ipv6_addr . inet_service
                elements = { ${concatStringsSep ", " fwds6} }
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
