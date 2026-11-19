{
  # type: lib :: Lib
  lib,
  ...
}:
let
  pow = lib.fix (
    self: base: power:
    if power != 0 then base * (self base (power - 1)) else 1
  );

in
rec {

  strHashToInt =
    s: start: end:
    lib.fromHexString (builtins.substring start end s);

  hashToIpStub =
    hash: offset:
    let
      hex = strHashToInt hash (offset + 0) 4;
      high = hex / 256;
      # type: low :: int
      low = builtins.bitAnd hex 255;
    in
    {
      inherit high low;
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
    let
      base = builtins.substring (offset + 0) 10 hash;
      # type: pairs :: [string]
      pairs = builtins.match "([[:alnum:]]{2})([[:alnum:]]{2})([[:alnum:]]{2})([[:alnum:]]{2})([[:alnum:]]{2})" base;
    in
    lib.strings.concatStringsSep ":" pairs;

  net =
    let
      ipFromStr = str: map lib.toIntBase10 (lib.strings.splitString "." str);
      addIp =
        listForm: num:
        lib.imap0 (
          i: octet:
          let
            initPow = pow 2 ((3 - i) * 8);
          in
          if (initPow <= num) then octet + (num / initPow) else octet
        ) listForm;
    in
    rec {
      ipAddr =
        listForm: mask:
        let
          _octetStr = map toString listForm;
        in
        {
          family = 4;
          addr = listForm;
          wMask = "${lib.concatStringsSep "." _octetStr}/${toString mask}";
          noMask = "${lib.concatStringsSep "." _octetStr}";
          __toString = self: self.wMask;
        };
      subnet =
        listForm: cidr:
        let
          inherit (builtins) elemAt;
          ip = { high, low }: ipAddr [ (elemAt listForm 0) (elemAt listForm 1) high low ] cidr;
          _octetStr = map toString listForm;
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
          __toString = self: "${lib.concatStringsSep "." _octetStr}/${toString cidr}";
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
        __toString = self: "${prefix}::/64";
      };
    };
}
