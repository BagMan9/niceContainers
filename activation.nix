# Deletes netdevs whose creation-time properties drifted from config, so
# networkd recreates them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.niceContainers;
  model = import ./model.nix { inherit lib cfg; };
  inherit (model) sviList vrfTables names;

  # The netdevs whose defining property is fixed at creation time: networkd's
  # reload can neither update nor delete an existing netdev, so when one of
  # these drifts from config it must be deleted out-of-band — networkd then
  # recreates it from the (already changed) .netdev file on reload.
  wantedNetdevs =
    (map (s: {
      name = names.svi s.name;
      kind = "vlan";
      prop = s.vid;
    }) sviList)
    ++ (lib.concatMap (
      s:
      let
        svi = s.svi;
      in
      if svi ? vrf then
        [
          {
            name = svi.vrf;
            kind = "vrf";
            prop = vrfTables.${names.vrfToRoutingTable svi.vrf};
          }
        ]
      else
        [ ]
    ) sviList);

  manifest = pkgs.writeText "niceContainers-netdevs.json" (builtins.toJSON wantedNetdevs);

  reconcile = pkgs.writeShellApplication {
    name = "niceContainers-reconcile-netdevs";
    runtimeInputs = [
      pkgs.iproute2
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      # Ownership convention: any vlan named *-svi that sits on our bridge and
      # any vrf named *-vrf is considered ours. Owned netdevs are deleted when
      # their creation-time property (vlan Id / vrf Table) disagrees with the
      # manifest, or when they have no manifest entry at all (config removed).
      deleted=0
      while read -r name kind prop; do
        want=$(jq -r --arg n "$name" --arg k "$kind" \
          'first(.[] | select(.name == $n and .kind == $k) | .prop) // "absent"' \
          ${manifest})
        if [ "$want" != "$prop" ]; then
          echo "niceContainers: deleting netdev $name ($kind: have $prop, want $want)"
          if ip link del "$name"; then
            deleted=1
          else
            echo "niceContainers: failed to delete $name" >&2
          fi
        fi
      done < <(
        ip -d -j link show | jq -r --arg bridge "${cfg.interfaceConfig.bridgeName}" '
          .[]
          | .linkinfo as $li
          | select(
              ($li.info_kind == "vlan" and (.ifname | endswith("-svi")) and .link == $bridge) or
              ($li.info_kind == "vrf" and (.ifname | endswith("-vrf")))
            )
          | "\(.ifname) \($li.info_kind) \($li.info_data.id // $li.info_data.table)"
        '
      )

      # During a switch a drifted netdev implies changed networkd config, so
      # switch-to-configuration reloads networkd right after activation and
      # this branch is redundant. It matters when the deletion happened for
      # drift networkd never saw (manual tampering); reconfiguring the bridge
      # re-attaches the recreated stacked vlans.
      if [ "$deleted" = 1 ] && systemctl is-active --quiet systemd-networkd.service; then
        networkctl reload
        networkctl reconfigure "${cfg.interfaceConfig.bridgeName}" || true
      fi
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    system.activationScripts."niceContainers-netdevs".text = ''
      ${reconcile}/bin/niceContainers-reconcile-netdevs \
        || echo "niceContainers: netdev reconciliation failed" >&2
    '';
  };
}
