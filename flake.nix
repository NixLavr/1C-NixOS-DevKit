{
  description = "1С:Предприятие 8.3 — генератор Nix-пакетов (сервер/клиент) и модуль NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      # Пакета "по умолчанию" нет: сборка требует локального архива
      # дистрибутива под лицензией пользователя, поэтому экспортируется
      # генератор — см. README.md.
      lib.${system} = {
        mkOnec = pkgs.callPackage ./pkgs/package.nix { };
        mkOnecEdt = pkgs.callPackage ./pkgs/onec-edt.nix { };
        mkPostgresql1c = pkgs.callPackage ./pkgs/postgresql-1c { };
      };

      packages.${system} = {
        postgresql_1c = self.lib.${system}.mkPostgresql1c {
          archiveFile = "/home/lavr/nixos-config-main/flakes/postgresql_18.1_2_ubuntu_24.04_x86_64_package.tar.bz2";
        };
        # Дистрибутив не скачивается и не перевыкладывается: архив кладётся
        # в стор вручную (nix store add-file), requireFile лишь ссылается на
        # него по имени и хешу — так сборка остаётся чистой, без путей из
        # домашнего каталога.
        onec-edt = self.lib.${system}.mkOnecEdt {
          archiveFile = pkgs.requireFile {
            name = "1c_edt_distr_offline_2026.1.2_2_linux_x86_64.tar.gz";
            sha256 = "892ea80e7b9019a7a333804cbdcbc84a1a49df47de88d13469639bed4773ec53";
            message = ''
              Скачайте offline-дистрибутив 1C:EDT с releases.1c.ru и добавьте в стор:
                nix store add-file --name 1c_edt_distr_offline_2026.1.2_2_linux_x86_64.tar.gz /путь/к/архиву
            '';
          };
        };
        onec-connect = pkgs.callPackage ./pkgs/onec-connect.nix { };
      };

      nixosModules.default = import ./modules/module.nix;
      nixosModules.onec = self.nixosModules.default;
      nixosModules.postgresql_1c = import ./modules/postgresql-1c.nix;
    };
}
