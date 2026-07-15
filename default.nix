{
  config,
  lib,
  pkgs,
  ...
}:
# TODO: Add port forwarding (both for something like traefik and something like qbit)
# TODO: Add inline defs, nspawn / vm / multihost semantics
let
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
  inherit (lib) mapAttrsToList;
  inherit (model) enabledContainers sviList sviDict;
  inherit (builtins) filter attrValues;
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
        allResource = lib.concatMap (c: c.mounts) <| lib.attrValues enabledContainers;
      in
      lib.genAttrs (map (r: r.group) allResource) (_: { });
    # services.unbound = {
    #   enable = true;
    #   settings = {
    #     server = {
    #       access-control = [ "0.0.0.0/0 allow" ];
    #       interface = builtins.attrNames sviDict;
    #       outgoing-interface = cfg.hostWan;
    #     };
    #     forward-zone = [
    #       {
    #         name = ".";
    #         forward-tls-upstream = false;
    #         forward-addr = [
    #           "192.168.86.100"
    #         ];
    #       }
    #     ];
    #   };
    # };

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
              });
            };
          })
        ];
    };
    systemd.services = lib.mkMerge [
      systemd.containerServices
      systemd.extraSetup
    ];

    # Activation scripts are bash snippets concatenated into
    # /run/current-system/activate. They run as root on every switch AND every
    # boot, before systemd units are (re)started/reloaded — so they must be
    # idempotent, and anything they delete here is recreated by the networkd
    # reload that switch-to-configuration performs afterwards. At boot no
    # interfaces exist yet, so this is a no-op. PATH is minimal during
    # activation; the script pins its dependencies via runtimeInputs.
    # (Not run by `nixos-rebuild dry-activate` since it mutates state.)
    system.activationScripts."niceContainers-netdevs".text = ''
      ${activation.reconcile}/bin/niceContainers-reconcile-netdevs \
        || echo "niceContainers: netdev reconciliation failed" >&2
    '';

    boot.kernelModules = [ "wireguard" ]; # NOTE: Probably unnecessary
    networking = {
      useNetworkd = true;
      firewall = {
        checkReversePath = false;
        allowedTCPPorts = [ 5056 ];
        allowedUDPPorts = [
          51820
          51821
        ];
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
                  idxParse = builtins.elemAt <| builtins.match "([[:digit:]]+):([[:digit:]]+)(/tcp|/udp)?" def;
                in
                {
                  egressSide = idxParse 0;
                  containerSide = idxParse 1;
                  proto = if (idxParse 2 != null) then idxParse 2 |> lib.removePrefix "/" else "tcp";
                };
              getMeta = container: {
                ifname = container.egressVlan.svi.wan or cfg.hostWan;
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
              fwds =
                lib.concatMap mkContainerEntry <| mapAttrsToList (n: v: v // { name = n; }) model.evalContainers;
            in
            {
              enable = fwds != [ ];
              content = ''
                map vrf_fwd_map {
                type inet_proto . ifname . inet_service : ipv4_addr . inet_service
                elements = { ${lib.concatStringsSep ", " fwds} }
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
                  idxParse = builtins.elemAt <| builtins.match "([[:digit:]]+):([[:digit:]]+)(/tcp|/udp)?" def;
                in
                map (iface: {
                  hostSide = idxParse 0;
                  containerSide = idxParse 1;
                  proto = if (idxParse 2 != null) then idxParse 2 |> lib.removePrefix "/" else "tcp";
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
                lib.concatMap (p: parseForwardPartial p) cfg.containers.${container.name}.hostBinds
                |> map (e: e // meta |> entryToString);
              fwds =
                lib.concatMap mkContainerEntries <| mapAttrsToList (n: v: v // { name = n; }) model.evalContainers;
            in
            {
              family = "inet";
              enable = fwds != [ ];
              content = ''
                map host_bind_map {
                  type inet_proto . ifname . inet_service : ipv4_addr . inet_service
                  elements = { ${lib.concatStringsSep ", " fwds} }
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
