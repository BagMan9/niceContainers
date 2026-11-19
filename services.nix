# The systemd units: one per container that creates its network namespace,
# and the wrapping of the service the container runs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
  inherit (lib)
    optionals
    flatten
    nameValuePair
    mapAttrs'
    partition
    ;
  inherit (model)
    evalContainers
    groupAddrMap
    parseGroupRef
    names
    ;
  inherit (builtins)
    attrValues
    ;
  ip = "${pkgs.iproute2}/bin/ip";

  # The priority of every single-valued setting the wrapper makes: above a
  # service module's plain definition, below mkForce. At plain priority a
  # module's own `User =` or `PrivateDevices =` would conflict with the
  # wrapper's; at mkForce a unit could not opt out of one with mkForce.
  wrap = lib.mkOverride 90;
  ipCmds = {
    setUp = dev: "${ip} link set ${dev} up";
    setAddr =
      addr: dev:
      # A new IPv6 address is unusable for about a second while the kernel
      # checks for a duplicate, and the service starts before that: its first
      # connections would fail. Two names never hash to the same address.
      "${ip} addr add ${addr} dev ${dev}${lib.optionalString (addr.family == 6) " nodad"}";
    setDefaultRoute = gw: "${ip} route add default via ${gw}";

    createLink =
      {
        dev,
        hostDev,
        nearMac,
        hostMac,
        ...
      }:
      "${ip} link add ${dev} address ${nearMac} type veth peer name ${hostDev} address ${hostMac} netns /proc/1/ns/net";

    inNetns = netns: cmd: "${ip} netns exec ${netns} ${cmd}";
  };
  inherit (ipCmds)
    setUp
    setAddr
    setDefaultRoute
    createLink
    ;
  createContainerPort =
    {
      dev,
      hostDev,
      nearMac,
      hostMac,
      addr ? null,
      gw ? null,
    }:
    let
      defaultRoute = optionals (gw != null && addr != null) [
        (setAddr addr dev)
        (setDefaultRoute gw)
      ];
    in
    [
      (createLink {
        inherit
          dev
          hostDev
          nearMac
          hostMac
          ;
      })
      (setUp dev)
    ]
    ++ defaultRoute;

  # The DNS servers of containers on egress `egress`. The built-in "host"
  # egress leaves by the host's own routes, so it uses the host's servers.
  nameserversOf =
    egress:
    if egress == "host" then config.networking.nameservers else cfg.egress.${egress}.nameservers or [ ];

  # Any free table number: each namespace has its own tables.
  replyTable = "100";
  createVlanInterface =
    {
      dev,
      name,
      vid,
      addr,
      addr6 ? null,
      gw6 ? null,
    }:
    [
      "${ip} link add link ${dev} name ${name} type vlan id ${toString vid}"
      (setAddr addr name)
      (setUp name)
    ]
    # A plain default route would make every program in the
    # namespace see IPv6 as reachable and try it first, and the host forwards
    # none of it.
    ++ optionals (addr6 != null) [
      (setAddr addr6 name)
      "${ip} -6 route add default via ${gw6} dev ${name} table ${replyTable}"
      "${ip} -6 rule add from ${addr6.noMask} lookup ${replyTable}"
    ];

  containerServices = mapAttrs' (
    n: c:
    let
      p = partition (m: !m.ro) c.mounts;
      rw_mounts = p.right;
      ro_mounts = p.wrong;
      netnsUnit = "${names.netnsUnit n}.service";
      hostsText =
        let
          pairToText = n: { addr, ... }: "${addr.noMask} ${n}";
          masterFilter = _: { isolated, ... }: !isolated;
          getHosts =
            grp:
            let
              thisMap = groupAddrMap grp;
            in
            if (thisMap.${n}.isolated) then (lib.filterAttrs masterFilter thisMap) else thisMap;
        in
        pkgs.writeText "${n}-hosts" (
          lib.concatStringsSep "\n" (
            lib.mapAttrsToList pairToText (
              lib.mergeAttrsList (map (g: getHosts (parseGroupRef g).name) c.groups)
            )
            ++ [ "127.0.0.1 localhost" ]
          )
        );

      # TODO: Move unbound to be containerized, and be the sole non-isolated container on egress vlans, such that it can function as the dns for everything on that VLAN (would allow future non-shared lookups by interface, etc)
      resolveText = pkgs.writeText "${n}-resolve" (
        lib.concatMapStrings (ns: "nameserver ${ns}\n") (nameserversOf c.egress)
      );
    in
    nameValuePair c.matchSystemd {
      # The namespace outlives restarts of the service; the service never
      # outlives the namespace.
      bindsTo = [ netnsUnit ];
      after = [ netnsUnit ];
      serviceConfig = {
        NetworkNamespacePath = wrap "/run/netns/${n}";
        # Has no effect while NetworkNamespacePath is set. If that is ever
        # overridden away, the unit lands in an empty namespace, not the host's.
        PrivateNetwork = wrap true;

        # Lists add to whatever the unit already has.
        SupplementaryGroups = map (r: r.group) c.mounts;
        BindPaths = map (r: r.path) rw_mounts;
        BindReadOnlyPaths =
          (map (r: r.path) ro_mounts)
          ++ [ "${hostsText}:/etc/hosts" ]
          ++ lib.optional (c.egressVlan != null) "${resolveText}:/etc/resolv.conf";
        InaccessiblePaths = "/run/nscd";
        SystemCallFilter = c.syscallFilter;

        DynamicUser = wrap true;
        User = wrap null;
        Group = wrap null;

        NoNewPrivileges = wrap true;
        # difference between this and "yes?"
        ProtectHome = wrap true;
        ProtectClock = wrap true;
        PrivateTmp = wrap "disconnected"; # Stricter version enabled by DynamicUser
        PrivateDevices = wrap true;
        PrivateUsers = wrap true;
        ProtectKernelLogs = wrap true;
        ProtectKernelTunables = wrap true;
        ProtectKernelModules = wrap true;
        ProtectControlGroups = wrap true;
        RestrictSUIDSGID = wrap true;
        RemoveIPC = wrap true;
        ProtectHostname = wrap true;
        # Weak process isolation

        ProtectProc = wrap "invisible";
        # Strong process isolation (pid 1)
        # Currently broken w/ DynamicUser, see systemd#41014
        # PrivatePIDs = true;

        # A service module that needs namespaces says so; let it win.
        RestrictNamespaces = lib.mkDefault true;
        RestrictRealtime = wrap true;
        LockPersonality = wrap true;
      };
    }

  ) evalContainers;

  # One per container: creates /run/netns/<name> and wires it to the bridge.
  netnsServices = mapAttrs' (
    n: c:
    let
      # Leftovers of a start that died half-way. The kernel tears a deleted
      # namespace down in the background, so its veth host ends can still be
      # there and would make the `link add` below fail.
      guardSetup = [
        "-${ip} netns del ${n}"
      ]
      ++ (map (s: "-${ip} link del ${s}") [
        c.trunkConfig.isolated.hostDev
        c.trunkConfig.free.hostDev
      ]);
      isoSetup = createContainerPort c.trunkConfig.isolated;
      freeSetup = createContainerPort c.trunkConfig.free;
      groupSetup = map createVlanInterface (attrValues c.groupVlans);

      fullSetup = flatten [
        # `ip netns add` leaves lo down, and the generated /etc/hosts points
        # localhost at it.
        (ipCmds.setUp "lo")
        isoSetup
        freeSetup
        groupSetup
      ];
    in
    nameValuePair (names.netnsUnit n) {
      description = "niceContainers network namespace for ${n}";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = guardSetup ++ [ "${ip} netns add ${n}" ] ++ map (ipCmds.inNetns n) fullSetup;
        ExecStop = "${ip} netns del ${n}";
      };
    }
  ) evalContainers;

in
{
  config = lib.mkIf cfg.enable {
    systemd.services = lib.mkMerge [
      containerServices
      netnsServices
    ];
    assertions = lib.mapAttrsToList (n: c: {
      # An undefined egress is reported by assertions.nix.
      assertion = c.egressVlan == null || nameserversOf c.egress != [ ];
      message = "niceContainers.containers.${n}: egress `${c.egress}` has no DNS servers; set ${
        if c.egress == "host" then
          "networking.nameservers"
        else
          "niceContainers.egress.${c.egress}.nameservers"
      }.";
    }) evalContainers;
  };
}
