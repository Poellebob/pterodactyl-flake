# pterodactyl-flake

NixOS flake for running Pterodactyl panel + Wings on a single machine.

## Using as a flake input in an existing dotfiles repo

```nix
# flake.nix
inputs.pterodactyl.url = "github:you/pterodactyl-flake";

# your host module
imports = [
  inputs.pterodactyl.nixosModules.pterodactyl
  inputs.pterodactyl.nixosModules.wings
];
services.pterodactyl = {
  enable  = true;
  domain  = "panel.example.com";
};
services.wings = {
  enable     = true;
  configFile = config.age.secrets."wings-config".path;
};
```

## Secrets with agenix

```bash
# Generate the DB password secret
echo -n "supersecret" | agenix encrypt -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" > secrets/pterodactyl-db-password.age

# Generate/encrypt the Wings config after creating the node in the panel
agenix encrypt -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" < /etc/pterodactyl/config.yml > secrets/wings-config.age
```

## Updating the Wings binary

Change `version` in `pkgs/wings.nix`, set `hash = lib.fakeHash`, run `nix build`,
then copy the correct hash from the error message.
