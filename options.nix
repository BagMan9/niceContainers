# Declares the `niceContainers` options. The other modules turn them into
# host config.
{ lib, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  net = import ./net.nix { inherit lib; };
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
      subnet = mkOption {
        type = types.nullOr cidr4;
        default = null;
        description = ''
          This VLAN's IPv4 subnet, instead of its slot of
          `interfaceConfig.baseSubnet`. Members' host parts are hashed from
          their names, so a small subnet makes two members more likely to
          collide; evaluation fails if they do.
        '';
      };
      vid = mkOption {
        type = types.ints.between 0 4095;
        default = 0; # 0 Indicates hash / automatic
      };
      ipv6 = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Address this group from `interfaceConfig.ulaPrefix` instead
          of IPv4. Members then reach each other over IPv6 only, so
          every server in the group must listen on `::`, not `0.0.0.0`.
        '';
      };

    };
  };

  egressConf = {
    options = {
      wanInterface = mkOption { type = types.singleLineStr; };
      nameservers = mkOption {
        type = types.listOf types.singleLineStr;
        default = [ ];
        description = ''
          The DNS servers of containers on this egress. Their queries leave
          through the egress like any other traffic.
        '';
      };
      subnet = mkOption {
        type = types.nullOr cidr4;
        default = null;
        description = ''
          This VLAN's IPv4 subnet, instead of its slot of
          `interfaceConfig.baseSubnet`. Members' host parts are hashed from
          their names, so a small subnet makes two members more likely to
          collide; evaluation fails if they do.
        '';
      };
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

  portSpec = types.strMatching net.portSpecRegex;
  cidr4 = types.strMatching net.cidr4Regex;
in
{
  options.niceContainers = {
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
        type = cidr4;
        default = "10.0.0.0/8";
        description = ''
          The IPv4 range VLAN subnets are cut from, in slots of
          `subnetPrefixLength`. VLAN i (egresses, then groups, then the
          built-in host-binds and host VLANs) takes slot i + 10, so adding a
          VLAN can move the ones after it; give a VLAN its own `subnet` to
          pin it. The host routes each VLAN subnet to its containers, so
          none may overlap a network the host reaches otherwise.
        '';
      };
      subnetPrefixLength = mkOption {
        type = types.ints.between 8 30;
        default = 16;
        description = "The prefix length of each VLAN's slot of `baseSubnet`.";
      };
      ulaPrefix = mkOption {
        type = types.strMatching "fd[[:xdigit:]]{2}(:[[:xdigit:]]{1,4}){2}";
        default = "fd6e:6963:6500";
        description = ''
          The /48 that IPv6 groups take their /64s from, as its first
          three hextets. Never routed off the host: these addresses
          exist only on the container bridge.
        '';
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
        types.submodule (
          { name, ... }:
          {
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
                default = name;
                description = "The systemd service to run as this container.";
              };
              syscallFilter = mkOption {
                type = types.listOf types.singleLineStr;
                default = [
                  "@system-service"
                  "~@mount" # Needed to totally prevent any changing of mounts
                  "~@privileged"
                ];
                description = ''
                  The wrapper's SystemCallFilter entries, added to the
                  service module's own. An option because the two are one
                  list at one priority: mkForce on the unit clears both, and
                  only this drops the wrapper's share alone.
                '';
              };
              mounts = mkOption {
                type = types.listOf (types.submodule resourceConf);
                default = [ ];
              };
            };
          }
        )
      );
      default = { };
    };
  };
}
