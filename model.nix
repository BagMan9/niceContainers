# The return value of this file, as a tix type, for the consumers that take it
# as `model`. Hand-maintained. The shapes are factored into the aliases below and
# stitched together with `import("./model.nix").<Alias>` references. That indirect
# form (not a bare `Subnet`) is what lets tix carry them cross-file: a consumer's
# `import("./model.nix").NiceContainersModel` resolves every same-file
# `import("./model.nix").*` transitively. (It will NOT chase an import to a
# *different* file, which is why Mount/Container are duplicated here rather than
# shared with default.nix.)
#
# Addr/Subnet come from lib.nix `net.subnet`. Addr coerces to string via
# __toString (wMask); __toString is listed in the Addr alias so tix's coercion
# arm fires. String interpolation `${addr}` is already unconstrained in tix.
/**
  type Mount = { path: string, group: string, ro: bool };
*/
/**
  type Addr = { family: int, wMask: string, noMask: string, __toString: a -> string, ... };
*/
/**
  type Subnet = {
     ip: { high: int, low: int } -> import("./model.nix").Addr,
     fromHash: string -> import("./model.nix").Addr,
     addr: [int],
     gateway: import("./model.nix").Addr,
     __toString: a -> string
   };
*/
/**
  type Subnet6 = {
     fromHash: string -> import("./model.nix").Addr,
     gateway: import("./model.nix").Addr,
     __toString: a -> string
   };
*/
/**
  type Container = {
     enable: bool,
     groups: [string],
     egress: string,
     forwardPorts: [string],
     hostBinds: [string],
     matchSystemd: string,
     syscallFilter: [string],
     mounts: [Mount],
   };
*/
/**
  type VlanEntry = {
     name: string,
     isolated: bool,
     vid: int,
     svi: { wan: string, vrf: string } | {vrf: string} | { } | null,
     subnet: import("./model.nix").Subnet | import("./model.nix").Subnet6,
     ...
   };
*/
/**
  type SviEntry = {
     name: string,
     isolated: bool,
     vid: int,
     subnet: import("./model.nix").Subnet,
     svi: { } | { wan: string, vrf: string } | {vrf: string},
     ...
  };
*/
/**
  type EvalContainer = {
     trunkConfig: {
       free: { dev: string, hostDev: string, nearMac: string, hostMac: string },
       isolated: { dev: string, hostDev: string, nearMac: string, hostMac: string, addr: import("./model.nix").Addr | null, gw: import("./model.nix").Addr },
     },
     egressVlan: VlanEntry | null,
     groupVlans: { _: { dev: string, vid: int, addr: import("./model.nix").Addr, name: string, ... } },
     groups: [string],
     matchSystemd: string,
     mounts: [Mount],
     forwardPorts: [string],
     hostBinds: [string],
     syscallFilter: [string],
     egress: string,
   };
*/
/**
  type NiceContainersModel = {
     names: {
       netnsUnit: string -> string,
       isoBridgeTrunk: string -> string,
       freeBridgeTrunk: string -> string,
       containerSub: { name: string, vid: int, ... } -> string,
       svi: string -> string,
       vrf: string -> string,
       vrfToRoutingTable: string -> string,
       vrfRoutingTable: string -> string,
     },
     vrfTables: { _: int },
     parseGroupRef: string -> { isMaster: bool, name: string, __toString: a -> string, ... },
     enabledContainers: { _: import("./model.nix").Container },
     vlans: [VlanEntry],
     sviList: [SviEntry],
     sviDict: { _: import("./model.nix").VlanEntry },
     grpDict: { _: import("./model.nix").VlanEntry },
     evalContainers: { _: import("./model.nix").EvalContainer },
     groupAddrMap: string -> { _: { addr: import("./model.nix").Addr, isolated: bool } },
   };
*/

{
  # type: lib :: Lib
  lib,
  # type: cfg :: import("./default.nix").NiceContainersConfig
  cfg,
}:
let
  inherit (lib)
    # type: nameValuePair :: string -> a -> {name: string, value: a}
    nameValuePair
    imap0
    mapAttrsToList
    concatMapAttrs
    optionalAttrs
    ;
  inherit (builtins) filter listToAttrs mapAttrs;
  utils = import ./lib.nix { inherit lib; };

  enabledContainers = lib.filterAttrs (_: c: c.enable) cfg.containers;
  parseGroupRef = g: {
    isMaster = lib.hasPrefix "master@" g;
    name = lib.removePrefix "master@" g;
    __toString = self: self.name;
  };
  containerGroups =
    enabledContainers
    |> mapAttrsToList (_: { groups, ... }: map (g: (parseGroupRef g).name) groups)
    |> lib.lists.flatten
    |> lib.lists.uniqueStrings;

  names = {
    netnsUnit = containerName: "nice-netns-${containerName}";

    isoBridgeTrunk =
      containerName:
      let
        prefix = "vi-";
        size = 15 - (builtins.stringLength prefix);
      in
      "${prefix}${builtins.substring 0 size containerName}";
    freeBridgeTrunk =
      containerName:
      let
        prefix = "vf-";
        size = 15 - (builtins.stringLength prefix);
      in
      "${prefix}${builtins.substring 0 size containerName}";
    containerSub =
      {
        name,
        vid,
        ...
      }:
      let
        postfix = toString vid;
        buffer = 14 - (builtins.stringLength postfix);
      in
      "${builtins.substring 0 buffer name}.${toString vid}";

    svi = egressName: "${egressName}-svi";

    vrf = egressName: "${egressName}-vrf";

    vrfToRoutingTable = builtins.replaceStrings [ "-" ] [ "" ];

    vrfRoutingTable = egressName: builtins.replaceStrings [ "-" ] [ "" ] "${egressName}vrf";
  };

  egressVid =
    name:
    let
      vidFromHash = hash: utils.strHashToInt hash 0 3;
      configVid = cfg.egress."${name}".vid or 0;
    in
    if (configVid == 0) then
      (x: (builtins.bitAnd x 1023) + 1) <| vidFromHash <| builtins.hashString "sha256" name
    else
      configVid;
  grpVid =
    name:
    let
      vidFromHash = hash: utils.strHashToInt hash 0 3;
      configVid = cfg.groupConfig."${name}".vid or 0;
    in
    if (configVid == 0) then
      (x: (builtins.bitAnd x 1023) + 1) <| vidFromHash <| builtins.hashString "sha256" name
    else
      configVid;

  # type: egressTable :: string -> int -> int
  egressTable =
    name: auto: if (0 == (cfg.egress.${name}.tableId or 0)) then auto else cfg.egress.${name}.tableId;

  localForward = {
    name = "host-binds";
    isolated = true;
    vid = egressVid "host-binds";
    svi = {
      vrf = names.vrf "host-binds";
    };
    # The host forwards its ports from its IPv6 addresses too, so this VLAN
    # carries both families.
    dualStack = true;
  };

  # NOTE: Approaching this as "gets full host routing table", might move to "gets only gateway"
  hostEgress = {
    name = "host";
    vid = egressVid "host";
    isolated = true;
    svi = { };
  };

  vrfTables =
    listToAttrs
    <| imap0 (i: f: f (i + 110))
    <|
      mapAttrsToList
        (
          egressName: _: i:
          nameValuePair "${names.vrfRoutingTable egressName}" (egressTable egressName i)
        )
        (
          cfg.egress
          // {
            "host-binds" = {
              wanInterface = "";
            };
          }
        );

  vlanDefs =
    let
      svi = mapAttrsToList (
        name:
        { wanInterface, ... }:
        {
          inherit name;
          svi = {
            wan = wanInterface;
            vrf = names.vrf name;
          };
          vid = egressVid name;
          isolated = true;
        }
      ) cfg.egress;
      grps = map (name: {
        svi = null;
        isolated = (cfg.groupConfig."${name}".isolated or false);
        ipv6 = (cfg.groupConfig."${name}".ipv6 or false);
        vid = grpVid name;
        inherit name;
      }) containerGroups;
    in
    svi
    ++ grps
    ++ [
      localForward
      hostEgress
    ];
  # An IPv6 group still takes its place in the IPv4 count, so switching one
  # group over leaves every other subnet, and so every other container, as
  # it was.
  vlans = imap0 (
    i: d:
    let
      # The VID's decimal digits are the subnet hextet (vid 123 is
      # ...:123::/64), to match the `<group>.123` interface names.
      subnet6 = utils.net.subnet6 "${cfg.interfaceConfig.ulaPrefix}:${toString d.vid}";
    in
    d
    // {
      subnet =
        if (d.ipv6 or false) then
          subnet6
        else
          utils.net.subnet [
            10
            (i + 10)
            0
            0
          ] 16;
    }
    // optionalAttrs (d.dualStack or false) { inherit subnet6; }
  ) vlanDefs;

  # type: sviList :: [SviEntry]
  sviList = filter (v: v.svi != null) vlans;
  # type: grpList :: [VlanEntry]
  grpList = filter (v: v.svi == null) vlans;
  sviDict = listToAttrs (map (v: nameValuePair v.name v) sviList);
  grpDict = listToAttrs (map (v: nameValuePair "${v.name}" v) grpList);

  processContainer =
    name:
    let
      # type: string
      hash = builtins.hashString "sha256" name;
      mkMac = utils.hashToPostMac hash;
      macs = {
        isolated = {
          host = "02:${mkMac 0}";
          near = "12:${mkMac 0}";
        };
        free = {
          host = "02:${mkMac 10}";
          near = "12:${mkMac 10}";
        };
      };
    in
    {
      egress,
      groups,
      hostBinds,
      ...
    }@attrs:
    let

    in
    {
      trunkConfig = {
        free = {
          dev = cfg.interfaceConfig.freeTrunk;
          hostDev = names.freeBridgeTrunk name;
          nearMac = macs.free.near;
          hostMac = macs.free.host;
        };
        isolated = {
          dev = cfg.interfaceConfig.isolatedTrunk;
          hostDev = names.isoBridgeTrunk name;
          nearMac = macs.isolated.near;
          hostMac = macs.isolated.host;
        }
        // (lib.optionalAttrs (egress != "") {
          addr = sviDict.${egress}.subnet.fromHash hash;
          gw = sviDict.${egress}.subnet.gateway.noMask;
        });
      };
      egressVlan = sviDict.${egress} or null;
      groupVlans =
        (listToAttrs (
          map (
            g:
            let
              grp = parseGroupRef g;
              groupDef = grpDict."${grp}";
              dev =
                if grp.isMaster then
                  cfg.interfaceConfig.freeTrunk
                else
                  (if groupDef.isolated then cfg.interfaceConfig.isolatedTrunk else cfg.interfaceConfig.freeTrunk);
            in
            nameValuePair "${grp}" {
              inherit dev;
              vid = groupDef.vid;
              addr = groupDef.subnet.fromHash hash;
              name = names.containerSub {
                parent = dev;
                vid = groupDef.vid;
                name = "${grp}";
              };
            }
          ) groups
        ))
        // lib.optionalAttrs (hostBinds != [ ]) {
          "host-binds" = {
            vid = sviDict."host-binds".vid;
            addr = sviDict."host-binds".subnet.fromHash hash;
            addr6 = sviDict."host-binds".subnet6.fromHash hash;
            gw6 = sviDict."host-binds".subnet6.gateway.noMask;
            dev = cfg.interfaceConfig.isolatedTrunk;
            name = names.containerSub {
              parent = cfg.interfaceConfig.isolatedTrunk;
              vid = sviDict."host-binds".vid;
              name = "host-binds";
            };
          };
        };
    }
    // {
      inherit (attrs)
        groups
        matchSystemd
        mounts
        forwardPorts
        hostBinds
        syscallFilter
        egress
        ;
    };
  evalContainers = mapAttrs processContainer enabledContainers;

  groupAddrMap =
    # type: string
    name:
    concatMapAttrs (
      c:
      { groupVlans, ... }:
      optionalAttrs (groupVlans ? "${name}") {
        ${c} = {
          addr = groupVlans."${name}".addr;
          isolated = (groupVlans."${name}".dev == cfg.interfaceConfig.isolatedTrunk);
        };
      }
    ) evalContainers;

in
{
  inherit
    names
    vrfTables
    parseGroupRef
    enabledContainers
    vlans
    sviList
    sviDict
    grpDict
    evalContainers
    groupAddrMap
    ;
}
