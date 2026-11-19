# systemd-networkd: the bridge, the VLAN interfaces (SVIs) and VRFs on the
# host side, and each container's bridge ports.
{ config, lib, ... }:
let
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
  inherit (builtins) listToAttrs filter;
  inherit (lib)
    nameValuePair
    mapAttrs'
    ;
  inherit (model)
    sviList
    evalContainers
    names
    ;
  templates = {
    netdevs = {
      svi = { name, vid, ... }: {
        netdevConfig = {
          Kind = "vlan";
          Name = names.svi name;
        };
        vlanConfig = {
          Id = vid;
        };
      };
      bridge = name: {
        netdevConfig = {
          Name = name;
          Kind = "bridge";
        };
        bridgeConfig = {
          VLANFiltering = true;
          DefaultPVID = "none";
          STP = false;
          MulticastSnooping = true;
        };
      };
      vrf = { name, ... }: {
        netdevConfig = {
          Name = name;
          Kind = "vrf";
        };
        vrfConfig = {
          Table = model.vrfTables.${names.vrfToRoutingTable name};
        };
      };
    };
    networks = {
      sviEgress = { name, svi, ... }: {
        matchConfig.Name = svi.wan;
        networkConfig = {
          VRF = names.vrf name;
        };
        routes = [
          {
            Destination = "0.0.0.0/0";
            Scope = "link";
            Metric = 10;
          }
        ];
      };
      vrf = { name, ... }: {
        matchConfig.Name = names.vrf name;
        networkConfig = {
          ConfigureWithoutCarrier = true;
        };
        routes = [
          {
            Destination = "0.0.0.0/0";
            Type = "unreachable";
            Metric = 4278198272;
            Table = names.vrfRoutingTable name;
          }
        ];
      };
      bridge = { name, sviList }: {
        matchConfig.Name = name;
        networkConfig = {
          ConfigureWithoutCarrier = true;
          LinkLocalAddressing = false;
          VLAN = map (s: names.svi s.name) sviList;
        };
        bridgeVLANs = map ({ vid, ... }: { VLAN = vid; }) sviList;
      };
      svi =
        {
          name,
          addresses,
          vrf ? false,
        }:
        {
          matchConfig.Name = names.svi name;
          networkConfig = {
            Address = addresses;
            VRF = lib.mkIf vrf (names.vrf name);
            ConfigureWithoutCarrier = true;
            IPv4Forwarding = true;
          };
          routes = lib.mkIf (name == "host-binds") [
            {
              Destination = model.sviDict."host-binds".subnet;
              Scope = "link";
              Table = "main";
            }
            {
              Destination = model.sviDict."host-binds".subnet6;
              Table = "main";
            }
          ];
        };
      isolatedBridgePort =
        {
          name,
          vlanList ? [ ],
          sviVlan ? null,
        }:
        {
          matchConfig.Name = name;
          networkConfig = {
            Bridge = cfg.interfaceConfig.bridgeName;
            LinkLocalAddressing = false;
          };
          bridgeConfig.Isolated = true;
          linkConfig.RequiredForOnline = false;
          bridgeVLANs =
            (lib.lists.optional (sviVlan != null) {
              VLAN = sviVlan.vid;
              PVID = sviVlan.vid;
              EgressUntagged = sviVlan.vid;
            })
            ++ (map ({ vid, ... }: { VLAN = vid; }) vlanList);
        };
      groupBridgePort =
        {
          name,

          vlanList,
        }:
        {
          matchConfig.Name = name;
          networkConfig = {
            Bridge = cfg.interfaceConfig.bridgeName;
            LinkLocalAddressing = false;
          };
          linkConfig.RequiredForOnline = false;
          bridgeVLANs = map ({ vid, ... }: { VLAN = vid; }) vlanList;
        };
    };
  };
  netdevs = {
    svi = listToAttrs (map (svi: nameValuePair "10-${svi.name}" (templates.netdevs.svi svi)) sviList);
    bridge = {
      "20-${cfg.interfaceConfig.bridgeName}" = templates.netdevs.bridge cfg.interfaceConfig.bridgeName;
    };

    vrf = listToAttrs (
      map (
        { svi, ... }:
        nameValuePair "10-${svi.vrf}" (
          templates.netdevs.vrf {
            name = svi.vrf;
          }
        )
      ) (filter (s: s.svi ? vrf) sviList)
    );
  };
  networks = {

    egress = listToAttrs (
      map ({ svi, ... }@def: nameValuePair "40-${svi.wan}" (templates.networks.sviEgress def)) (
        filter (s: s.svi ? wan) sviList
      )
    );

    container = {
      isolated = mapAttrs' (
        _: c:
        let
          name = c.trunkConfig.isolated.hostDev;
          isoGroups = filter ({ dev, ... }: dev == cfg.interfaceConfig.isolatedTrunk) (
            builtins.attrValues c.groupVlans
          );
        in
        nameValuePair "20-${name}" (
          templates.networks.isolatedBridgePort {
            inherit name;
            sviVlan = c.egressVlan;
            vlanList = isoGroups;
          }
        )
      ) evalContainers;
      free = mapAttrs' (
        _: c:
        let
          name = c.trunkConfig.free.hostDev;
          freeGroups = filter ({ dev, ... }: dev == cfg.interfaceConfig.freeTrunk) (
            builtins.attrValues c.groupVlans
          );
        in
        nameValuePair "20-${name}" (
          templates.networks.groupBridgePort {
            inherit name;
            vlanList = freeGroups;
          }
        )
      ) evalContainers;
    };
    vrf = listToAttrs (
      map ({ svi, ... }@def: nameValuePair "20-${svi.vrf}" (templates.networks.vrf def)) (
        filter (s: s.svi ? vrf) sviList
      )
    );
    bridge = {
      "20-${cfg.interfaceConfig.bridgeName}" = templates.networks.bridge {
        name = cfg.interfaceConfig.bridgeName;
        sviList = sviList;
      };
    };
    svi = listToAttrs (
      map (
        {
          name,
          subnet,
          svi,
          ...
        }@def:
        nameValuePair "10-${name}" (
          templates.networks.svi {
            inherit name;
            vrf = svi ? vrf;
            addresses = [ subnet.gateway.wMask ] ++ lib.optional (def ? subnet6) def.subnet6.gateway.wMask;
          }
        )
      ) sviList
    );
  };
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
        netdevs.svi
        netdevs.bridge
        netdevs.vrf
      ];
      networks = lib.mkMerge [
        networks.svi
        networks.bridge
        networks.vrf
        networks.egress
        networks.container.isolated
        networks.container.free
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
            ++ (lib.optional cfg.interfaceConfig.fixTailscale {
              FirewallMark = 1;
              Priority = 10;
              Table = 52;
              Family = "both";
            })
            ++ lib.imap (i: s: {
              To = toString s.subnet;
              Priority = 50 + i;
              Table = model.vrfTables.${names.vrfRoutingTable s.name};
            }) (filter (s: !lib.hasPrefix "host" s.name) sviList);
          };
        })
      ];
    };
  };
}
