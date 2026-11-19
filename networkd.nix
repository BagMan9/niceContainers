# systemd-networkd: the bridge, the VLAN interfaces (SVIs) and VRFs on the
# host side, and each container's bridge ports.
{ config, lib, ... }:
let
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
  inherit (lib)
    nameValuePair
    mapAttrs'
    listToAttrs
    filter
    ;
  inherit (model) sviList names;
  inherit (cfg.interfaceConfig) bridgeName;

  egressVlans = filter (s: s.svi ? wan) sviList;
  vrfVlans = filter (s: s.svi ? vrf) sviList;
  # One networkd unit per VLAN, named "<prio>-<name s>".
  unitsFor =
    prio: name: mk: vlans:
    listToAttrs (map (s: nameValuePair "${prio}-${name s}" (mk s)) vlans);

  # A container's end of a trunk on the bridge. On the isolated trunk it is
  # an isolated port, and untagged traffic on it is its egress VLAN.
  containerPorts =
    trunk:
    let
      isolated = trunk == "isolated";
    in
    mapAttrs' (
      _: c:
      let
        port = c.trunkConfig.${trunk};
        egress = if isolated then c.egressVlan else null;
      in
      nameValuePair "20-${port.hostDev}" (
        {
          matchConfig.Name = port.hostDev;
          networkConfig = {
            Bridge = bridgeName;
            LinkLocalAddressing = false;
          };
          linkConfig.RequiredForOnline = false;
          bridgeVLANs =
            lib.optional (egress != null) {
              VLAN = egress.vid;
              PVID = egress.vid;
              EgressUntagged = egress.vid;
            }
            ++ map (v: { VLAN = v.vid; }) (filter (v: v.dev == port.dev) (lib.attrValues c.groupVlans));
        }
        // lib.optionalAttrs isolated { bridgeConfig.Isolated = true; }
      )
    ) model.evalContainers;
in
{
  config = lib.mkIf cfg.enable {
    networking.useNetworkd = true;
    systemd.network = {
      enable = true;
      config = {
        addRouteTablesToIPRoute2 = true;
        routeTables = model.vrfTables;
      };

      netdevs = lib.mkMerge [
        (unitsFor "10" (s: s.name) (s: {
          netdevConfig = {
            Kind = "vlan";
            Name = names.svi s.name;
          };
          vlanConfig.Id = s.vid;
        }) sviList)
        (unitsFor "10" (s: s.svi.vrf) (s: {
          netdevConfig = {
            Name = s.svi.vrf;
            Kind = "vrf";
          };
          vrfConfig.Table = model.vrfTables.${names.vrfRoutingTable s.name};
        }) vrfVlans)
        {
          "20-${bridgeName}" = {
            netdevConfig = {
              Name = bridgeName;
              Kind = "bridge";
            };
            bridgeConfig = {
              VLANFiltering = true;
              DefaultPVID = "none";
              STP = false;
              MulticastSnooping = true;
            };
          };
        }
      ];

      networks = lib.mkMerge [
        (unitsFor "10" (s: s.name) (s: {
          matchConfig.Name = names.svi s.name;
          networkConfig = {
            Address = [ s.subnet.gateway.wMask ] ++ lib.optional (s ? subnet6) s.subnet6.gateway.wMask;
            VRF = lib.mkIf (s.svi ? vrf) s.svi.vrf;
            ConfigureWithoutCarrier = true;
            IPv4Forwarding = true;
          };
          routes = lib.mkIf (s.routedFromMain or false) (
            [
              {
                Destination = s.subnet;
                Scope = "link";
                Table = "main";
              }
            ]
            ++ lib.optional (s ? subnet6) {
              Destination = s.subnet6;
              Table = "main";
            }
          );
        }) sviList)
        {
          "20-${bridgeName}" = {
            matchConfig.Name = bridgeName;
            networkConfig = {
              ConfigureWithoutCarrier = true;
              LinkLocalAddressing = false;
              VLAN = map (s: names.svi s.name) sviList;
            };
            bridgeVLANs = map (s: { VLAN = s.vid; }) sviList;
          };
        }
        (unitsFor "20" (s: s.svi.vrf) (s: {
          matchConfig.Name = s.svi.vrf;
          networkConfig.ConfigureWithoutCarrier = true;
          routes = [
            {
              Destination = "0.0.0.0/0";
              Type = "unreachable";
              Metric = 4278198272;
              Table = names.vrfRoutingTable s.name;
            }
          ];
        }) vrfVlans)
        (unitsFor "40" (s: s.svi.wan) (s: {
          matchConfig.Name = s.svi.wan;
          networkConfig.VRF = s.svi.vrf;
          routes = [
            {
              Destination = "0.0.0.0/0";
              Scope = "link";
              Metric = 10;
            }
          ];
        }) egressVlans)
        (containerPorts "isolated")
        (containerPorts "free")
        (lib.optionalAttrs (cfg.forwardInterfaces != [ ]) {
          "10-generic" = {
            matchConfig.Name = "lo";
            routingPolicyRules = [
              {
                FirewallMark = 1;
                Priority = 11;
                Table = "main";
                # A rule with no address is IPv4 only unless told otherwise.
                Family = "both";
              }
              {
                Priority = 12;
                L3MasterDevice = true;
              }
            ]
            ++ lib.optional cfg.interfaceConfig.fixTailscale {
              FirewallMark = 1;
              Priority = 10;
              Table = 52;
              Family = "both";
            }
            ++ lib.imap (i: s: {
              To = toString s.subnet;
              Priority = 50 + i;
              Table = model.vrfTables.${names.vrfRoutingTable s.name};
            }) egressVlans;
          };
        })
      ];
    };
  };
}
