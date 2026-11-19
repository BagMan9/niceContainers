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
        description = "A host path, bound into the container at the same path.";
      };
      group = mkOption {
        type = types.singleLineStr;
        description = ''
          A group the container runs with as a supplementary group, to give
          it access to `path`. Created on the host if missing.
        '';
      };
      ro = mkOption {
        type = types.bool;
        default = false;
        description = "Bind `path` read-only.";
      };
    };
  };
  groupConf = {
    options = {
      isolated = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Members reach only the group's masters (`master@<group>` in
          `containers.<name>.groups`), not each other.
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
        default = 0;
        description = "The group's VLAN ID; 0 derives one (1-1024) from its name.";
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
      wanInterface = mkOption {
        type = types.singleLineStr;
        description = ''
          The interface this egress leaves through, such as a VPN tunnel.
          It is moved into the egress's VRF.
        '';
      };
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
        default = 0;
        description = "The egress's VLAN ID; 0 derives one (1-1024) from its name.";
      };
      tableId = mkOption {
        type = types.ints.u16;
        default = 0;
        description = ''
          The routing table of the egress's VRF; 0 picks 110 plus the VRF's
          position among all VRFs in name order.
        '';
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
        readOnly = true;
        description = ''
          The evaluated containers, for other config to read: each one's
          interfaces, egress VLAN, group legs and addresses.
        '';
      };
    };
    enable = mkEnableOption "isolated container networking (niceContainers)";
    hostWan = mkOption {
      type = types.singleLineStr;
      description = ''
        The host's uplink. Traffic from containers on the built-in `host`
        egress is masqueraded out of it, and their `forwardPorts` arrive on
        it.
      '';
    };
    forwardInterfaces = mkOption {
      type = types.listOf types.singleLineStr;
      default = [ ];
      description = ''
        Host interfaces whose connections to a `hostBinds` port are
        forwarded into the container. Reverse-path filtering is turned off
        on them.
      '';
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
        description = "The bridge joining the host's VLAN interfaces and every container's trunks.";
      };
      isolatedTrunk = mkOption {
        type = types.singleLineStr;
        default = "eth-iso";
        description = ''
          The name, inside each container, of its interface for its egress
          VLAN (untagged) and its isolated groups (tagged). Its bridge port
          is isolated, so it reaches no other isolated port.
        '';
      };
      freeTrunk = mkOption {
        type = types.singleLineStr;
        default = "eth-free";
        description = ''
          The name, inside each container, of its interface for its other
          groups and the groups it is master of.
        '';
      };
    };
    groupConfig = mkOption {
      type = types.attrsOf (types.submodule groupConf);
      default = { };
      description = ''
        Settings for groups named in `containers.<name>.groups`. A group
        needs no entry here to exist.
      '';
    };
    egress = mkOption {
      type = types.attrsOf (types.submodule egressConf);
      default = { };
      description = ''
        Ways out for containers. Each is a VRF whose default route leaves
        through `wanInterface`, masqueraded. The names `host` (the host's
        own routing table, out of `hostWan`) and `host-binds` are built in.
      '';
    };

    containers = mkOption {
      description = ''
        Containers. Each runs a systemd service (by default the one of the
        same name) in its own network namespace and sandbox.
      '';
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Whether to set up this container.";
              };
              groups = mkOption {
                type = types.listOf types.singleLineStr;
                default = [ ];
                description = ''
                  Groups this container joins. Members reach each other by
                  container name (written to its /etc/hosts).
                  `master@<group>` joins as a master, which every member
                  reaches even in an isolated group.
                '';
              };
              egress = mkOption {
                type = types.singleLineStr;
                default = "";
                description = ''
                  The egress this container's traffic leaves by: a name from
                  `niceContainers.egress`, or `host`. Empty for none: the
                  container then reaches only its groups.
                '';
              };
              forwardPorts = mkOption {
                type = types.listOf portSpec;
                default = [ ];
                description = ''
                  Ports forwarded from the egress's WAN interface into the
                  container, as `<egress port>:<container port>[/tcp|/udp]`
                  (tcp when left out).
                '';
              };
              hostBinds = mkOption {
                type = types.listOf portSpec;
                default = [ ];
                description = ''
                  Ports forwarded from the host's `forwardInterfaces` into
                  the container, over IPv4 and IPv6, as
                  `<host port>:<container port>[/tcp|/udp]` (tcp when left
                  out).
                '';
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
                description = "Host paths bound into the container.";
              };
            };
          }
        )
      );
      default = { };
    };
  };
}
