{
  description = "1С:Предприятие 8.3 — генератор Nix-пакетов (сервер/клиент) и модуль NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
    in
    {
      # Пакета "по умолчанию" нет: сборка требует локального архива
      # дистрибутива (.zip), скачанного пользователем под свою лицензию,
      # и его нельзя зашить в публичный flake-output. Вместо этого
      # экспортируется генератор — см. README.md, там же примеры
      # использования.
      lib.${system}.mkOnec = pkgs.callPackage ./pkgs/package.nix { };

      nixosModules.default = import ./modules/module.nix;
      nixosModules.onec = self.nixosModules.default;
    };
}
