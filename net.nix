# Pure helpers: names hashed into numbers and addresses, address records,
# and the port-spec format of `forwardPorts` / `hostBinds`.
{ lib, ... }:
rec {

  # `len` hex digits of `s` from `start`, as an integer.
  strHashToInt =
    s: start: len:
    lib.fromHexString (builtins.substring start len s);

  pow2 = n: if n == 0 then 1 else 2 * pow2 (n - 1);

  # IPv4 addresses as integers.
  parseIpv4 = s: lib.foldl' (acc: o: acc * 256 + lib.toIntBase10 o) 0 (lib.splitString "." s);
  ipv4Octets = n: map (i: lib.mod (n / pow2 (8 * (3 - i))) 256) (lib.range 0 3);
  formatIpv4 = n: lib.concatMapStringsSep "." toString (ipv4Octets n);
  cidr4Regex =
    let
      seg = "[[:digit:]]{1,3}";
    in
    "${seg}\\.${seg}\\.${seg}\\.${seg}/[[:digit:]]{1,2}";
  # "a.b.c.d/p" as { network; prefixLength; }, host bits cleared.
  parseCidr4 =
    s:
    let
      parts = lib.splitString "/" s;
      prefixLength = lib.toIntBase10 (lib.elemAt parts 1);
      size = pow2 (32 - prefixLength);
    in
    {
      inherit prefixLength;
      network = parseIpv4 (lib.head parts) / size * size;
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
      n: prefixLength:
      let
        str = formatIpv4 n;
      in
      {
        family = 4;
        addr = ipv4Octets n;
        wMask = "${str}/${toString prefixLength}";
        noMask = str;
        __toString = self: self.wMask;
      };
    # An IPv4 subnet, from its network address (an integer) and prefix length.
    subnet =
      network: prefixLength:
      let
        at = host: ipAddr (network + host) prefixLength;
      in
      {
        inherit network prefixLength;
        # The address a name gets in this subnet, from its hash alone: the
        # top (32 - prefixLength) bits of the hash's first 32.
        fromHash = hash: at (strHashToInt hash 0 8 / pow2 prefixLength);
        addr = ipv4Octets network;
        gateway = at 1;
        broadcast = at (pow2 (32 - prefixLength) - 1);
        __toString = _: "${formatIpv4 network}/${toString prefixLength}";
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
