# A host that exercises every niceContainers feature, for tests/golden.sh.
{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "25.11";
  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };
  # The options manual records which file declares each option, so moving a
  # declaration between files would change the system without changing
  # anything the module does.
  documentation.nixos.enable = false;

  niceContainers = {
    enable = true;
    hostWan = "enp1s0";
    forwardInterfaces = [
      "enp1s0"
      "tailscale0"
    ];
    interfaceConfig.fixTailscale = true;
    egress = {
      nyc = {
        wanInterface = "wg-nyc";
        nameservers = [ "10.64.0.1" ];
      };
      lon = {
        wanInterface = "wg-lon";
        nameservers = [
          "9.9.9.9"
          "149.112.112.112"
        ];
        vid = 300;
        tableId = 200;
      };
    };
    groupConfig = {
      media.isolated = true;
      v6.ipv6 = true;
      download.subnet = "192.168.77.0/24";
    };
    containers = {
      sabnzbd = {
        egress = "nyc";
        groups = [
          "download"
          "master@media"
        ];
        forwardPorts = [
          "8080:8080"
          "9000:9000/udp"
        ];
        hostBinds = [
          "8085:8080/tcp"
          "8086:8081"
        ];
        mounts = [
          {
            path = "/srv/dl";
            group = "dl";
          }
          {
            path = "/srv/media";
            group = "media";
            ro = true;
          }
        ];
      };
      jellyfin = {
        egress = "lon";
        groups = [
          "media"
          "v6"
        ];
        hostBinds = [ "8096:8096" ];
        syscallFilter = [ "@system-service" ];
      };
      helper = {
        matchSystemd = "helper-daemon";
        groups = [
          "v6"
          "download"
        ];
      };
      off = {
        enable = false;
        egress = "nyc";
      };
    };
  };
}
