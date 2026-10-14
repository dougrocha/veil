# veil

A Vulkan 1.4 renderer in Odin, with SDL3 and Slang. macOS runs through MoltenVK.

## Features

- Bindless textures and samplers
- Clustered light binning
- Cascaded shadow maps with PCF
- GPU frustum culling and indirect draws
- glTF and OBJ model loading
- Bloom and tonemapping
- Particles, lines, text and UI overlay
- Object picking, selection outlines and gizmos
- Slang shaders that compile at runtime and hot-reload on save

## Build

Requirements: [Odin](https://odin-lang.org), [just](https://github.com/casey/just), SDL3, a Vulkan 1.4 driver, `premake5` and `make`.

```sh
git clone --recurse-submodules https://github.com/dougrocha/veil
cd veil
just run
```

- `just build` writes `build/veil`.
- `just debug` builds with address sanitizer and runs it.
- `just release` builds with `-o:speed` and validation layers off.

On the first build, `just` compiles VMA in `shared/odin-vma` and downloads `libslang-glslang` into `shared/odin-slang/slang/lib`.

## Layout

- `src/graphics/backend/` - GPU API wrappers, with no engine or scene types
- `src/graphics/` - renderer: passes, lights, shadows, materials, meshes
- `shaders/` - Slang shaders
- `tools/gpu_types_gen/` - generates `shaders/types.slang` from `@(shader_shared)` Odin declarations
- `docs/` - design notes
- `shared/` - vendored Odin bindings (Slang, VMA, tinyobj)

## License

The code is under the [MIT License](LICENSE). Third-party code and assets keep their own licenses. See below.

## Third-party code

- [odin-slang](https://github.com/DragosPopse/odin-slang) - Slang bindings (git submodule)
- [odin-vma](shared/odin-vma) - Vulkan Memory Allocator bindings, MIT (see `shared/odin-vma/LICENSE`)

## Asset credits

| Asset | Source | License |
| --- | --- | --- |
| `assets/models/sponza-gltf-pbr/` | Crytek Sponza by Frank Meinl, Crytek (glTF PBR conversion: TODO) | CC BY 3.0 |
| `assets/models/viking_room.obj`, `assets/textures/viking_room.png` | "Viking room" by nigelgoh on Sketchfab, via [vulkan-tutorial.com](https://vulkan-tutorial.com) | CC BY 4.0 |
| `lion_head`, `namaqualand_boulder_02`, `rubber_duck_toy`, `wooden_gate` | [Poly Haven](https://polyhaven.com) | CC0 |
| `assets/starmap_2020_4k_print.jpg` | [NASA/Goddard Scientific Visualization Studio, Deep Star Maps 2020](https://svs.gsfc.nasa.gov/4851) | Public domain |
| `assets/textures/megumi.jpeg` | TODO | TODO |
| `assets/textures/StandardCubeMap.png` | TODO | TODO |
| `assets/textures/sky_07_cubemap.png` | TODO | TODO |
| `assets/textures/space_skybox.jpg` | TODO | TODO |
| `assets/textures/water_scene_cubemap.jpg` | TODO | TODO |
| `assets/textures/grass.png` | TODO | TODO |
| `assets/textures/texture.jpeg` | TODO | TODO |
| `assets/textures/wood_floor.png` | TODO | TODO |
