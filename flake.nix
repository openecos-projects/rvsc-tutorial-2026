{
  description = "RVSC 2026 tutorial workspace — dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    ecos-studio.url = "github:openecos-projects/ecos-studio";
    ecos-studio.inputs.ecc.follows = "ecc";
    ecc.url = "git+https://github.com/openecos-projects/ecc.git?submodules=1";
    ecc-sizer.url = "git+https://github.com/openecos-projects/ecc-sizer.git?submodules=1";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.treefmt-nix.flakeModule ];
      # Ecc is only supported on Linux, so we only build for Linux.
      systems = [ "x86_64-linux" ];

      perSystem =
        {
          pkgs,
          inputs',
          self',
          config,
          ...
        }:
        let
          # Use latest yosys from nixpkgs-unstable, and wrap it to set the environment variables for ecc.
          eccLatestYosys = inputs'.ecc.packages.default.overrideAttrs (_: {
            postFixup = ''
              for bin in ecc ecc-agent-rpc; do
                wrapProgram "$out/bin/$bin" \
                  --set CHIPCOMPILER_OSS_CAD_DIR "${pkgs.yosys}" \
                  --set CHIPCOMPILER_KEPLER_FORMAL_ROOT "${inputs'.ecc.packages.keplerFormal}" \
                  --prefix PATH : "${pkgs.yosys}/bin"
              done
            '';
          });
        in
        {
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              nodejs_22
              pnpm
              yosys
              inputs'.ecos-studio.packages.default
              eccLatestYosys
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

          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            programs.prettier.enable = true;
            programs.prettier.excludes = [
              "flake.lock"
              "**/pnpm-lock.yaml"
              "**/dist/**"
              "**/components.d.ts"
              # prettier will insert a blank line between Slidev page separator ---
              # and frontmatter, which breaks the parsing
              "slides/slides.md"
            ];
            programs.autocorrect.enable = true;
            programs.autocorrect.includes = [ "*.md" ];
          };

          # For buildbot ci
          checks = {
            devShell = self'.devShells.default;
            formatting = config.treefmt.build.check inputs.self;
            ecos-studio = inputs'.ecos-studio.packages.default;
            ecc = eccLatestYosys;
            ecc-sizer = inputs'.ecc-sizer.packages.default;
          };
        };
    };
}
