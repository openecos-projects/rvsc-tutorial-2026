{
  description = "RVSC 2026 tutorial workspace — dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nodejs_22
            pnpm
          ];

          shellHook = ''
            echo "🛝  Dev shell ready (node + pnpm)"
            echo "    cd slides"
            echo "    pnpm install   # 安装依赖"
            echo "    pnpm dev       # 启动 Slidev 预览"
            echo "    pnpm build     # 构建静态站点"
          '';
        };
      });
}
