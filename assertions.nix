# Configs the module can't build a working network from, rejected at
# evaluation rather than failing on the host.
{ config, lib, ... }:
let
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
  net = import ./net.nix { inherit lib; };
  inherit (lib)
    attrValues
    mapAttrsToList
    concatMap
    concatStringsSep
    filter
    length
    ;
  containers = model.evalContainers;
  # By VID: an egress and a group may share a name, but not a VID.
  vlanByVid = lib.listToAttrs (map (v: lib.nameValuePair (toString v.vid) v) model.vlans);

  # Fails when two `items` (each with a `name`) have the same `key`.
  noClash =
    what: key: items:
    let
      clashing = lib.filterAttrs (_: g: length g > 1) (lib.groupBy (i: toString (key i)) items);
    in
    {
      assertion = clashing == { };
      message = "niceContainers: these share ${what}: ${
        concatStringsSep "; " (
          mapAttrsToList (k: g: "${k} (${concatStringsSep ", " (map (i: i.name) g)})") clashing
        )
      }";
    };
  # Fails when `bad` is non-empty, listing it.
  none = what: bad: {
    assertion = bad == [ ];
    message = "niceContainers: ${what}: ${concatStringsSep ", " bad}";
  };

  # Every address a container has, by VLAN.
  memberships = concatMap (
    { name, c }:
    lib.optional (c.egressVlan != null) {
      inherit name;
      vlan = c.egress;
      inherit (c.egressVlan) vid;
      addr = c.trunkConfig.isolated.addr.noMask;
    }
    ++ mapAttrsToList (vlan: leg: {
      inherit name vlan;
      inherit (leg) vid;
      addr = leg.addr.noMask;
    }) c.groupVlans
  ) (mapAttrsToList (name: c: { inherit name c; }) containers);
  # The addresses in a subnet no container may hash to.
  reservedIn =
    s:
    [ s.gateway.noMask ]
    ++ lib.optionals (s ? network) [
      (net.formatIpv4 s.network)
      s.broadcast.noMask
    ];

  v4 = filter (v: v.subnet ? network) model.vlans;
  size = s: net.pow2 (32 - s.prefixLength);
  overlaps = a: b: a.network < b.network + size b && b.network < a.network + size a;
  poolEnd = model.pool.network + size model.pool;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      (none "names reserved for built-in VLANs" (
        filter (n: cfg.egress ? ${n} || lib.any (v: v.svi == null && v.name == n) model.vlans) [
          "host"
          model.hostBinds.name
        ]
      ))
      (none "containers whose egress is not defined in niceContainers.egress" (
        mapAttrsToList (n: c: "${n} (${c.egress})") (
          lib.filterAttrs (
            _: c: c.egress != "" && c.egress != "host" && !(cfg.egress ? ${c.egress})
          ) containers
        )
      ))
      (none "containers with forwardPorts but no egress to forward from" (
        lib.attrNames (lib.filterAttrs (_: c: c.forwardPorts != [ ] && c.egress == "") containers)
      ))
      (noClash "a systemd service (matchSystemd)" (i: i.unit) (
        mapAttrsToList (name: c: {
          inherit name;
          unit = c.matchSystemd;
        }) containers
      ))
      (noClash "a VLAN ID" (v: v.vid) model.vlans)
      (noClash "a VRF routing table" (t: t.table) (
        mapAttrsToList (name: table: { inherit name table; }) model.vrfTables
      ))
      # Interface names are cut to 15 characters, so long names can meet.
      (noClash "a bridge port name" (p: p.ifname) (
        concatMap (
          { name, value }:
          map (t: {
            inherit name;
            ifname = t.hostDev;
          }) (attrValues value.trunkConfig)
        ) (lib.attrsToList containers)
      ))
      (noClash "a VLAN interface name inside one container" (i: i.ifname) (
        concatMap (
          { name, value }:
          mapAttrsToList (_: leg: {
            inherit name;
            ifname = "${name}/${leg.name}";
          }) value.groupVlans
        ) (lib.attrsToList containers)
      ))
      # Host parts are hashed from names, so two members of a VLAN can draw
      # the same one.
      (noClash "an address" (m: "${m.addr} in ${m.vlan}") memberships)
      (none
        "containers whose hashed address is reserved in its VLAN (rename one, or give the VLAN another subnet)"
        (
          map (m: "${m.name} (${m.addr} in ${m.vlan})") (
            filter (m: lib.elem m.addr (reservedIn vlanByVid.${toString m.vid}.subnet)) memberships
          )
        )
      )
      (none "IPv6 groups that set an IPv4 subnet" (
        map (v: v.name) (filter (v: v.ipv6 or false && v.configuredSubnet or null != null) model.vlans)
      ))
      (none "VLAN subnets smaller than /30" (
        map (v: "${v.name} (${toString v.subnet})") (filter (v: v.subnet.prefixLength > 30) v4)
      ))
      (none "VLAN subnets that overlap" (
        concatMap (
          i:
          let
            a = lib.elemAt v4 i;
          in
          map (b: "${a.name} (${toString a.subnet}) and ${b.name} (${toString b.subnet})") (
            filter (b: overlaps a.subnet b.subnet) (lib.drop (i + 1) v4)
          )
        ) (lib.range 0 (length v4 - 1))
      ))
      (none
        "VLANs whose slot falls outside interfaceConfig.baseSubnet (${cfg.interfaceConfig.baseSubnet}; slots 0-9 are left unused)"
        (
          map (v: "${v.name} (${toString v.subnet})") (
            filter (
              v:
              v.configuredSubnet or null == null
              && (
                cfg.interfaceConfig.subnetPrefixLength < model.pool.prefixLength
                || v.subnet.network + size v.subnet > poolEnd
              )
            ) v4
          )
        )
      )
    ];
    warnings = lib.optional (
      cfg.forwardInterfaces == [ ] && lib.any (c: c.hostBinds != [ ]) (attrValues containers)
    ) "niceContainers: hostBinds are set but forwardInterfaces is empty, so no port is forwarded.";
  };
}
