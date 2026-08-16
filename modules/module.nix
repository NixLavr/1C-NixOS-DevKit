{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.onec;

  mkOnec = pkgs.callPackage ../pkgs/package.nix { };

  # Версия выводится из имени файла дистрибутива, скачанного с портала 1С
  # (server64_8_3_27_2130.zip — версия кодируется через "_" вместо "."),
  # чтобы не заставлять вписывать её руками. Если имя нестандартное —
  # версию нужно задать явно.
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

  # "ru" (как и любой другой нелатинский язык интерфейса) — это отдельный
  # УСТАНАВЛИВАЕМЫЙ компонент инсталлятора (--enable-components), а не
  # встроенный по умолчанию функционал: штатный набор по умолчанию у
  # самого инсталлятора — "client_full,langs,en,ru,advanced" ("langs" в
  # этой строке — служебное слово самого --help, а не реальный компонент:
  # в списке "Allowed" его нет, --enable-components его не принимает).
  # Если явно не запросить компонент с кодом cfg.language, в собранный
  # пакет физически не попадают файлы с переводом интерфейса — и тогда ни
  # LANG, ни conf.cfg, ни /L не помогают, потому что переводить нечем.
  # "en" в списке допустимых компонентов не встречается — он всегда в
  # комплекте и отдельно не запрашивается.
  languageComponents = optional (cfg.language != "en") cfg.language;

  clientPackage = mkOnec {
    inherit (cfg) archiveFile language;
    version = resolveVersion "client" cfg.archiveFile cfg.version;
    components = unique (cfg.client.components ++ languageComponents);
    pname = "1c-enterprise-client";
  };

  # ---------------------------------------------------------------------
  # Инстансы сервера
  # ---------------------------------------------------------------------

  enabledInstances = filterAttrs (_: i: i.enable) cfg.server.instances;

  # Каждый инстанс может жить на своём дистрибутиве: archiveFile/version
  # по умолчанию берутся общие, но их можно переопределить — так на одной
  # машине поднимаются сервера разных версий (у каждого свой архив).
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

  # Каталог данных надо создать и передать пользователю сервиса до старта.
  # "+" перед ExecStartPre — эта команда выполняется от root, в отличие от
  # самого ExecStart (штатный PermissionsStartOnly для этого объявлен
  # устаревшим и в новых systemd уже не действует).
  prepareDataDir =
    unit: dir:
    "+"
    + toString (
      pkgs.writeShellScript "1c-prepare-${unit}" ''
        mkdir -p ${escapeShellArg dir}
        chown -R ${escapeShellArg cfg.server.user}:${escapeShellArg cfg.server.group} ${escapeShellArg dir}
      ''
    );

  # core83.so собирает и запускает через /bin/sh команду вида
  #   /sbin/ldconfig -p | awk '/^[\t ]*<библиотека>/ ...'
  # — так 1С ищет опциональные клиентские библиотеки СУБД (libpq,
  # libodbc, libmysqlclient). В PATH сервиса systemd на NixOS есть
  # coreutils/findutils/grep/sed, но НЕ gawk, поэтому в журнал каждые
  # полминуты сыпалось "awk: command not found". Даём awk.
  #
  # Вторую половину этой команды починить нельзя и не нужно:
  # /sbin/ldconfig вызывается по абсолютному пути (PATH не участвует), а
  # на NixOS нет /etc/ld.so.cache — даже штатный ldconfig из nixpkgs на
  # `-p` отвечает "Can't open cache file". Библиотеки здесь ищутся через
  # RUNPATH, так что сам способ поиска бессмысленен: probe в любом случае
  # вернёт пустой список. На работу это не влияет (внешние СУБД
  # подключаются через LD_LIBRARY_PATH сервиса), в журнале остаётся одна
  # строка про отсутствующий /sbin/ldconfig.
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

  # ibcmd/ibsrv кладутся в PATH с суффиксом версии (ibcmd-8.3.27.2130),
  # как это сделано в nix-1c-server: одноимённые бинарники разных версий
  # иначе перекрыли бы друг друга. Ключ атрибута — имя команды, поэтому
  # два инстанса одной версии не создают конфликтующих пакетов.
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
          optional i.programs.ibcmd.enable (mk "ibcmd")
          ++ optional i.programs.ibsrv.enable (mk "ibsrv")
        ) enabledInstances
      );
    in
    attrValues (listToAttrs entries);

  instanceType = types.submodule {
    options = {
      enable = mkEnableOption "этот инстанс сервера 1С";

      archiveFile = mkOption {
        type = types.nullOr types.str;
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
          (стандартный формат server64_8_3_27_2130.zip).
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

    (mkIf (enabledInstances != { }) {
      users.groups.${cfg.server.group} = { };
      users.users.${cfg.server.user} = {
        isSystemUser = true;
        group = cfg.server.group;
        home = cfg.server.home;
        createHome = true;
        # Без двоеточия: NixOS требует, чтобы GECOS-поле не содержало ни
        # переносов строк, ни ":" — это разделитель полей в /etc/passwd.
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
                  (
                    if standalone.settings.http.enable then "--enable-http-gate" else "--disable-http-gate"
                  )
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
            # (В nix-1c-server здесь стоял lib.mkIf прямо внутри списка —
            # так он не работает: mkIf возвращает атрибут-обёртку, а не
            # элемент списка, и в allowedTCPPorts попадал мусор вместо
            # номера порта.)
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
          ++ optional (
            standalone.enable && standalone.openFirewall
          ) (parseRange standalone.settings.direct-range)
        ) enabledInstances
      );
    })
  ]);
}
