{
  # type: lib :: Lib
  lib,
  # type: pkgs :: Pkgs
  pkgs,
  # type: cfg :: import("./default.nix").NiceContainersConfig
  cfg,
  # type: model :: import("./model.nix").NiceContainersModel
  model,
}:
let
  inherit (lib)
    optionals
    flatten
    # type: string -> a -> {name: string, value: a}
    nameValuePair
    # type: (string -> a -> {name: string, value: b}) -> {_: a} -> {_: b}
    mapAttrs'
    # type: (a -> bool) -> [a] -> {right: [a], wrong: [a]}
    partition
    ;
  inherit (model)
    evalContainers
    groupAddrMap
    parseGroupRef
    ;
  inherit (builtins)
    # type: attrValues :: {_: a} -> [a]
    attrValues
    ;
  ip = "${pkgs.iproute2}/bin/ip";
  ipCmds = {
    setUp = dev: "${ip} link set ${dev} up";
    setAddr =
      # type: addr :: string
      addr: dev: "${ip} addr add ${addr} dev ${dev}";
    setDefaultRoute =
      # type: gw :: string
      gw: "${ip} route add default via ${gw}";

    createLink =
      {
        dev,
        hostDev,
        nearMac,
        hostMac,
        ...
      }:
      "${ip} link add ${dev} address ${nearMac} type veth peer name ${hostDev} address ${hostMac} netns /proc/1/ns/net";
  };
  createContainerPort =
    with ipCmds;
    {
      # type: string
      dev,
      # type: string
      hostDev,
      # type: string
      nearMac,
      # type: string
      hostMac,
      addr ? null,
      # type: string
      gw ? null,
    }:
    let
      defaultRoute = optionals (gw != null && addr != null) [
        #tix-ignore
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

  createVlanInterface =
    with ipCmds;
    {
      # type: string
      dev,
      # type: string
      name,
      # type: int
      vid,
      # type: string
      addr,
    }:
    [
      "${ip} link add link ${dev} name ${name} type vlan id ${toString vid}"
      (setAddr addr name)
      (setUp name)
    ];

in
{
  containerServices = mapAttrs' (
    n: c:
    let
      p = partition (m: !m.ro) c.mounts;
      rw_mounts = p.right;
      ro_mounts = p.wrong;
      guardSetup =
        with c.trunkConfig;
        map (s: "-${pkgs.toybox}/bin/nsenter --net=/proc/1/ns/net ${ip} link del ${s}") [
          isolated.hostDev
          free.hostDev
        ];
      isoSetup = createContainerPort c.trunkConfig.isolated;
      freeSetup = createContainerPort c.trunkConfig.free;
      groupSetup = map createVlanInterface <| attrValues c.groupVlans;
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
          c.groups
          |> map parseGroupRef
          |> map getHosts
          |> lib.mergeAttrsList
          |> lib.mapAttrsToList pairToText
          |> (x: x ++ [ "127.0.0.1 localhost" ])
          |> lib.concatStringsSep "\n"
        );

      resolveText = pkgs.writeText "${n}-resolve" ''
        nameserver ${c.egressVlan.subnet.gateway.noMask}
      '';

      fullSetup = flatten [
        guardSetup
        isoSetup
        freeSetup
        groupSetup
      ];

      extraService = c.extraServiceConfig.serviceConfig or { };

      extraPaths =
        let
          confguard = extraService.BindReadOnlyPaths or [ ];
        in
        if (builtins.isList confguard) then confguard else lib.singleton confguard;

      extraSetup =
        let
          confGuard = extraService.ExecStartPre or [ ];
        in
        if (builtins.isList confGuard) then confGuard else lib.singleton confGuard;
    in
    nameValuePair c.matchSystemd
    <| lib.mkMerge [
      {
        serviceConfig = {
          PrivateNetwork = lib.mkForce true;
          ExecStartPre = map (s: "+${s}") <| fullSetup ++ extraSetup;

          SupplementaryGroups = map (r: r.group) c.mounts;
          BindPaths = map (r: r.path) rw_mounts;
          BindReadOnlyPaths =
            (map (r: r.path) ro_mounts)
            ++ lib.singleton "${hostsText}:/etc/hosts"
            ++ lib.optional (c.egressVlan != null) "${resolveText}:/etc/resolv.conf"
            ++ extraPaths;

          DynamicUser = true;
          User = lib.mkForce null;
          Group = lib.mkForce null;

          NoNewPrivileges = true;
          # difference between this and "yes?"
          ProtectHome = lib.mkForce true;
          ProtectClock = true;
          InaccessiblePaths = "/run/nscd";
          PrivateTmp = lib.mkForce "disconnected"; # Stricter version enabled by DynamicUser
          PrivateDevices = lib.mkForce true; # WARN: TEMP, MOVE TO SOMETHING THAT OVERRIDES BARE DEFS BUT IS STILL EASILY FORCEABLE
          PrivateUsers = true;
          ProtectKernelLogs = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          RemoveIPC = true;
          ProtectHostname = true;
          # Weak process isolation

          ProtectProc = lib.mkForce "invisible";
          # Strong process isolation (pid 1)
          # Currently broken w/ DynamicUser, see systemd#41014
          # PrivatePIDs = true;

          RestrictNamespaces = lib.mkDefault true;
          RestrictRealtime = true;
          LockPersonality = true;
          SystemCallFilter = lib.mkOverride 100 [
            "@system-service"
            "~@mount" # Needed to totally prevent any changing of mounts
            "~@privileged"
          ];
        }
        // (removeAttrs extraService [
          "ExecStartPre"
          "BindReadOnlyPaths"
        ]);
      }
      (removeAttrs c.extraServiceConfig [ "serviceConfig" ])
    ]

  ) evalContainers;
  extraSetup = {
    "rule-config" = {
      enable = cfg.interfaceConfig.fixTailscale;
      bindsTo = [ "tailscaled.service" ];
      after = [
        "tailscaled.service"
      ];
      requiredBy = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.sysctl}/bin/sysctl -w net.ipv4.conf.tailscale0.rp_filter=0";
      };
    };
  };
}
