# pterodactyl-flake

NixOS flake for running Pterodactyl panel + Wings on a single machine.

---

## Using as a flake input

### 1. Add the input

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pterodactyl = {
      url = "git+https://codeberg.org/Poellebob/pterodactyl-flake.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, pterodactyl, ... }: {
    nixosConfigurations.myserver = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        pterodactyl.nixosModules.pterodactyl
        pterodactyl.nixosModules.wings
        ./hosts/myserver/configuration.nix
      ];
    };
  };
}
```

### 2. Configure the modules

```nix
# hosts/myserver/configuration.nix
{ config, ... }:
{
  services.pterodactyl = {
    enable  = true;
    domain  = "panel.example.com";
    useACME = true;

    # Optional — point at a plain file or an agenix secret:
    # dbPasswordFile = "/run/agenix/ptero-db-password";
  };

  services.wings = {
    enable = true;
    # Paste the config.yml path here after creating the node in the panel.
    # configFile = "/run/agenix/wings-config";
  };
}
```

### 3. Lock and switch

```bash
nix flake lock          # resolves the new input
nixos-rebuild switch --flake .#myserver
```

---

## One-time panel setup

Run these **once** after the first successful `nixos-rebuild switch`.
All commands run as the `pterodactyl` system user.

```bash
# 1. Download and extract the panel release
sudo mkdir -p /srv/pterodactyl
sudo chown pterodactyl:pterodactyl /srv/pterodactyl
cd /srv/pterodactyl

sudo -u pterodactyl curl -Lo panel.tar.gz \
  https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
sudo -u pterodactyl tar --strip-components=1 -xzf panel.tar.gz
sudo -u pterodactyl rm panel.tar.gz

# 2. Install PHP dependencies
sudo -u pterodactyl composer install --no-dev --optimize-autoloader

# 3. Generate the app key + configure environment
sudo -u pterodactyl php artisan key:generate --force
sudo -u pterodactyl php artisan p:environment:setup
sudo -u pterodactyl php artisan p:environment:database

# 4. Run migrations and seed default data
sudo -u pterodactyl php artisan migrate --seed --force

# 5. Create the first admin account
sudo -u pterodactyl php artisan p:user:make

# 6. Fix permissions
sudo chown -R pterodactyl:pterodactyl /srv/pterodactyl
sudo chmod -R 755 /srv/pterodactyl/storage \
                  /srv/pterodactyl/bootstrap/cache
```

---

## Connecting Wings

After completing the panel setup:

1. Open the panel → **Admin** → **Locations** → create a location.
2. Go to **Nodes** → create a node, set its FQDN to the server's hostname.
3. On the **Configuration** tab, click **Generate Token** and copy the `config.yml`.
4. Place the config on the server:

```bash
# Plain file (fine for a private/trusted machine)
sudo mkdir -p /etc/pterodactyl
sudo install -m 600 config.yml /etc/pterodactyl/config.yml
```

5. Point the module at it:

```nix
services.wings.configFile = "/etc/pterodactyl/config.yml";
```

6. Rebuild and restart Wings:

```bash
nixos-rebuild switch --flake .#myserver
sudo systemctl restart wings
sudo systemctl status wings
```

---

## Secrets with agenix

If you are already using agenix, encrypt both secrets and reference them instead of plain paths.

```bash
# Encrypt the DB password
printf 'supersecretpassword' \
  | rage -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" \
  > secrets/ptero-db-password.age

# Encrypt the Wings config.yml
rage -r "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" \
  -o secrets/wings-config.age \
  /etc/pterodactyl/config.yml
```

```nix
# flake.nix — add agenix input
agenix = {
  url = "github:ryantm/agenix";
  inputs.nixpkgs.follows = "nixpkgs";
};

# configuration.nix
{ config, ... }:
{
  imports = [ agenix.nixosModules.default ];

  age.secrets."ptero-db-password" = {
    file  = ./secrets/ptero-db-password.age;
    owner = "pterodactyl";
  };
  age.secrets."wings-config" = {
    file  = ./secrets/wings-config.age;
    owner = "root";
    mode  = "0600";
  };

  services.pterodactyl = {
    enable         = true;
    domain         = "panel.example.com";
    dbPasswordFile = config.age.secrets."ptero-db-password".path;
  };

  services.wings = {
    enable     = true;
    configFile = config.age.secrets."wings-config".path;
  };
}
```

---

## Updating Wings

The Wings binary version is pinned in `pkgs/wings.nix`.
To update it, open an issue or PR on the repo, or override the package locally:

```nix
services.wings.package = pkgs.callPackage ./my-wings-override.nix {};
```

---

## Module options reference

### `services.pterodactyl`

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the panel |
| `domain` | str | — | Public domain / Nginx vhost |
| `useACME` | bool | `true` | Auto-provision Let's Encrypt cert |
| `dataDir` | str | `/srv/pterodactyl` | Panel file location |
| `user` | str | `pterodactyl` | System user for php-fpm + queue worker |
| `redisName` | str | `pterodactyl` | Redis server instance name |
| `dbName` | str | `pterodactyl` | MariaDB database name |
| `dbUser` | str | `pterodactyl` | MariaDB user |
| `dbPasswordFile` | path\|null | `null` | File containing the DB password |

### `services.wings`

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the Wings daemon |
| `configFile` | path | — | Path to Wings `config.yml` (required) |
| `package` | package | built-in | Override the Wings binary |
| `openFirewall` | bool | `true` | Open ports 8080 and 2022 |