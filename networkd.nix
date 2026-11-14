{
  # type: lib :: Lib
  lib,
  # type: cfg :: import("./default.nix").NiceContainersConfig
  cfg,
  # type: model :: import("./model.nix").NiceContainersModel
  model,
}:
let
  inherit (builtins) listToAttrs filter;
  inherit (lib)
    # type: nameValuePair :: string -> a -> {name: string, value: a}
    nameValuePair
    # type: mapAttrs' :: (string -> a -> {name: string, value: b}) -> {_: a} -> {_: b}
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
          address,
          vrf ? false,
        }:
        {
          matchConfig.Name = names.svi name;
          networkConfig = {
            Address = address;
            VRF = lib.mkIf vrf <| names.vrf name;
            ConfigureWithoutCarrier = true;
            IPv4Forwarding = true;
          };
          routes = lib.mkIf (name == "host-binds") [
            {
              Destination = model.sviDict."host-binds".subnet;
              Scope = "link";
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
          # type: string
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
in
{
  devices = {
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
      )
      <| filter (s: s.svi ? vrf) sviList
    );
  };
  networks = {

    egress = listToAttrs (
      map ({ svi, ... }@def: nameValuePair "40-${svi.wan}" (templates.networks.sviEgress def))
      <| filter (s: s.svi ? wan) sviList
    );

    container = {
      isolated = mapAttrs' (
        serviceName: config:
        let
          name = config.trunkConfig.isolated.hostDev;
          isoGroups = filter ({ dev, ... }: dev == cfg.interfaceConfig.isolatedTrunk) (
            builtins.attrValues config.groupVlans
          );
        in
        nameValuePair "20-${name}" (
          templates.networks.isolatedBridgePort {
            inherit name;
            sviVlan = config.egressVlan;
            vlanList = isoGroups;
          }
        )
      ) evalContainers;
      free = mapAttrs' (
        serviceName: config:
        let
          name = config.trunkConfig.free.hostDev;
          freeGroups = filter ({ dev, ... }: dev == cfg.interfaceConfig.freeTrunk) (
            builtins.attrValues config.groupVlans
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
      map ({ svi, ... }@def: nameValuePair "20-${svi.vrf}" (templates.networks.vrf def))
      <| filter (s: s.svi ? vrf) sviList
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
        }:
        nameValuePair "10-${name}" (
          templates.networks.svi {
            inherit name;
            vrf = svi ? vrf;
            address = subnet.gateway.wMask;
          }
        )
      ) sviList
    );
  };
}
