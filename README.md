# pterodactyl-flake

NixOS flake for running Pterodactyl panel + Wings on a single machine, with automated panel setup.

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
{ config, ... }:
{
  services.pterodactyl = {
    enable  = true;
    domain  = "panel.example.com";
    useACME = true;

    # Optional — customize database, redis, and admin settings:
    # database.passwordFile = "/run/agenix/ptero-db-password";
    # database.host = "127.0.0.1";  # default
    # database.port = 3306;          # default
    # redis.host = "127.0.0.1";     # default
    # redis.port = 6379;            # default
    # admin.emailFile = "/run/agenix/ptero-admin-email";
    # admin.passwordFile = "/run/agenix/ptero-admin-password";
  };

  services.wings = {
    enable = true;
    # Paste the config.yml path here after creating the node in the panel.
    # configFile = "/run/agenix/wings-config";
  };
}
```

---

## Automated panel setup

The panel setup runs **automatically** via `pterodactyl-setup` systemd service. The setup is **idempotent** and **config-aware**:

- **First boot**: Downloads panel, configures environment, creates admin user
- **Config changes**: When you change `domain`, `timezone`, `database.*`, `redis.*`, or `admin.*` options, NixOS automatically re-runs the setup to apply changes
- **Safe re-runs**: Already-completed steps (download, key generation, admin creation) are skipped on subsequent runs

### Initial setup

Configure the required options and rebuild:

```nix
services.pterodactyl = {
  enable = true;
  domain  = "panel.example.com";
  admin.emailFile = "/run/agenix/ptero-admin-email";
  admin.passwordFile = "/run/agenix/ptero-admin-password";
  # Optional: database.passwordFile = "/run/agenix/ptero-db-password";
};
```

After `nixos-rebuild switch && reboot` (or just `nixos-rebuild switch` if already running), check:
```bash
systemctl status pterodactyl-setup
journalctl -u pterodactyl-setup -f
```

### Automatic re-setup on config changes

When you modify relevant configuration (domain, database settings, redis settings, admin settings), the setup service automatically re-runs on next `nixos-rebuild switch`:

```nix
# Example: Change domain - setup will re-run automatically
services.pterodactyl.domain = "new-panel.example.com";
```

No manual intervention needed - NixOS handles everything through the config hash mechanism.

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
sudo systemctl restart wings
sudo systemctl status wings
```

---

## Secrets with agenix

If you are already using agenix, encrypt both secrets and reference them instead of plain paths.

```bash
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
  age.secrets."ptero-admin-email" = {
    file  = ./secrets/ptero-admin-email.age;
    owner = "pterodactyl";
  };
  age.secrets."ptero-admin-password" = {
    file  = ./secrets/ptero-admin-password.age;
    owner = "pterodactyl";
  };
  age.secrets."wings-config" = {
    file  = ./secrets/wings-config.age;
    owner = "root";
    mode  = "0600";
  };

  services.pterodactyl = {
    enable = true;
    domain = "panel.example.com";
    database.passwordFile = config.age.secrets."ptero-db-password".path;
    admin.emailFile = config.age.secrets."ptero-admin-email".path;
    admin.passwordFile = config.age.secrets."ptero-admin-password".path;
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

#### Top-level options

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the panel |
| `domain` | str | — | Public domain / Nginx vhost |
| `useACME` | bool | `true` | Auto-provision Let's Encrypt cert |
| `dataDir` | str | `/srv/pterodactyl` | Panel file location |
| `timezone` | str | `UTC` | Timezone for the panel |
| `user` | str | `pterodactyl` | System user for php-fpm + queue worker |

#### `services.pterodactyl.database`

| Option | Type | Default | Description |
|---|---|---|---|
| `name` | str | `pterodactyl` | MariaDB database name |
| `user` | str | `pterodactyl` | MariaDB user |
| `passwordFile` | path\|null | `null` | File containing the DB password |
| `host` | str | `127.0.0.1` | MariaDB host address |
| `port` | port | `3306` | MariaDB port |

#### `services.pterodactyl.redis`

| Option | Type | Default | Description |
|---|---|---|---|
| `name` | str | `pterodactyl` | Redis server instance name |
| `host` | str | `127.0.0.1` | Redis host address |
| `port` | port | `6379` | Redis port |

#### `services.pterodactyl.admin`

| Option | Type | Default | Description |
|---|---|---|---|
| `emailFile` | path | — | File containing admin e-mail (required) |
| `passwordFile` | path | — | File containing admin password (required) |
| `username` | str | `admin` | Initial admin username |
| `firstName` | str | `Panel` | Initial admin first name |
| `lastName` | str | `Admin` | Initial admin last name |

### `services.wings`

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the Wings daemon |
| `configFile` | path | — | Path to Wings `config.yml` (required) |
| `package` | package | built-in | Override the Wings binary |
| `openFirewall` | bool | `true` | Open ports 8080 and 2022 |
