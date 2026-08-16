{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.postgresql_1c;

  mkPostgresql1c = pkgs.callPackage ../pkgs/postgresql-1c { };

  generatedPackage = mkPostgresql1c {
    inherit (cfg) archiveFile version;
  };

  upstreamAliases = [
    "authentication"
    "checkConfig"
    "dataDir"
    "enableJIT"
    "enableTCPIP"
    "ensureDatabases"
    "ensureUsers"
    "extensions"
    "identMap"
    "initialScript"
    "initdbArgs"
    "settings"
    "systemCallFilter"
  ];
in
{
  imports =
    map (
      name:
      mkAliasOptionModule
        [
          "services"
          "postgresql_1c"
          name
        ]
        [
          "services"
          "postgresql"
          name
        ]
    ) upstreamAliases
    ++ [
      (mkRenamedOptionModule
        [
          "services"
          "postgresql_1c"
          "extraPlugins"
        ]
        [
          "services"
          "postgresql_1c"
          "extensions"
        ]
      )
      (mkRenamedOptionModule
        [
          "services"
          "postgresql_1c"
          "logLinePrefix"
        ]
        [
          "services"
          "postgresql_1c"
          "settings"
          "log_line_prefix"
        ]
      )
      (mkRenamedOptionModule
        [
          "services"
          "postgresql_1c"
          "port"
        ]
        [
          "services"
          "postgresql_1c"
          "settings"
          "port"
        ]
      )
    ];

  options.services.postgresql_1c = {
    enable = mkEnableOption "PostgreSQL 18.1-2.1C for 1C";

    archiveFile = mkOption {
      type = types.either types.path types.str;
      default = "/home/lavr/nixos-config-main/flakes/postgresql_18.1_2_ubuntu_24.04_x86_64_package.tar.bz2";
      description = ''
        Абсолютный путь к архиву PostgreSQL 1C, внутри которого лежат
        Debian-пакеты `postgresql-18`, `postgresql-client-18`, `libpq5`
        и связанные библиотеки. Указывается строкой, как и
        `services.onec.archiveFile`, или path-литералом из вашего flake.
      '';
    };

    version = mkOption {
      type = types.str;
      default = "18.1-2.1C";
      description = "Версия PostgreSQL из 1C-поставки.";
    };

    package = mkOption {
      type = types.package;
      default = generatedPackage;
      defaultText = literalExpression ''
        pkgs.callPackage ../pkgs/postgresql-1c { } {
          archiveFile = config.services.postgresql_1c.archiveFile;
          version = config.services.postgresql_1c.version;
        }
      '';
      description = ''
        Готовый пакет PostgreSQL, который будет передан в
        `services.postgresql.package`. По умолчанию собирается PostgreSQL
        1C из `archiveFile`.
      '';
    };

    addToSystemPackages = mkOption {
      type = types.bool;
      default = true;
      description = "Добавить клиентские утилиты PostgreSQL 1C в environment.systemPackages.";
    };

  };

  config = mkIf cfg.enable {
    services.postgresql = {
      enable = mkDefault true;
      package = mkOverride 900 cfg.package;
      enableJIT = mkDefault false;
      settings.jit = mkDefault "off";
    };

    environment.systemPackages = mkIf cfg.addToSystemPackages [ cfg.package ];

    systemd.services.postgresql.serviceConfig.BindReadOnlyPaths = [
      "${pkgs.tzdata}/share/zoneinfo:/usr/share/zoneinfo"
    ];
  };
}
