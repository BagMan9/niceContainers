# The network model: every VLAN, its numbers and subnet, and each enabled
# container's interfaces and addresses, all computed from `cfg` (the
# niceContainers options). Pure; the modules turn it into host config.
{ lib, cfg }:
let
  inherit (lib)
    nameValuePair
    imap0
    mapAttrsToList
    concatMapAttrs
    optionalAttrs
    ;
  inherit (builtins) filter listToAttrs mapAttrs;
  utils = import ./net.nix { inherit lib; };
  inherit (cfg) interfaceConfig;

  enabledContainers = lib.filterAttrs (_: c: c.enable) cfg.containers;
  # "master@<group>" joins <group> over the free trunk, so it reaches every
  # member even when the group is isolated.
  parseGroupRef = g: {
    isMaster = lib.hasPrefix "master@" g;
    name = lib.removePrefix "master@" g;
  };
  containerGroups = lib.lists.uniqueStrings (
    lib.concatLists (
      mapAttrsToList (_: { groups, ... }: map (g: (parseGroupRef g).name) groups) enabledContainers
    )
  );

  # Interface names are at most 15 characters.
  truncIfname =
    prefix: name: "${prefix}${builtins.substring 0 (15 - builtins.stringLength prefix) name}";

  names = {
    netnsUnit = containerName: "nice-netns-${containerName}";
    isoBridgeTrunk = truncIfname "vi-";
    freeBridgeTrunk = truncIfname "vf-";
    containerSub =
      { name, vid }:
      let
        suffix = ".${toString vid}";
      in
      "${builtins.substring 0 (15 - builtins.stringLength suffix) name}${suffix}";
    svi = egressName: "${egressName}-svi";
    vrf = egressName: "${egressName}-vrf";
    vrfRoutingTable = egressName: builtins.replaceStrings [ "-" ] [ "" ] "${egressName}vrf";
  };

  # A VID from config, or from the name's hash when config leaves it 0.
  autoVid =
    name: configured:
    if configured == 0 then
      builtins.bitAnd (utils.strHashToInt (builtins.hashString "sha256" name) 0 3) 1023 + 1
    else
      configured;
  egressVid = name: autoVid name (cfg.egress.${name}.vid or 0);
  grpVid = name: autoVid name (cfg.groupConfig.${name}.vid or 0);

  # The VLAN the host forwards `hostBinds` ports into.
  hostBindsName = "host-binds";
  localForward = {
    name = hostBindsName;
    isolated = true;
    vid = egressVid hostBindsName;
    svi = {
      vrf = names.vrf hostBindsName;
    };
    # The host forwards its ports from its IPv6 addresses too, so this VLAN
    # carries both families.
    dualStack = true;
    # Connections the host forwards in arrive outside any VRF and are routed
    # by the main table, which so needs a route to this VLAN.
    routedFromMain = true;
  };

  # NOTE: Approaching this as "gets full host routing table", might move to "gets only gateway"
  hostEgress = {
    name = "host";
    vid = egressVid "host";
    isolated = true;
    svi = { };
  };

  # Every VRF's routing table: `tableId` from config, or else 110 plus its
  # position among the VRFs in name order.
  vrfTables = listToAttrs (
    imap0 (
      i: egressName:
      let
        configured = cfg.egress.${egressName}.tableId or 0;
      in
      nameValuePair (names.vrfRoutingTable egressName) (if configured == 0 then i + 110 else configured)
    ) (builtins.sort builtins.lessThan (lib.attrNames cfg.egress ++ [ hostBindsName ]))
  );

  vlanDefs =
    mapAttrsToList (name: egress: {
      inherit name;
      svi = {
        wan = egress.wanInterface;
        vrf = names.vrf name;
      };
      vid = egressVid name;
      isolated = true;
    }) cfg.egress
    ++ map (name: {
      inherit name;
      svi = null;
      isolated = cfg.groupConfig.${name}.isolated or false;
      ipv6 = cfg.groupConfig.${name}.ipv6 or false;
      vid = grpVid name;
    }) containerGroups
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
      subnet6 = utils.net.subnet6 "${interfaceConfig.ulaPrefix}:${toString d.vid}";
    in
    d
    // {
      subnet =
        if d.ipv6 or false then
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

  # VLANs with an interface on the host (egresses, host-binds, host) and
  # VLANs that only join containers (groups).
  sviList = filter (v: v.svi != null) vlans;
  sviDict = listToAttrs (map (v: nameValuePair v.name v) sviList);
  grpDict = listToAttrs (map (v: nameValuePair v.name v) (filter (v: v.svi == null) vlans));
  hostBindsVlan = sviDict.${hostBindsName};

  processContainer =
    name:
    {
      egress,
      groups,
      hostBinds,
      ...
    }@attrs:
    let
      hash = builtins.hashString "sha256" name;
      mkMac = utils.hashToPostMac hash;
      # One veth pair per trunk: `dev` inside the namespace, `hostDev` on the
      # bridge.
      trunk = dev: hostDev: macOffset: {
        inherit dev hostDev;
        nearMac = "12:${mkMac macOffset}";
        hostMac = "02:${mkMac macOffset}";
      };
      groupVlan =
        g:
        let
          grp = parseGroupRef g;
          groupDef = grpDict.${grp.name};
          dev =
            if !grp.isMaster && groupDef.isolated then
              interfaceConfig.isolatedTrunk
            else
              interfaceConfig.freeTrunk;
        in
        nameValuePair grp.name {
          inherit dev;
          inherit (groupDef) vid;
          addr = groupDef.subnet.fromHash hash;
          name = names.containerSub {
            inherit (grp) name;
            inherit (groupDef) vid;
          };
        };
    in
    {
      trunkConfig = {
        free = trunk interfaceConfig.freeTrunk (names.freeBridgeTrunk name) 10;
        isolated =
          trunk interfaceConfig.isolatedTrunk (names.isoBridgeTrunk name) 0
          // optionalAttrs (egress != "") {
            addr = sviDict.${egress}.subnet.fromHash hash;
            gw = sviDict.${egress}.subnet.gateway.noMask;
          };
      };
      egressVlan = sviDict.${egress} or null;
      groupVlans =
        listToAttrs (map groupVlan groups)
        // optionalAttrs (hostBinds != [ ]) {
          ${hostBindsName} = {
            inherit (localForward) vid;
            addr = hostBindsVlan.subnet.fromHash hash;
            addr6 = hostBindsVlan.subnet6.fromHash hash;
            gw6 = hostBindsVlan.subnet6.gateway.noMask;
            dev = interfaceConfig.isolatedTrunk;
            name = names.containerSub {
              name = hostBindsName;
              inherit (localForward) vid;
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

  # The members of group `name`, by container name: their address in it and
  # whether they joined over the isolated trunk.
  groupAddrMap =
    name:
    concatMapAttrs (
      c:
      { groupVlans, ... }:
      optionalAttrs (groupVlans ? ${name}) {
        ${c} = {
          inherit (groupVlans.${name}) addr;
          isolated = groupVlans.${name}.dev == interfaceConfig.isolatedTrunk;
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
    sviList
    evalContainers
    groupAddrMap
    ;
  hostBinds = hostBindsVlan;
}
