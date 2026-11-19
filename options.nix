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
      cidrMask = mkOption {
        type = types.ints.between 0 32;
        default = 16;
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
        type =
          let
            seg4 = "[[:digit:]]{1,3}";
            cidr4 = "[[:digit:]]{1,2}";
          in
          types.strMatching "(${seg4})\.(${seg4})\.(${seg4})\.(${seg4})/(${cidr4})";
        default = "10.0.0.0/8";
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
