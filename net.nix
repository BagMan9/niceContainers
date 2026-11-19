# Pure helpers: names hashed into numbers and addresses, address records,
# and the port-spec format of `forwardPorts` / `hostBinds`.
{ lib, ... }:
rec {

  # `len` hex digits of `s` from `start`, as an integer.
  strHashToInt =
    s: start: len:
    lib.fromHexString (builtins.substring start len s);

  hashToIpStub =
    hash: offset:
    let
      hex = strHashToInt hash offset 4;
    in
    {
      high = hex / 256;
      low = builtins.bitAnd hex 255;
    };
  # The host half of a /64: 64 bits of the hash as four hextets, written
  # without leading zeros so they read the same as in `ip addr` output.
  hashToIp6Host =
    hash: offset:
    lib.concatMapStringsSep ":" (
      i: lib.toLower (lib.toHexString (strHashToInt hash (offset + i * 4) 4))
    ) (lib.range 0 3);
  hashToPostMac =
    hash: offset:
    lib.concatStringsSep ":" (
      builtins.match "([[:alnum:]]{2})([[:alnum:]]{2})([[:alnum:]]{2})([[:alnum:]]{2})([[:alnum:]]{2})" (
        builtins.substring offset 10 hash
      )
    );

  # "<outer>:<inner>[/tcp|/udp]": a port on the host side, the port in the
  # container it reaches, and the protocol (tcp when left out).
  portSpecRegex = "([[:digit:]]+):([[:digit:]]+)(/tcp|/udp)?";
  parsePortSpec =
    spec:
    let
      m = builtins.match portSpecRegex spec;
      proto = builtins.elemAt m 2;
    in
    {
      outer = builtins.elemAt m 0;
      inner = builtins.elemAt m 1;
      proto = if proto == null then "tcp" else lib.removePrefix "/" proto;
    };

  net = rec {
    ipAddr =
      listForm: mask:
      let
        octets = lib.concatMapStringsSep "." toString listForm;
      in
      {
        family = 4;
        addr = listForm;
        wMask = "${octets}/${toString mask}";
        noMask = octets;
        __toString = self: self.wMask;
      };
    subnet =
      listForm: cidr:
      let
        ip =
          { high, low }:
          ipAddr [
            (builtins.elemAt listForm 0)
            (builtins.elemAt listForm 1)
            high
            low
          ] cidr;
      in
      {
        inherit ip;
        # The address a name gets in this subnet, from its hash alone.
        fromHash = hash: ip (hashToIpStub hash 0);
        addr = listForm;
        gateway = ip {
          high = 0;
          low = 1;
        };
        __toString = _: "${lib.concatMapStringsSep "." toString listForm}/${toString cidr}";
      };

    # The IPv6 counterparts, always a /64. `prefix` is the first four
    # hextets ("fd6e:6963:6500:123").
    ipAddr6 = addr: {
      family = 6;
      wMask = "${addr}/64";
      noMask = addr;
      __toString = self: self.wMask;
    };
    subnet6 = prefix: {
      fromHash = hash: ipAddr6 "${prefix}:${hashToIp6Host hash 0}";
      gateway = ipAddr6 "${prefix}::1";
      __toString = _: "${prefix}::/64";
    };
  };
}
