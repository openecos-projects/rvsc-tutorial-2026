{
  description = "RVSC 2026 tutorial workspace — dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    ecos-studio.url = "github:openecos-projects/ecos-studio";
    ecos-studio.inputs.ecc.follows = "ecc";
    ecc.url = "git+https://github.com/openecos-projects/ecc.git?submodules=1";
    ecc-sizer.url = "git+https://github.com/openecos-projects/ecc-sizer.git?submodules=1";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Ecc is only supported on Linux, so we only build for Linux.
      systems = [ "x86_64-linux" ];

      perSystem = { pkgs, inputs', self', ... }: {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nodejs_22
            pnpm
            yosys
            inputs'.ecos-studio.packages.default
            inputs'.ecc.packages.default
            inputs'.ecc-sizer.packages.default
          ];

          shellHook = ''
            echo "🛝  Dev shell ready (node + pnpm)"
            echo "    cd slides"
            echo "    pnpm install   # 安装依赖"
            echo "    pnpm dev       # 启动 Slidev 预览"
            echo "    pnpm build     # 构建静态站点"
          '';
        };

        # For buildbot ci
        checks = {
          devShell = self'.devShells.default;
          ecos-studio = inputs'.ecos-studio.packages.default;
          ecc = inputs'.ecc.packages.default;
          ecc-sizer = inputs'.ecc-sizer.packages.default;
        };
      };
    };
}
