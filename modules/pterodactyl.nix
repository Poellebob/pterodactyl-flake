{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.services.pterodactyl;

  # PHP 8.1 with all extensions Pterodactyl needs.
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
in {
  options.services.pterodactyl = {
    enable = mkEnableOption "Pterodactyl panel";

    domain = mkOption {
      type    = types.str;
      example = "panel.example.com";
      description = mdDoc ''
        Public domain (or IP) for the panel.
        Used as the Nginx `server_name` and, when `useACME` is true,
        as the Let's Encrypt certificate domain.
      '';
    };

    useACME = mkOption {
      type    = types.bool;
      default = true;
      description = mdDoc ''
        Whether to provision a Let's Encrypt certificate via ACME.
        Set to false if you are behind a reverse proxy that already terminates TLS,
        or if you want to bring your own certificate.
      '';
    };

    dataDir = mkOption {
      type    = types.str;
      default = "/srv/pterodactyl";
      example = "/var/www/pterodactyl";
      description = mdDoc ''
        Directory where the Pterodactyl panel files live.
        After deploying, run the one-time setup described in README.md.
      '';
    };

    user = mkOption {
      type    = types.str;
      default = "pterodactyl";
      description = mdDoc "System user that owns the panel files and runs php-fpm / the queue worker.";
    };

    redisName = mkOption {
      type    = types.str;
      default = "pterodactyl";
      description = mdDoc "Name for the dedicated Redis server instance.";
    };

    dbName = mkOption {
      type    = types.str;
      default = "pterodactyl";
      description = mdDoc "MySQL database name for the panel.";
    };

    dbUser = mkOption {
      type    = types.str;
      default = "pterodactyl";
      description = mdDoc "MySQL user for the panel.";
    };

    # Path to an agenix-managed secret containing the DB password (plain text).
    dbPasswordFile = mkOption {
      type    = types.nullOr types.path;
      default = null;
      example = "/run/agenix/pterodactyl-db-password";
      description = mdDoc ''
        Path to a file containing the database password.
        Use together with agenix or any other secret provider.
        When null, the password is left empty (only suitable for local dev).
      '';
    };
  };

  # ─── Implementation ────────────────────────────────────────────────────────

  config = mkIf cfg.enable {

    # ── Users ────────────────────────────────────────────────────────────────
    users.users.${cfg.user} = {
      isSystemUser = true;
      createHome   = true;
      home         = cfg.dataDir;
      group        = cfg.user;
    };
    users.groups.${cfg.user} = {};

    # ── Database (MariaDB) ───────────────────────────────────────────────────
    services.mysql = {
      enable  = true;
      package = pkgs.mariadb;
      ensureDatabases = [ cfg.dbName ];
      ensureUsers = [
        {
          name = cfg.dbUser;
          ensurePermissions = {
            "${cfg.dbName}.*" = "ALL PRIVILEGES";
          };
        }
      ];
    };

    # ── Redis ────────────────────────────────────────────────────────────────
    services.redis.servers.${cfg.redisName} = {
      enable = true;
      port   = 6379;
    };

    # ── PHP-FPM ──────────────────────────────────────────────────────────────
    services.phpfpm.pools.pterodactyl = {
      user     = cfg.user;
      phpPackage = pteroPhp;
      settings = {
        "listen.owner"             = config.services.nginx.user;
        "pm"                       = "dynamic";
        "pm.start_servers"         = 4;
        "pm.min_spare_servers"     = 4;
        "pm.max_spare_servers"     = 16;
        "pm.max_children"          = 64;
        "pm.max_requests"          = 256;
        "clear_env"                = false;
        "catch_workers_output"     = true;
        "decorate_workers_output"  = false;
        "php_admin_value[error_log]"  = "stderr";
        "php_admin_flag[daemonize]"   = "false";
      };
    };

    # ── Nginx ────────────────────────────────────────────────────────────────
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
          enableACME    = true;
          forceSSL      = true;
        })
      ];
    };

    # ACME contact e-mail — override in your configuration.nix.
    security.acme = mkIf cfg.useACME {
      acceptTerms = true;
      defaults.email = "admin@${cfg.domain}";
    };

    # ── Queue worker (pteroq) ────────────────────────────────────────────────
    systemd.services.pteroq = {
      description = "Pterodactyl Queue Worker";
      after        = [ "redis-${cfg.redisName}.service" "mysql.service" ];
      requires     = [ "redis-${cfg.redisName}.service" "mysql.service" ];
      wantedBy     = [ "multi-user.target" ];

      unitConfig.StartLimitInterval = 180;

      serviceConfig = {
        User       = cfg.user;
        Group      = cfg.user;
        Restart    = "always";
        RestartSec = "5s";
        StartLimitBurst = 30;
        ExecStart  = "${pteroPhp}/bin/php ${cfg.dataDir}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3";
      };
    };

    # ── Firewall ─────────────────────────────────────────────────────────────
    networking.firewall.allowedTCPPorts = [ 80 443 ];

    # ── Extra packages (available on the system for manual artisan commands) ─
    environment.systemPackages = [
      pteroPhp
      pteroComposer
    ];
  };
}
