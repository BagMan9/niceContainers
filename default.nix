# The `niceContainers` options schema, as a tix type. tix does not evaluate the
# NixOS module system, so it can't derive this from the option declarations
# below — it's hand-maintained: edit it when you add/remove an option. It must be
# SELF-CONTAINED (inline nested shapes), because tix's cross-file
# `import("./default.nix").NiceContainersConfig` extracts this one alias and does
# NOT carry references to sibling aliases.
/**
  type NiceContainersConfig = {
     enable: bool,
     hostWan: string,
     forwardInterfaces: [string],
     api: { containers: { ... }, ... },
     interfaceConfig: {
       baseSubnet: string,
       bridgeName: string,
       isolatedTrunk: string,
       freeTrunk: string,
       fixTailscale: bool,
     },
     groupConfig: { _: { isolated: bool, cidrMask: int, vid: int } },
     egress: { _: { wanInterface: string, vid: int, tableId: int } },
     containers: { _: {
       enable: bool,
       groups: [string],
       egress: string,
       forwardPorts: [string],
       hostBinds: [string],
       matchSystemd: string,
       extraServiceConfig: { ... },
       mounts: [{ path: string, group: string, ro: bool }],
     } },
   };
*/
{
  config,
  # type: lib :: Lib
  lib,
  # type: pkgs :: Pkgs
  pkgs,
  ...
}:
# TODO: Add inline defs, nspawn / vm / multihost semantics
let
  # type: cfg :: NiceContainersConfig
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
  networkd = import ./networkd.nix { inherit lib cfg model; };
  systemd = import ./systemd.nix {
    inherit
      lib
      cfg
      model
      pkgs
      ;
  };
  activation = import ./activation.nix {
    inherit
      lib
      cfg
      model
      pkgs
      ;
  };
  inherit (lib) mapAttrsToList concatMap concatStringsSep;
  # type mode :: import("./model.nix").NiceContainersModel
  inherit (model) enabledContainers sviList sviDict;
  inherit (builtins)
    filter
    attrValues
    # type: string -> string -> [string | null]
    match
    ;
in
{
  options =
    with lib;
    let
      resourceConf = {
        options = {
          path = mkOption {
            type = types.singleLineStr;
          };
          group = mkOption {
            type = types.singleLineStr;
          };
          ro = mkOption {
            type = types.bool;
            default = false;
          };
        };
      };
      groupConf = {
        options = {
          isolated = mkOption {
            type = types.bool;
            default = false;
          };
          cidrMask = mkOption {
            type = types.ints.between 0 32;
            default = 16;
          };
          vid = mkOption {
            type = types.ints.between 0 4095;
            default = 0; # 0 Indicates hash / automatic
          };

        };
      };

      egressConf = {
        options = {
          wanInterface = mkOption { type = types.singleLineStr; };
          vid = mkOption {
            type = types.ints.between 0 4095;
            default = 0; # 0 Indicates hash / automatic
          };
          tableId = mkOption {
            type = types.ints.u16;
            default = 0;
          };
        };
      };

      portSpec = types.strMatching "([[:digit:]]+):([[:digit:]]+)(/tcp|/udp)?";
    in
    {
      niceContainers = {
        api = {
          containers = mkOption {
            type = types.anything;
          };
        };
        enable = mkEnableOption "Nice Containers";
        hostWan = mkOption {
          type = types.singleLineStr;
        };
        forwardInterfaces = mkOption {
          type = types.listOf types.singleLineStr;
          default = [ ];
        };
        interfaceConfig = {
          baseSubnet = mkOption {
            type =
              let
                seg4 = "[[:digit:]]{1,3}";
                cidr4 = "[[:digit:]]{1,2}";
              in
              types.strMatching "(${seg4})\.(${seg4})\.(${seg4})\.(${seg4})/(${cidr4})";
            default = "10.0.0.0/8";
          };

          bridgeName = mkOption {
            type = types.singleLineStr;
            default = "br-containers";
          };
          isolatedTrunk = mkOption {
            type = types.singleLineStr;
            default = "eth-iso";
          };
          freeTrunk = mkOption {
            type = types.singleLineStr;
            default = "eth-free";
          };
          fixTailscale = mkOption {
            type = types.bool;
            default = false;
          };
        };
        groupConfig = mkOption {
          type = types.attrsOf (types.submodule groupConf);
          default = { };
        };
        egress = mkOption {
          type = types.attrsOf (types.submodule egressConf);
          default = { };
        };

        containers = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                };
                groups = mkOption {
                  type = types.listOf types.singleLineStr;
                  default = [ ];
                };
                egress = mkOption {
                  type = types.singleLineStr;
                  default = "";
                };
                forwardPorts = mkOption {
                  type = types.listOf portSpec;
                  default = [ ];
                };
                hostBinds = mkOption {
                  type = types.listOf portSpec;
                  default = [ ];
                };
                matchSystemd = mkOption {
                  type = types.singleLineStr;
                };
                extraServiceConfig = mkOption {
                  type = types.anything;
                  default = { };
                };
                mounts = mkOption {
                  type = types.listOf (types.submodule resourceConf);
                  default = [ ];
                };
              };
            }
          );
          default = { };
        };
      };
    };

  config = lib.mkIf cfg.enable {
    niceContainers.api.containers = model.evalContainers;
    users.groups =
      let
        allResource = concatMap (c: c.mounts) <| lib.attrValues enabledContainers;
      in
      lib.genAttrs (map (r: r.group) allResource) (_: { });
    # TODO: Move unbound to be containerized, and be the sole non-isolated container on egress vlans, such that it can function as the dns for everything on that VLAN (would allow future non-shared lookups by interface, etc)
    services.unbound = {
      enable = true;
      settings = {
        server = {
          access-control = [ "0.0.0.0/0 allow" ];
          interface = "10.10.0.0";
          interface-automatic = true;
          tls-cert-bundle = "/etc/ssl/certs/ca-certificates.crt";
        };
        forward-zone = [
          {
            name = ".";
            forward-tls-upstream = true;
            forward-addr = [
              "9.9.9.10@853#dns10.quad9.net"
              "149.112.112.10@853#dns10.quad9.net"
              "2620:fe::10@853#dns10.quad9.net"
              "2620:fe::fe:10@853#dns10.quad9.net"
            ];
          }
        ];
      };
    };

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv4.conf.default.forwarding" = 1;
    };
    systemd.network = with networkd; {

      enable = true;
      config = {
        addRouteTablesToIPRoute2 = true;
        routeTables = model.vrfTables;
      };
      netdevs =
        with devices;
        lib.mkMerge [
          svi
          bridge
          vrf
        ];
      networks =
        with networks;
        lib.mkMerge [
          svi
          bridge
          vrf
          egress
          container.isolated
          container.free
          (lib.optionalAttrs (cfg.forwardInterfaces != [ ]) {
            "10-generic" = {
              matchConfig.Name = "lo";
              routingPolicyRules = [
                {
                  FirewallMark = 1;
                  Priority = 11;
                  Table = "main";
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
              })
              ++ (
                filter (s: !lib.hasPrefix "host" s.name) sviList
                |> lib.imap (
                  i: s: {
                    To = toString s.subnet;
                    Priority = 50 + i;
                    Table = model.vrfTables.${model.names.vrfRoutingTable s.name};
                  }
                )
              );
            };
          })
        ];
    };
    systemd.services = lib.mkMerge [
      systemd.containerServices
      systemd.extraSetup
    ];

    system.activationScripts."niceContainers-netdevs".text = ''
      ${activation.reconcile}/bin/niceContainers-reconcile-netdevs \
        || echo "niceContainers: netdev reconciliation failed" >&2
    '';

    boot.kernelModules = [ "wireguard" ]; # NOTE: Probably unnecessary
    networking = {
      useNetworkd = true;
      firewall = {
        checkReversePath = false;
      };
      nftables = {
        enable = true;

        tables = {
          hostRouting =
            let
              pairs =
                (
                  map (s: ''${s.subnet} . "${s.svi.wan or cfg.hostWan}"'')
                  <| filter ({ svi, ... }: svi != null) sviList
                )
                |> lib.strings.concatStringsSep ", ";
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
                  idxParse = builtins.elemAt <| match "([[:digit:]]+):([[:digit:]]+)(/tcp|/udp)?" def;
                in
                {
                  # type: string
                  egressSide = idxParse 0;
                  # type: string
                  containerSide = idxParse 1;
                  proto =
                    let
                      pro = idxParse 2;
                    in
                    if (pro != null) then pro |> lib.removePrefix "/" else "tcp";
                };
              getMeta =
                container:
                let
                  egressVlan = container.egressVlan;
                  svi = if egressVlan != null then egressVlan.svi else null;
                in
                {
                  ifname = if svi != null then svi.wan or cfg.hostWan else cfg.hostWan;
                  # type: string
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
                map (
                  p: entryToString <| (parsePortForward p) // meta
                ) cfg.containers.${container.name}.forwardPorts;
              fwds = concatMap mkContainerEntry <| mapAttrsToList (n: v: v // { name = n; }) model.evalContainers;
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
              parseForwardPartial =
                def:
                let
                  idxParse = builtins.elemAt <| match "([[:digit:]]+):([[:digit:]]+)(/tcp|/udp)?" def;
                in
                map (iface: {
                  hostSide = idxParse 0;
                  containerSide = idxParse 1;
                  proto =
                    let
                      pro = idxParse 2;
                    in
                    if (pro != null) then pro |> lib.removePrefix "/" else "tcp";
                  ifname = iface;
                }) cfg.forwardInterfaces;
              getMeta = container: {
                ip = container.groupVlans."host-binds".addr.noMask;
              };
              entryToString =
                entry:
                "${entry.proto} . ${entry.ifname} . ${entry.hostSide} : ${entry.ip} . ${entry.containerSide}";
              mkContainerEntries =
                container:
                let
                  meta = getMeta container;
                in
                concatMap (p: parseForwardPartial p) cfg.containers.${container.name}.hostBinds
                |> map (e: e // meta |> entryToString);
              fwds =
                concatMap mkContainerEntries <| mapAttrsToList (n: v: v // { name = n; }) model.evalContainers;
            in
            {
              family = "inet";
              enable = fwds != [ ];
              content = ''
                map host_bind_map {
                  type inet_proto . ifname . inet_service : ipv4_addr . inet_service
                  elements = { ${concatStringsSep ", " fwds} }
                }

                chain prerouting {
                  type nat hook prerouting priority -100;
                  fib daddr type local dnat ip to meta l4proto . iifname . th dport map @host_bind_map
                }
                # Drop coming out
                chain forward {
                  type filter hook forward priority filter - 10; policy accept;
                  iifname "${hostBindsIface}" ct direction original drop
                }

                chain input {
                  type filter hook input priority filter - 10; policy accept;
                  iifname "${hostBindsIface}" ct direction original drop
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

  };
}
