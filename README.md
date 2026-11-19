# niceContainers

Declarative isolated container networking for NixOS.

Pros:
- Much less evaluation overhead than nixpkgs' systemd-nspawn based containers
- Easy to use securely: Specify exactly what your container needs

Cons:
- You end up writing 2-3 separate config blocks for one service.

TODO:
- Fix the con. Can't put config under `systemd.services.<name>.*` due to evaluation issues with mounts right now.
