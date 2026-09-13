{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.onec;

  mkOnec = pkgs.callPackage ../pkgs/package.nix { };

  # Версия выводится из имени файла дистрибутива (server64_8_3_XX_XXXX.zip);
  # при нестандартном имени задайте её явно.
  versionFromArchive =
    archive:
    let
      m = builtins.match ".*_([0-9]+)_([0-9]+)_([0-9]+)_([0-9]+)\\.zip" (baseNameOf archive);
    in
    if m != null then concatStringsSep "." m else null;

  resolveVersion =
    what: archiveFile: version:
    if version != null then
      version
    else if versionFromArchive archiveFile != null then
      versionFromArchive archiveFile
    else
      throw "services.onec: ${what} — version не задана и не выводится из имени архива '${archiveFile}'";

  # Нелатинский язык интерфейса — отдельный устанавливаемый компонент
  # (--enable-components), без него файлы перевода не попадают в сборку.
  # "en" в список компонентов не добавляется — он всегда в комплекте.
  languageComponents = optional (cfg.language != "en") cfg.language;

  clientVersion = resolveVersion "client" cfg.archiveFile cfg.version;
  webConfigFile = "${cfg.web.stateDir}/httpd.conf";

  clientPackage = mkOnec {
    inherit (cfg) archiveFile language;
    version = clientVersion;
    # Компонент ws ставится только для web.enable: он содержит webinst и
    # wsap24.so. Пользователю не нужно дублировать его в client.components.
    components = unique (cfg.client.components ++ optional cfg.web.enable "ws" ++ languageComponents);
    pname = "1c-enterprise-client";
    webinstConfigPath = if cfg.web.enable then webConfigFile else null;
  };

  # ---------------------------------------------------------------------
  # Инстансы сервера
  # ---------------------------------------------------------------------

  enabledInstances = filterAttrs (_: i: i.enable) cfg.server.instances;

  # archiveFile/version по умолчанию общие, но каждый инстанс может их
  # переопределить — так на одной машине можно поднять сервера разных версий.
  instArchive = i: if i.archiveFile != null then i.archiveFile else cfg.archiveFile;
  instVersion = name: i: resolveVersion "instance '${name}'" (instArchive i) i.version;

  instPackage =
    name: i:
    mkOnec {
      archiveFile = instArchive i;
      language = cfg.language;
      version = instVersion name i;
      components = unique (i.components ++ languageComponents);
      pname = "1c-enterprise-server";
    };

  # Каталог данных нужно создать и передать пользователю сервиса до старта;
  # "+" перед ExecStartPre запускает эту команду от root.
  prepareDataDir =
    unit: dir:
    "+"
    + toString (
      pkgs.writeShellScript "1c-prepare-${unit}" ''
        mkdir -p ${escapeShellArg dir}
        chown -R ${escapeShellArg cfg.server.user}:${escapeShellArg cfg.server.group} ${escapeShellArg dir}
      ''
    );

  # 1С ищет опциональные клиентские библиотеки СУБД через `ldconfig -p | awk`,
  # но gawk отсутствует в PATH сервиса systemd на NixOS — даём его явно.
  servicePath = [ pkgs.gawk ];

  commonServiceConfig = {
    Type = "simple";
    User = cfg.server.user;
    Group = cfg.server.group;
    WorkingDirectory = cfg.server.home;
    Restart = "always";
    RestartSec = 1;
  };

  parseRange =
    range:
    let
      parts = splitString ":" range;
    in
    {
      from = toInt (elemAt parts 0);
      to = toInt (elemAt parts 1);
    };

  # ibcmd/ibsrv кладутся в PATH с суффиксом версии (ibcmd-8.3.XX.XXXX),
  # иначе одноимённые бинарники разных версий перекрыли бы друг друга.
  programPackages =
    let
      entries = concatLists (
        mapAttrsToList (
          name: i:
          let
            v = instVersion name i;
            pkg = instPackage name i;
            mk = prog: {
              name = "${prog}-${v}";
              value = pkgs.writeShellScriptBin "${prog}-${v}" ''
                exec ${pkg}/bin/${prog} "$@"
              '';
            };
          in
          optional i.programs.ibcmd.enable (mk "ibcmd") ++ optional i.programs.ibsrv.enable (mk "ibsrv")
        ) enabledInstances
      );
    in
    attrValues (listToAttrs entries);

  instanceType = types.submodule {
    options = {
      enable = mkEnableOption "этот инстанс сервера 1С";

      archiveFile = mkOption {
        type = types.nullOr (types.either types.path types.str);
        default = null;
        description = ''
          Дистрибутив для этого инстанса. При null берётся общий
          `services.onec.archiveFile`. Задавать имеет смысл только если
          инстансы разных версий — у каждой версии свой архив.
        '';
      };

      version = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Версия инстанса. При null выводится из имени файла архива
          (стандартный формат server64_8_3_XX_XXXX.zip).
        '';
      };

      components = mkOption {
        type = types.listOf types.str;
        default = [
          "server"
          "server_admin"
          "ws"
        ];
        description = ''
          Компоненты дистрибутива для этого инстанса. Полный список
          допустимых значений для конкретной версии — `setup-full-*.run
          --help` (инсталлятор внутри архива).
        '';
      };

      programs = {
        ibcmd.enable = mkEnableOption "утилиту ibcmd в PATH (как ibcmd-<версия>)";
        ibsrv.enable = mkEnableOption "утилиту ibsrv в PATH (как ibsrv-<версия>)";
      };

      services = {
        full-server = {
          enable = mkEnableOption "кластер серверов 1С (ragent/rmngr/rphost)";

          openFirewall = mkOption {
            type = types.bool;
            default = false;
            description = "Открыть в firewall порты кластера.";
          };

          settings = {
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
            debug = mkOption {
              type = types.str;
              default = "";
              description = ''
                Режим отладки конфигураций:
                выключен — пусто (по умолчанию),
                по TCP   — "-debug" или "-debug -tcp",
                по HTTP  — "-debug -http".
              '';
            };
            data = mkOption {
              type = types.str;
              default = "/var/lib/1cv8";
              description = "Каталог данных кластера.";
            };
            securityLevel = mkOption {
              type = types.enum [
                0
                1
                2
              ];
              default = 0;
              description = ''
                0 — незащищённые соединения (по умолчанию),
                1 — защищённые только на время аутентификации,
                2 — постоянно защищённые соединения.
              '';
            };
            pingPeriod = mkOption {
              type = types.int;
              default = 1000;
              description = "Период проверки детектора потери соединения, мс.";
            };
            pingTimeout = mkOption {
              type = types.int;
              default = 5000;
              description = "Таймаут ответа детектора потери соединения, мс.";
            };
            keytabFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = ''
                Keytab-файл для Kerberos-аутентификации. ragent берёт его
                не из аргумента командной строки, а из переменной
                окружения SRV1CV8_KEYTAB — так делает и штатный .service
                из дистрибутива.
              '';
            };
            extraArgs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Дополнительные аргументы командной строки ragent.";
            };
          };
        };

        standalone-server = {
          enable = mkEnableOption "автономный сервер (ibsrv)";

          openFirewall = mkOption {
            type = types.bool;
            default = false;
            description = "Открыть в firewall порты автономного сервера.";
          };

          settings = {
            http = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Доступ к автономному серверу по HTTP.";
              };
              port = mkOption {
                type = types.port;
                default = 8314;
                description = "Основной TCP-порт HTTP-шлюза.";
              };
            };
            data = mkOption {
              type = types.str;
              default = "/var/lib/1cv8-standalone";
              description = "Каталог данных автономного сервера.";
            };
            name = mkOption {
              type = types.str;
              default = "";
              description = ''
                Имя информационной базы. При пустом значении используется
                строковое представление идентификатора базы.
              '';
            };
            direct-regport = mkOption {
              type = types.port;
              default = 1541;
              description = "Основной порт для прямого соединения с сервером.";
            };
            direct-range = mkOption {
              type = types.str;
              default = "1560:1591";
              description = "Диапазон портов для прямого соединения с сервером.";
            };
            debug-port = mkOption {
              type = types.port;
              default = 1550;
              description = "TCP-порт сервера отладки по HTTP.";
            };
            extraArgs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Дополнительные аргументы командной строки ibsrv.";
            };
          };
        };

        ras = {
          enable = mkEnableOption "сервер удалённого администрирования (ras)";

          openFirewall = mkOption {
            type = types.bool;
            default = false;
            description = "Открыть в firewall порт ras.";
          };

          port = mkOption {
            type = types.port;
            default = 1545;
            description = "Порт сервера удалённого администрирования.";
          };

          clusterAddress = mkOption {
            type = types.str;
            default = "";
            description = "Адрес агента кластера (пусто = localhost:1540).";
          };
        };
      };
    };
  };
in
{
  options.services.onec = {
    enable = mkEnableOption "1С:Предприятие 8.3 (сервер и/или клиент)";

    archiveFile = mkOption {
      type = types.either types.path types.str;
      description = ''
        Абсолютный путь к фирменному дистрибутиву — zip-архиву (например
        server64_8_3_XX_XXXX.zip), скачанному с портала 1С под вашей
        лицензией. Можно указывать path-литералом из flake или строкой с
        абсолютным путём. Строка полезна для путей с нелатинскими
        символами в каталогах (например, "Загрузки"). Распаковкой архива и поиском
        внутри него инсталлятора занимается сам Nix во время сборки —
        ничего распаковывать вручную не нужно.
      '';
      example = "/home/user/Downloads/server64_8_3_XX_XXXX/server64_8_3_XX_XXXX.zip";
    };

    version = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Версия дистрибутива. При null выводится из имени файла в
        `archiveFile` (стандартный формат server64_8_3_XX_XXXX.zip).
      '';
    };

    language = mkOption {
      type = types.str;
      default = "ru";
      description = "Язык интерфейса устанавливаемых компонентов (--installer-language).";
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

      linkToOpt = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Опубликовать клиент по штатному для 1С пути
          `/opt/1cv8/x86_64/<версия>` (симлинк через systemd-tmpfiles).

          Нужно для 1C:EDT: версии платформы он ищет, перебирая подкаталоги
          `/opt/1cv8/i386` и `/opt/1cv8/x86_64` (раскладка единого
          дистрибутива, 8.3.18+) и `/opt/1C/v8.3/<арх>` (старая, по одной
          версии), а саму версию берёт из имени каталога. Запускает он
          затем `1cv8`, `1cv8c`, `dbgs` и `rphost` прямо оттуда, поэтому
          публикуется не каталог пакета напрямую, а `passthru.optTree` —
          дерево симлинков, в котором клиентские бинарники подменены
          обёртками из `bin/` (голые падают без GTK-окружения).

          Толстый клиент EDT нужен обязательно: с `client_thin` в каталоге
          не будет ни `1cv8`, ни конфигуратора, и EDT сочтёт такую версию
          непригодной.
        '';
      };
    };

    web = {
      enable = mkEnableOption "публикацию веб-клиента из Конфигуратора через Apache 2.4";

      stateDir = mkOption {
        type = types.str;
        default = "/var/lib/1c-web";
        description = ''
          Каталог с изменяемой конфигурацией публикаций, которые создаёт
          Конфигуратор. Файл `httpd.conf` в этом каталоге подключается в
          основную конфигурацию Apache и не перезаписывается `nixos-rebuild`.
        '';
      };
    };

    server = {
      user = mkOption {
        type = types.str;
        default = "usr1cv8";
        description = "Системный пользователь, от имени которого работают сервисы 1С.";
      };

      group = mkOption {
        type = types.str;
        default = "grp1cv8";
        description = "Системная группа сервисов 1С.";
      };

      home = mkOption {
        type = types.str;
        default = "/var/lib/usr1cv8";
        description = "Домашний каталог служебного пользователя (рабочий каталог сервисов).";
      };

      instances = mkOption {
        type = types.attrsOf instanceType;
        default = { };
        description = ''
          Набор инстансов сервера. Ключ — метка инстанса, она же попадает
          в имена юнитов (1c-server-<метка>.service и т.п.). Каждый
          инстанс может поднимать кластерный сервер (ragent), автономный
          сервер (ibsrv) и ras — независимо друг от друга.
        '';
        example = literalExpression ''
          {
            main = {
              enable = true;
              programs.ibcmd.enable = true;
              services.standalone-server = {
                enable = true;
                openFirewall = true;
                settings.name = "main";
              };
            };
          }
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.client.enable {
      environment.systemPackages = [ clientPackage ];
    })

    (mkIf (cfg.client.enable && cfg.client.linkToOpt) {
      systemd.tmpfiles.rules = [
        "d /opt/1cv8 0755 root root -"
        "d /opt/1cv8/x86_64 0755 root root -"
        "L+ /opt/1cv8/x86_64/${clientVersion} - - - - ${clientPackage.optTree}"
      ];
    })

    (mkIf cfg.web.enable {
      assertions = [
        {
          assertion = cfg.client.enable;
          message = "services.onec.web.enable требует services.onec.client.enable = true";
        }
        {
          assertion = elem "client_full" cfg.client.components;
          message = "services.onec.web.enable требует components = [ \"client_full\" … ]; Конфигуратор отсутствует в client_thin";
        }
        {
          assertion = cfg.client.linkToOpt;
          message = "services.onec.web.enable требует services.onec.client.linkToOpt = true, чтобы Конфигуратор запускал webinst из /opt";
        }
        {
          assertion = config.services.httpd.enable;
          message = "services.onec.web.enable требует включённый services.httpd.enable";
        }
      ];

      # Apache получает модуль 1С декларативно. Имя DSO-символа начинается
      # с подчёркивания, поэтому это именно _1cws, а не имя файла wsap24.
      services.httpd = {
        enable = mkDefault true;
        mpm = mkDefault "worker";
        extraModules = mkAfter [
          {
            name = "_1cws";
            path = "${clientPackage}/opt/1cv8/x86_64/${clientVersion}/wsap24.so";
          }
        ];
        extraConfig = mkAfter ''
          # Публикации, созданные в Конфигураторе через webinst.
          IncludeOptional ${webConfigFile}
        '';
      };

      # Конфигуратор распознаёт Apache по RPM-путям. На NixOS они отсутствуют,
      # поэтому даём совместимые ссылки, не заменяя существующие пользовательские
      # файлы (тип L без +). Запись webinst всегда перенаправляется обёрткой
      # в webConfigFile, а не в неизменяемый /etc/httpd/httpd.conf.
      systemd.tmpfiles.rules = [
        "d ${cfg.web.stateDir} 0755 root root -"
        "f ${webConfigFile} 0644 root root -"
        "d /etc/httpd/conf 0755 root root -"
        "L /etc/httpd/conf/httpd.conf - - - - /etc/httpd/httpd.conf"
        "d /usr/sbin 0755 root root -"
        "L /usr/sbin/httpd - - - - ${config.services.httpd.package.out}/bin/httpd"
        "L /usr/sbin/apachectl - - - - /run/current-system/sw/bin/apachectl"
      ];

      # webinst переписывает файл публикаций атомарно. Проверяем обновлённую
      # конфигурацию и перезагружаем Apache без ручного systemctl restart.
      systemd.paths.onec-web-reload-httpd = {
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = [ webConfigFile ];
          Unit = "onec-web-reload-httpd.service";
        };
      };

      systemd.services.onec-web-reload-httpd = {
        description = "Reload Apache after 1C web publication changes";
        after = [ "httpd.service" ];
        path = [ config.services.httpd.package pkgs.systemd ];
        serviceConfig.Type = "oneshot";
        script = ''
          if httpd -t -f /etc/httpd/httpd.conf; then
            systemctl reload httpd.service
          fi
        '';
      };
    })

    (mkIf (enabledInstances != { }) {
      users.groups.${cfg.server.group} = { };
      users.users.${cfg.server.user} = {
        isSystemUser = true;
        group = cfg.server.group;
        home = cfg.server.home;
        createHome = true;
        # Без двоеточия: это разделитель полей в /etc/passwd.
        description = "1C Enterprise server";
      };

      environment.systemPackages = programPackages;

      systemd.services = concatMapAttrs (
        name: i:
        let
          pkg = instPackage name i;
          full = i.services.full-server;
          standalone = i.services.standalone-server;
          ras = i.services.ras;
          v = instVersion name i;
        in
        optionalAttrs full.enable {
          "1c-server-${name}" = {
            description = "1C:Enterprise Server 8.3 (${v}, инстанс ${name})";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            path = servicePath;

            environment = optionalAttrs (full.settings.keytabFile != null) {
              SRV1CV8_KEYTAB = toString full.settings.keytabFile;
            };

            serviceConfig = commonServiceConfig // {
              ExecStartPre = prepareDataDir "server-${name}" full.settings.data;
              ExecStart = concatStringsSep " " (
                [
                  "${pkg}/bin/ragent"
                  "-d"
                  full.settings.data
                  "-port"
                  (toString full.settings.port)
                  "-regport"
                  (toString full.settings.regPort)
                  "-range"
                  full.settings.portRange
                  "-seclev"
                  (toString full.settings.securityLevel)
                  "-pingPeriod"
                  (toString full.settings.pingPeriod)
                  "-pingTimeout"
                  (toString full.settings.pingTimeout)
                ]
                ++ optional (full.settings.debug != "") full.settings.debug
                ++ full.settings.extraArgs
              );
            };
          };
        }
        // optionalAttrs standalone.enable {
          "1c-standalone-server-${name}" = {
            description = "1C:Enterprise Standalone Server 8.3 (${v}, инстанс ${name})";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            path = servicePath;

            serviceConfig = commonServiceConfig // {
              ExecStartPre = prepareDataDir "standalone-${name}" standalone.settings.data;
              ExecStart = concatStringsSep " " (
                [
                  "${pkg}/bin/ibsrv"
                  (if standalone.settings.http.enable then "--enable-http-gate" else "--disable-http-gate")
                  "--http-port=${toString standalone.settings.http.port}"
                  "--data=${standalone.settings.data}"
                  "--direct-regport=${toString standalone.settings.direct-regport}"
                  "--direct-range=${standalone.settings.direct-range}"
                  "--debug-port=${toString standalone.settings.debug-port}"
                ]
                ++ optional (standalone.settings.name != "") "--name=${standalone.settings.name}"
                ++ standalone.settings.extraArgs
              );
            };
          };
        }
        // optionalAttrs ras.enable {
          "1c-ras-${name}" = {
            description = "1C:Enterprise Remote Administration Server 8.3 (${v}, инстанс ${name})";
            after = [
              "network.target"
              "1c-server-${name}.service"
            ];
            wantedBy = [ "multi-user.target" ];
            path = servicePath;

            serviceConfig = commonServiceConfig // {
              ExecStart = concatStringsSep " " (
                [
                  "${pkg}/bin/ras"
                  "cluster"
                  "--port=${toString ras.port}"
                ]
                ++ optional (ras.clusterAddress != "") ras.clusterAddress
              );
            };
          };
        }
      ) enabledInstances;

      networking.firewall.allowedTCPPorts = concatLists (
        mapAttrsToList (
          _: i:
          let
            full = i.services.full-server;
            standalone = i.services.standalone-server;
            ras = i.services.ras;
          in
          optionals (full.enable && full.openFirewall) [
            full.settings.port
            full.settings.regPort
          ]
          ++ optionals (standalone.enable && standalone.openFirewall) (
            [
              standalone.settings.direct-regport
              standalone.settings.debug-port
            ]
            # http-порт открывается только если сам HTTP-шлюз включён.
            ++ optional standalone.settings.http.enable standalone.settings.http.port
          )
          ++ optional (ras.enable && ras.openFirewall) ras.port
        ) enabledInstances
      );

      networking.firewall.allowedTCPPortRanges = concatLists (
        mapAttrsToList (
          _: i:
          let
            full = i.services.full-server;
            standalone = i.services.standalone-server;
          in
          optional (full.enable && full.openFirewall) (parseRange full.settings.portRange)
          ++ optional (standalone.enable && standalone.openFirewall) (
            parseRange standalone.settings.direct-range
          )
        ) enabledInstances
      );
    })
  ]);
}
