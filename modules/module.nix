{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.onec;

  mkOnec = pkgs.callPackage ../pkgs/package.nix { };

  # Пытаемся вытащить версию из имени файла архива, скачанного с портала 1С
  # (например server64_8_3_27_2130.zip — версия кодируется через "_" вместо
  # "."), чтобы не заставлять каждого пользователя вписывать её вручную.
  # Если имя нестандартное — используется cfg.version, заданный явно.
  versionFromFileName =
    let m = builtins.match ".*_([0-9]+)_([0-9]+)_([0-9]+)_([0-9]+)\\.zip" (baseNameOf cfg.archiveFile);
    in if m != null then concatStringsSep "." m else null;

  effectiveVersion =
    if cfg.version != null then cfg.version
    else if versionFromFileName != null then versionFromFileName
    else throw "services.onec.version не задан и не выводится из имени services.onec.archiveFile";

  # "ru" (как и любой другой нелатинский язык интерфейса) — это отдельный
  # УСТАНАВЛИВАЕМЫЙ компонент инсталлятора (--enable-components), а не
  # встроенный по умолчанию функционал: штатный набор по умолчанию у
  # самого инсталлятора — "client_full,langs,en,ru,advanced" ("langs" в
  # этой строке — служебное слово самого --help, а не реальный
  # компонент: в списке "Allowed" его нет, --enable-components его не
  # принимает). Если явно не запросить компонент с кодом cfg.language, в
  # собранный пакет физически не попадают файлы с переводом интерфейса —
  # и тогда ни LANG, ни conf.cfg, ни /L не помогают, потому что
  # переводить нечем. "en" в списке допустимых компонентов не
  # встречается — он всегда в комплекте и отдельно не запрашивается.
  languageComponents = optional (cfg.language != "en") cfg.language;

  serverPackage = mkOnec {
    inherit (cfg) archiveFile language;
    version = effectiveVersion;
    components = unique (cfg.server.components ++ languageComponents);
    pname = "1c-enterprise-server";
  };

  clientPackage = mkOnec {
    inherit (cfg) archiveFile language;
    version = effectiveVersion;
    components = unique (cfg.client.components ++ languageComponents);
    pname = "1c-enterprise-client";
  };

  binDir = "${serverPackage}/opt/1cv8/x86_64/${effectiveVersion}";
in
{
  options.services.onec = {
    enable = mkEnableOption "1С:Предприятие 8.3 (сервер и/или клиент)";

    archiveFile = mkOption {
      type = types.str;
      description = ''
        Абсолютный путь к фирменному дистрибутиву — zip-архиву (например
        server64_8_3_27_2130.zip), скачанному с портала 1С под вашей
        лицензией. Указывается строкой, а не путём-литералом — Nix
        некорректно парсит path-литералы с нелатинскими символами в
        каталогах (например, "Загрузки"). Распаковкой архива и поиском
        внутри него инсталлятора занимается сам Nix во время сборки —
        ничего распаковывать вручную не нужно.
      '';
      example = "/home/user/Downloads/server64_8_3_27_2130/server64_8_3_27_2130.zip";
    };

    version = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Версия дистрибутива. При null выводится из имени файла в
        `archiveFile` (стандартный формат server64_8_3_27_2130.zip).
      '';
    };

    language = mkOption {
      type = types.str;
      default = "ru";
      description = "Язык интерфейса устанавливаемых компонентов (--installer-language).";
    };

    server = {
      enable = mkEnableOption "кластер серверов 1С (ragent/rmngr/rphost) как сервис systemd";

      components = mkOption {
        type = types.listOf types.str;
        default = [ "server" "server_admin" "ws" ];
        description = ''
          Компоненты дистрибутива для серверной части. Полный список
          допустимых значений для конкретной версии — `setup-full-*.run
          --help` (инсталлятор внутри archiveFile).
        '';
      };

      user = mkOption {
        type = types.str;
        default = "usr1cv8";
        description = "Системный пользователь, от имени которого работает кластер.";
      };

      group = mkOption {
        type = types.str;
        default = "grp1cv8";
        description = "Системная группа кластера.";
      };

      port = mkOption {
        type = types.port;
        default = 1540;
        description = "Основной порт агента кластера (ragent).";
      };

      regPort = mkOption {
        type = types.port;
        default = 1541;
        description = "Порт менеджера кластера по умолчанию.";
      };

      portRange = mkOption {
        type = types.str;
        default = "1560:1591";
        description = "Диапазон портов пула соединений рабочих процессов.";
      };

      securityLevel = mkOption {
        type = types.enum [ 0 1 2 ];
        default = 0;
        description = "Уровень защищённости соединений (см. документацию 1С).";
      };

      debugFlags = mkOption {
        type = types.str;
        default = "";
        description = ''Доп. флаги отладки ragent, например "-debug -http".'';
      };

      keytabFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Keytab-файл для Kerberos-аутентификации (необязательно).";
      };

      ras = {
        enable = mkEnableOption "сервер удалённого администрирования (ras)";

        port = mkOption {
          type = types.port;
          default = 1545;
          description = "Порт сервера удалённого администрирования.";
        };

        clusterAddress = mkOption {
          type = types.str;
          default = "";
          description = "Адрес агента кластера, которым управляет ras (пусто = localhost:1540).";
        };
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Открыть в firewall порты кластера (и ras, если он включён).";
      };
    };

    client = {
      enable = mkEnableOption "клиент 1С (толстый/тонкий) в environment.systemPackages";

      components = mkOption {
        type = types.listOf types.str;
        default = [ "client_thin" ];
        example = [ "client_full" ];
        description = ''
          Компоненты дистрибутива для клиентской части, например
          `[ "client_thin" ]` (тонкий клиент) или `[ "client_full" ]`
          (толстый клиент с конфигуратором).
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.client.enable {
      environment.systemPackages = [ clientPackage ];
    })

    (mkIf cfg.server.enable {
      users.groups.${cfg.server.group} = { };
      users.users.${cfg.server.user} = {
        isSystemUser = true;
        group = cfg.server.group;
        home = "/var/lib/1cv8";
        createHome = false;
        description = "1C:Enterprise server";
      };

      systemd.services."1c-ragent" = {
        description = "1C:Enterprise Server 8.3 (${effectiveVersion})";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        # ragent берёт keytab не из аргумента командной строки, а из
        # переменной окружения SRV1CV8_KEYTAB — так делает и штатный
        # .service из дистрибутива.
        environment = optionalAttrs (cfg.server.keytabFile != null) {
          SRV1CV8_KEYTAB = cfg.server.keytabFile;
        };

        serviceConfig = {
          Type = "simple";
          User = cfg.server.user;
          Group = cfg.server.group;
          StateDirectory = "1cv8";
          StateDirectoryMode = "0750";
          ExecStart = concatStringsSep " " ([
            "${binDir}/ragent"
            "-d" "/var/lib/1cv8"
            "-port" (toString cfg.server.port)
            "-regport" (toString cfg.server.regPort)
            "-range" cfg.server.portRange
            "-seclev" (toString cfg.server.securityLevel)
          ] ++ optional (cfg.server.debugFlags != "") cfg.server.debugFlags);
          Restart = "always";
          RestartSec = 1;
        };
      };

      systemd.services."1c-ras" = mkIf cfg.server.ras.enable {
        description = "1C:Enterprise Remote Administration Server 8.3 (${effectiveVersion})";
        after = [ "network.target" "1c-ragent.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          User = cfg.server.user;
          Group = cfg.server.group;
          ExecStart = "${binDir}/ras cluster --port=${toString cfg.server.ras.port} ${cfg.server.ras.clusterAddress}";
          Restart = "always";
          RestartSec = 1;
        };
      };

      networking.firewall = mkIf cfg.server.openFirewall {
        allowedTCPPorts = [ cfg.server.port cfg.server.regPort ]
          ++ optional cfg.server.ras.enable cfg.server.ras.port;
        allowedTCPPortRanges = [
          {
            from = toInt (elemAt (splitString ":" cfg.server.portRange) 0);
            to = toInt (elemAt (splitString ":" cfg.server.portRange) 1);
          }
        ];
      };
    })
  ]);
}
