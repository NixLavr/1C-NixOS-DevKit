# 1С:Предприятие 8.3 — пакет для Nix/NixOS

Генератор Nix-пакетов и модуль NixOS для официального дистрибутива
1С:Предприятие 8.3 (сервер и клиент), а также сопутствующих компонентов:
PostgreSQL для 1С и клиент 1C-Connect.

## Использование пакета напрямую

```nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  mkOnec = pkgs.callPackage ./package.nix { };
in
mkOnec {
  archiveFile = "/home/user/Downloads/server64_8_3_XX_XXXX/server64_8_3_XX_XXXX.zip"; # строка!
  components = [ "server" "server_admin" "ws" "ru" ];   # или [ "client_thin" "ru" ], [ "client_full" "ru" ]...
  language = "ru";
  version = "8.3.XX.XXXX";
  pname = "1c-enterprise-server";
}
```

`archiveFile` — путь к скачанному с портала 1С zip-архиву дистрибутива,
указывается строкой (не path-литералом). Язык интерфейса (`"ru"` и т.п.)
нужно включить в список `components` — без него в сборку не попадут файлы
перевода. `module.nix` (см. ниже) делает это автоматически из
`services.onec.language`.

## Подключение флейка

```nix
{
  inputs.onec-devkit.url = "github:NixLavr/1C-NixOS-DevKit";

  outputs = { self, nixpkgs, onec-devkit, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        onec-devkit.nixosModules.default   # или .onec — тот же модуль
        { nixpkgs.config.allowUnfree = true; }
        {
          services.onec = {
            enable = true;
            archiveFile = "/home/user/Downloads/server64_8_3_XX_XXXX.zip";
            # ...
          };
        }
      ];
    };
  };
}
```

Для PostgreSQL 1С аналогично: `onec-devkit.nixosModules.postgresql_1c`,
генератор пакета — `onec-devkit.lib.${system}.mkPostgresql1c`, подробности —
[PostgreSQL 1С](#postgresql-1с). Пакет 1C-Connect (без модуля, просто
бинарник) — `onec-devkit.packages.${system}.onec-connect`, см.
[1C-Connect](#1c-connect). Без флейков модуль можно импортировать и
напрямую по пути (`imports = [ ./modules/module.nix ];`), если репозиторий
склонирован локально.

## NixOS-модуль

```nix
{
  imports = [ onec-devkit.nixosModules.default ];

  services.onec = {
    enable = true;
    archiveFile = "/home/user/Downloads/server64_8_3_XX_XXXX/server64_8_3_XX_XXXX.zip";
    language = "ru";

    client = {
      enable = true;                        # добавить клиент в PATH всем пользователям
      components = [ "client_thin" ];       # или [ "client_full" ]
    };

    server.instances."main" = {
      enable = true;

      programs.ibcmd.enable = true;         # ibcmd-8.3.XX.XXXX в PATH

      services.full-server = {              # кластер: ragent/rmngr/rphost
        enable = true;
        openFirewall = true;
      };

      services.ras.enable = true;           # rac/ras — консоль администрирования кластера

      services.standalone-server = {        # автономный сервер (ibsrv)
        enable = true;
        openFirewall = true;
        settings.name = "main";
      };
    };
  };
}
```

`services.onec.version` можно не указывать — выводится из имени файла в
`archiveFile`. `services.onec.client.enable` просто кладёт клиентский пакет
в `environment.systemPackages`, это не сервис.

### Инстансы сервера

Серверная часть построена вокруг `services.onec.server.instances` — набора
именованных инстансов. Ключ атрибута попадает в имена юнитов:

| Что включено | Юнит |
| --- | --- |
| `services.full-server` | `1c-server-<метка>.service` |
| `services.standalone-server` | `1c-standalone-server-<метка>.service` |
| `services.ras` | `1c-ras-<метка>.service` |

Все три независимы. Модуль заводит системного пользователя
`usr1cv8`/`grp1cv8` (настраивается через `services.onec.server.user` /
`.group` / `.home`) и готовит каталоги данных перед стартом сервиса.

Инстансы могут быть разных версий — у каждого свои `archiveFile` и
`version`, по умолчанию берутся общие:

```nix
services.onec.server.instances = {
  main = {
    enable = true;
    services.standalone-server.enable = true;
    services.standalone-server.settings.name = "main";
  };
  testing = {
    enable = true;
    archiveFile = "/home/user/Downloads/server64_8_3_YY_YYYY.zip"; # другая версия
    services.standalone-server = {
      enable = true;
      settings = {
        name = "test";
        http.port = 8315;
        direct-regport = 1542;
        direct-range = "1610:1641";
        debug-port = 1555;
        data = "/var/lib/1cv8-testing";
        extraArgs = [ "--disable-extended-designer-features" ];
      };
    };
  };
};
```

Полный набор настроек — в `modules/module.nix`.

## PostgreSQL 1С

`pkgs/postgresql-1c` — пакет PostgreSQL, собранный из фирменного архива 1С
для Ubuntu.

### Использование пакета напрямую

```nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  mkPostgresql1c = pkgs.callPackage ./pkgs/postgresql-1c { };
in
mkPostgresql1c {
  archiveFile = "/home/user/Downloads/postgresql_18.1-2.1C_ubuntu_x86_64_package.tar.bz2";
  version = "18.1-2.1C"; # необязательно, это значение по умолчанию
}
```

### NixOS-модуль

```nix
{
  imports = [ onec-devkit.nixosModules.postgresql_1c ];

  services.postgresql_1c = {
    enable = true;
    archiveFile = "/home/user/Downloads/postgresql_18.1-2.1C_ubuntu_x86_64_package.tar.bz2";
    ensureDatabases = [ "mydb" ];
    ensureUsers = [
      {
        name = "usr1cv8";
        ensureDBOwnership = true;
      }
    ];
  };
}
```

`services.postgresql_1c.enable` включает штатный `services.postgresql` с
пакетом, собранным из `archiveFile`. Опции вроде `dataDir`, `settings`,
`ensureDatabases`, `ensureUsers`, `authentication`, `extensions` — это
алиасы на одноимённые опции `services.postgresql.*`, работают так же, как
в штатном модуле nixpkgs. `addToSystemPackages` (по умолчанию `true`)
кладёт клиентские утилиты (`psql`, `pg_dump` и т.п.) в
`environment.systemPackages`.

## 1C-Connect

`pkgs/onec-connect.nix` — пакет для официального Linux-клиента
[1C-Connect](https://1c-connect.com/), сервиса удалённого доступа/
техподдержки от 1С. С самим 1С:Предприятием он никак не связан — общее
только происхождение от фирмы 1С, но экспортируется из этого же flake как
отдельный пакет: `packages.${system}.onec-connect`.

NixOS-модуля у него нет — подключается через `environment.systemPackages`
из flake-input (см. [Подключение флейка](#подключение-флейка)):

```nix
{
  environment.systemPackages = [ onec-devkit.packages.${system}.onec-connect ];
}
```

`nixpkgs.config.allowUnfree = true` обязателен — лицензия
`unfreeRedistributable`.

## Важно про лицензию

Дистрибутив 1С:Предприятие — проприетарное ПО. Пакет не переопубликовывает
и не скачивает его: он берёт уже скачанный вами (под вашей лицензией) архив
и превращает в воспроизводимую Nix-сборку. Публиковать архив дистрибутива
или собранный из него пакет в открытом доступе нельзя.
