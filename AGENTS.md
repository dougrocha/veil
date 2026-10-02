# AGENTS.md

Vulkan 1.4 renderer in Odin with SDL3 and Slang. macOS runs through MoltenVK.

## Build

- Always build through `just`. Do not call `odin build` or `odin check` directly. The justfile sets `-collection:shared=shared` and the Slang rpath.
  - `just build` builds `odin-vulkan.out`.
  - `just debug` builds with `-debug -sanitize:address`.
  - `just run` and `just run-debug` build, then run.
  - `just build-release` builds `odin-vulkan-release.out` with `-o:speed` and validation layers off (`-define:VEIL_VALIDATION=false`). `just release` builds it, then runs.
- There are no tests and no linter. Check your work by building, and by running when behavior changes.
- On first build, Linux compiles VMA in `shared/odin-vma`. This needs `premake5` and `make`.

## GPU types are generated

- `src/graphics/gpu_types.odin` is the source of truth for structs and constants that the CPU and GPU share.
- `shaders/types.slang` is generated from it. Do not edit it by hand.
- After you change `gpu_types.odin`, run `./tools/generate-gpu-types.sh` (`just build` also runs it). Use `--check` to verify that the generated file is current.

## Architecture notes

- `src/graphics/backend/` holds the GPU API wrappers. It must not know about engine or scene types.
  - Its API uses backend-neutral types (`ImageUsage`, `CompareOp`, `ImageStateKind`, `RenderEncoder`, ...) defined in `types.odin`, mapped to Vulkan inside the backend.
- Bindless textures are a `Texture2D[]` plus a fixed `SamplerState[]` (`shaders/bindless.slang`). Shaders sample through `gpu_texture`/`gpu_sampler` with the `SAMPLER_*` constants.
- Slang shaders in `shaders/` compile at runtime, not offline. `src/watcher` hot-reloads them. Any `*.spv` files are only debug output.
- `shared/` is a vendored Odin collection (Slang, VMA, tinyobj bindings). Do not edit it.
- `docs/` holds design notes. Read them before you change the related systems.

## Style

- After you edit `.odin` files, run `just format`. It runs `odinfmt` (`odinfmt.json`: 120-column width) and skips `shared/` and generated files.
- Commit messages are short and lowercase, with no body. Examples: "orbit camera", "skybox fix".
