{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.services.pterodactyl;

  pteroPhp = pkgs.php81.buildEnv {
    extensions = { enabled, all, ... }: enabled ++ (with all; [
      redis
      gd
      curl
      mbstring
      xml
      zip
      bcmath
      sodium
      intl
      openssl
    ]);
    extraConfig = ''
      upload_max_filesize = 100M
      post_max_size       = 100M
    '';
  };

  pteroComposer = pkgs.php81Packages.composer.override { php = pteroPhp; };

  # Hash of relevant config - changes when panel config changes, triggering re-setup
  relevantConfig = {
    domain = cfg.domain;
    timezone = cfg.timezone;
    database = { inherit (cfg.database) name user host port; };
    redis = { inherit (cfg.redis) name host port; };
    admin = { inherit (cfg.admin) username firstName lastName; };
  };
  configHash = builtins.substring 0 8 (builtins.hashString "sha256" (builtins.toJSON relevantConfig));
  markerFile = "${cfg.dataDir}/.setup-done-${configHash}";

  appUrl = if cfg.useACME then "https://${cfg.domain}" else "http://${cfg.domain}";

  setupScript = pkgs.writeShellScript "pterodactyl-setup" ''
    set -euo pipefail

    PHP="${pteroPhp}/bin/php"
    COMPOSER="${pteroComposer}/bin/composer"
    ARTISAN="$PHP ${cfg.dataDir}/artisan"

    # Download and extract panel only if not already present
    if [ ! -f "${cfg.dataDir}/artisan" ]; then
      echo "pterodactyl-setup: downloading panel..."
      mkdir -p "${cfg.dataDir}"
      ${pkgs.curl}/bin/curl -fsSL \
        https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
        -o /tmp/pterodactyl-panel.tar.gz

      tar --strip-components=1 -xzf /tmp/pterodactyl-panel.tar.gz -C "${cfg.dataDir}"
      rm /tmp/pterodactyl-panel.tar.gz

      echo "pterodactyl-setup: running composer install..."
      cd "${cfg.dataDir}"
      HOME="${cfg.dataDir}" \
        COMPOSER_HOME="${cfg.dataDir}/.composer" \
        $COMPOSER install --no-dev --optimize-autoloader --no-interaction
    else
      echo "pterodactyl-setup: panel already present, skipping download."
    fi

    DB_PASSWORD=""
    ${optionalString (cfg.database.passwordFile != null) ''
      DB_PASSWORD=$(cat "${cfg.database.passwordFile}")
    ''}
    ADMIN_PASSWORD=$(cat "${cfg.admin.passwordFile}")
    ADMIN_EMAIL=$(cat "${cfg.admin.emailFile}")

    # Generate app key only if not already set
    if ! grep -q "^APP_KEY=" "${cfg.dataDir}/.env" 2>/dev/null; then
      echo "pterodactyl-setup: generating app key..."
      $ARTISAN key:generate --force
    else
      echo "pterodactyl-setup: app key already exists, skipping."
    fi

    echo "pterodactyl-setup: configuring environment..."
    $ARTISAN p:environment:setup \
      --no-interaction \
      --author="$ADMIN_EMAIL" \
      --url="${appUrl}" \
      --timezone="${cfg.timezone}" \
      --cache=redis \
      --session=redis \
      --queue=redis \
      --redis-host=${cfg.redis.host} \
      --redis-port=${cfg.redis.port}

    echo "pterodactyl-setup: configuring database..."
    $ARTISAN p:environment:database \
      --no-interaction \
      --host=${cfg.database.host} \
      --port=${cfg.database.port} \
      --database="${cfg.database.name}" \
      --username="${cfg.database.user}" \
      --password="$DB_PASSWORD"

    echo "pterodactyl-setup: running migrations..."
    $ARTISAN migrate --seed --force

    # Create admin user only if APP_KEY exists (indicates setup was done)
    if [ ! -f "${cfg.dataDir}/.env" ] || ! grep -q "^APP_KEY=" "${cfg.dataDir}/.env" 2>/dev/null; then
      echo "pterodactyl-setup: creating admin user..."
      $ARTISAN p:user:make \
        --no-interaction \
        --email="$ADMIN_EMAIL" \
        --username="${cfg.admin.username}" \
        --name-first="${cfg.admin.firstName}" \
        --name-last="${cfg.admin.lastName}" \
        --password="$ADMIN_PASSWORD" \
        --admin=1
    else
      echo "pterodactyl-setup: admin user likely exists, skipping creation."
    fi

    chown -R "${cfg.user}:${cfg.user}" "${cfg.dataDir}"
    chmod -R 755 "${cfg.dataDir}/storage" "${cfg.dataDir}/bootstrap/cache"

    touch "${markerFile}"
    echo "pterodactyl-setup: complete."
  '';
in {
  options.services.pterodactyl = {
    enable = mkEnableOption "Pterodactyl panel";

    domain = mkOption {
      type    = types.str;
      example = "panel.example.com";
      description = mdDoc "Public domain for the panel. Used as Nginx server_name and ACME cert domain.";
    };

    useACME = mkOption {
      type    = types.bool;
      default = true;
      description = mdDoc "Provision a Let's Encrypt cert. Set false if TLS is terminated upstream.";
    };

    dataDir = mkOption {
      type    = types.str;
      default = "/srv/pterodactyl";
      description = mdDoc "Directory where the panel files will be extracted to.";
    };

    timezone = mkOption {
      type    = types.str;
      default = "UTC";
      example = "Europe/Copenhagen";
      description = mdDoc "Timezone passed to p:environment:setup.";
    };

    user = mkOption {
      type    = types.str;
      default = "pterodactyl";
      description = mdDoc "System user that owns the panel files and runs php-fpm / the queue worker.";
    };

    database = {
      name = mkOption {
        type    = types.str;
        default = "pterodactyl";
        description = mdDoc "MariaDB database name.";
      };

      user = mkOption {
        type    = types.str;
        default = "pterodactyl";
        description = mdDoc "MariaDB user.";
      };

      passwordFile = mkOption {
        type    = types.nullOr types.path;
        default = null;
        example = "/run/agenix/ptero-db-password";
        description = mdDoc "File containing the DB password (no trailing newline). Null = empty password.";
      };

      host = mkOption {
        type    = types.str;
        default = "127.0.0.1";
        description = mdDoc "MariaDB host address.";
      };

      port = mkOption {
        type    = types.port;
        default = 3306;
        description = mdDoc "MariaDB port.";
      };
    };

    redis = {
      name = mkOption {
        type    = types.str;
        default = "pterodactyl";
        description = mdDoc "Name for the dedicated Redis server instance.";
      };

      host = mkOption {
        type    = types.str;
        default = "127.0.0.1";
        description = mdDoc "Redis host address.";
      };

      port = mkOption {
        type    = types.port;
        default = 6379;
        description = mdDoc "Redis port.";
      };
    };

    admin = {
      emailFile = mkOption {
        type    = types.path;
        example = "/run/agenix/ptero-admin-email";
        description = mdDoc "File containing the admin e-mail address (no trailing newline). Required.";
      };

      passwordFile = mkOption {
        type    = types.path;
        example = "/run/agenix/ptero-admin-password";
        description = mdDoc "File containing the admin password, min 8 chars (no trailing newline). Required.";
      };

      username = mkOption {
        type    = types.str;
        default = "admin";
        description = mdDoc "Username for the initial admin account.";
      };

      firstName = mkOption {
        type    = types.str;
        default = "Panel";
        description = mdDoc "First name for the initial admin account.";
      };

      lastName = mkOption {
        type    = types.str;
        default = "Admin";
        description = mdDoc "Last name for the initial admin account.";
      };
    };
  };

  config = mkIf cfg.enable {

    users.users.${cfg.user} = {
      isSystemUser = true;
      createHome   = true;
      home         = cfg.dataDir;
      group        = cfg.user;
    };
    users.groups.${cfg.user} = {};

    services.mysql = {
      enable  = true;
      package = pkgs.mariadb;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [{
        name = cfg.database.user;
        ensurePermissions = { "${cfg.database.name}.*" = "ALL PRIVILEGES"; };
      }];
    };

    services.redis.servers.${cfg.redis.name} = {
      enable = true;
      bind   = cfg.redis.host;
      port   = cfg.redis.port;
    };

    systemd.services.pterodactyl-setup = {
      description = "Pterodactyl panel automated setup";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network-online.target" "mysql.service" "redis-${cfg.redis.name}.service" ];
      requires    = [ "mysql.service" "redis-${cfg.redis.name}.service" ];

      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        User            = "root";
        ExecStart       = setupScript;
        TimeoutStartSec = "10min";
        PrivateTmp      = true;
      };
    };

    systemd.services.pteroq = {
      description = "Pterodactyl Queue Worker";
      after       = [ "pterodactyl-setup.service" "redis-${cfg.redis.name}.service" "mysql.service" ];
      requires    = [ "pterodactyl-setup.service" "redis-${cfg.redis.name}.service" "mysql.service" ];
      wantedBy    = [ "multi-user.target" ];

      unitConfig.StartLimitInterval = 180;

      serviceConfig = {
        User            = cfg.user;
        Group           = cfg.user;
        Restart         = "always";
        RestartSec      = "5s";
        StartLimitBurst = 30;
        ExecStart       = "${pteroPhp}/bin/php ${cfg.dataDir}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3";
      };
    };

    systemd.services.phpfpm-pterodactyl = {
      after    = [ "pterodactyl-setup.service" ];
      requires = [ "pterodactyl-setup.service" ];
    };

    services.phpfpm.pools.pterodactyl = {
      user       = cfg.user;
      phpPackage = pteroPhp;
      settings = {
        "listen.owner"            = config.services.nginx.user;
        "pm"                      = "dynamic";
        "pm.start_servers"        = 4;
        "pm.min_spare_servers"    = 4;
        "pm.max_spare_servers"    = 16;
        "pm.max_children"         = 64;
        "pm.max_requests"         = 256;
        "clear_env"               = false;
        "catch_workers_output"    = true;
        "decorate_workers_output" = false;
        "php_admin_value[error_log]" = "stderr";
        "php_admin_flag[daemonize]"  = "false";
      };
    };

    services.nginx = {
      enable = true;
      virtualHosts.${cfg.domain} = mkMerge [
        {
          root = "${cfg.dataDir}/public";
          extraConfig = ''
            index index.php;
            charset utf-8;
          '';
          locations = {
            "/" = {
              tryFiles = "$uri $uri/ /index.php?$query_string";
            };
            "~ \\.php$" = {
              extraConfig = ''
                fastcgi_split_path_info ^(.+\.php)(/.+)$;
                fastcgi_pass unix:${config.services.phpfpm.pools.pterodactyl.socket};
                include ${pkgs.nginx}/conf/fastcgi_params;
                fastcgi_index index.php;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_param HTTP_PROXY "";
                fastcgi_intercept_errors off;
                fastcgi_buffer_size 16k;
                fastcgi_buffers 4 16k;
                fastcgi_connect_timeout 300;
                fastcgi_send_timeout    300;
                fastcgi_read_timeout    300;
              '';
            };
            "~ /\\.ht" = {
              extraConfig = "deny all;";
            };
          };
        }
        (mkIf cfg.useACME {
          enableACME = true;
          forceSSL   = true;
        })
      ];
    };

    security.acme = mkIf cfg.useACME {
      acceptTerms    = true;
      defaults.email = "admin@${cfg.domain}";
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];

    environment.systemPackages = [ pteroPhp pteroComposer ];
  };
}
