# AGENTS.md

Vulkan 1.4 renderer in Odin with SDL3 and Slang. On macOS a Metal backend builds instead.

## Build

- Always build through `just`. Do not call `odin build` or `odin check` directly. The justfile sets `-collection:shared=shared` and the Slang rpath.
  - `just build` builds `odin-vulkan.out` (`odin-metal.out` on macOS).
  - `just debug` builds with `-debug -sanitize:address`.
  - `just run` and `just run-debug` build, then run.
- There are no tests and no linter. Check your work by building, and by running when behavior changes.
- On first build, Linux compiles VMA in `shared/odin-vma`. This needs `premake5` and `make`.

## GPU types are generated

- `src/graphics/gpu_types.odin` is the source of truth for structs and constants that the CPU and GPU share.
- `shaders/types.slang` and `src/graphics/layout_asserts_generated.odin` are generated from it. Do not edit them by hand.
- After you change `gpu_types.odin`, run `./tools/generate-gpu-types.sh` (`just build` also runs it). Use `--check` to verify that the generated files are current.
- The layout asserts check that Slang's Vulkan scalar layout and Metal layout agree.

## Architecture notes

- `src/graphics/backend/` holds the GPU API wrappers. It must not know about engine or scene types.
  - Files come in `*_vulkan.odin` / `*_metal.odin` pairs, selected by `#+build` tags. The shared API is in `types.odin`.
  - When you change a backend proc, update both implementations.
- Slang shaders in `shaders/` compile at runtime, not offline. `src/watcher` hot-reloads them. Any `*.spv` files are only debug output.
- `shared/` is a vendored Odin collection (Slang, VMA, tinyobj bindings). Do not edit it.
- `docs/` holds design notes. Read them before you change the related systems.

## Style

- After you edit `.odin` files, run `just format`. It runs `odinfmt` (`odinfmt.json`: 120-column width) and skips `shared/` and generated files.
- Commit messages are short and lowercase, with no body. Examples: "orbit camera", "skybox fix".
