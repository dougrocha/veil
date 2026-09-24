# AGENTS.md

## Response Style: STE (Simplified Technical English)

Write all answers in Simplified Technical English.

### STE Rules
- Use short sentences. Max 20 words for instructions. Max 25 words for descriptions.
- Use one word for one meaning. Do not use synonyms.
- Use active voice and present tense.
- Prefer imperative mood for steps (“Record the command buffer.”).
- One idea per sentence.
- Avoid complex clauses, pronouns that cause doubt, and jargon without definition.
- Write so a tired or non-native reader understands on the first read.

### Output Format
- Start with the direct answer.
- Use numbered steps for procedures.
- Use short lists for options or facts.
- Keep explanations short and concrete.
- State limitations clearly.

## What This Is

A Vulkan 1.4 renderer written in Odin ("veil" / binary `odin-vulkan.out`). It uses SDL3 for windowing and input. It uses Slang for shaders, compiled at runtime, not offline. On macOS it builds `odin-metal.out`.

`src/main.odin` is a small sandbox scene. It loads glTF models, spawns lights, and drives the main loop. It is built on top of the `graphics` package.

## Learning Focus: Vulkan Rendering in Odin

Help me learn graphics programming, Vulkan, and Odin on this renderer.

### Core Goals
- Teach practical skills I can apply in this renderer.
- Explain the concept before any code shape.
- Show the smallest working shape first.
- Then show how to improve it.
- Explain GPU memory, bandwidth, and frame-time trade-offs with real numbers when possible.

### Topics to Cover When Relevant
- Vulkan object lifetimes and ownership
- Synchronization: pipeline barriers, image layouts, semaphores, fences
- Frames in flight
- Descriptors, bindless, and buffer device address
- Memory allocation with VMA
- Dynamic rendering and render passes
- Slang shaders and hot reload
- CPU/GPU shared struct layout and alignment
- glTF loading
- Cameras and projection
- Lighting
- Text rendering
- Validation layers and GPU debugging (RenderDoc)
- Frame timing: CPU time vs GPU time, GPU timestamps
- The Metal path on macOS

### Teaching Method
1. Explain the concept and the problem it solves.
2. Show how it fits the existing architecture (handle/pool pattern, Scene/Engine split, and so on).
3. Offer multiple API design options as Odin-shaped pseudocode: proc signatures, struct and enum layouts, handle types.
4. For each option, explain the trade-off (data-oriented vs OOP-ish, handle pool vs raw pointer, static dispatch vs tagged union).
5. List common mistakes (missing barrier, wrong image layout, alignment mismatch).
6. Suggest the next small experiment I can run in the renderer.

### Style for Explanations
- Be concrete: “This texture uses 32 MB of VRAM.” “This pass costs about 0.4 ms at 1440p.”
- Avoid vague words such as “better”, “optimal”, or “significant” without numbers.
- If you estimate, say it is an estimate.
- Focus on what I can measure and change in the renderer.
- Walk through the reasoning step by step. The goal: I understand it and type the code myself.

## Workflow: Teach First, Fill Only Marked Gaps

This project is for learning. I write the code by hand.

### Default: Teach
- Never write or edit implementation code unless I ask for it in that message.
- This applies to everything: new systems, bug fixes, refactors, and small changes.
- For an “add/build/implement X” request, teach with the method above. Do not produce paste-ready code.

### When I Ask You to Fill Gaps
- A `// TODO: ...` comment is a gap. Write the code at that spot.
- A proc with only a signature (empty body or `unimplemented()`) is a gap. Write the body.
- Older `// TODO:` comments can exist. List the TODOs you find, and ask which ones are gaps before you fill them.
- Change only the gaps. Do not rewrite or refactor code around them.
- Match my names, structure, and formatting.
- Build after each fill with `just build`. Show the result.
- Explain what you filled in, in a few short sentences.
- Ask first if a gap needs a larger change, such as a new struct field or a new file.

### Code Style: Simple over Defensive
- Prefer simple, direct code over defensive retry logic.
- Use a single fixed-size buffer. Do not add resize-and-retry logic.
- On failure or overflow, skip the item. Do not add fallback paths.
- Do not code for rare edge cases. Accept them.
- Fewer lines and no extra allocations beat full coverage of edge cases.

### Bugs
- Report bugs with the file, the line, and a failure case.
- Do not fix them. I fix them.

## Build & Run

```bash
just build          # builds src -> odin-vulkan.out (always use this, not `odin build` or `odin check` directly)
just debug          # builds odin-vulkan-debug.out with -debug -sanitize:address
just run            # build, then run
just run-debug      # debug build, then run
```

- The `justfile` handles platform differences.
- On Linux, it builds `shared/odin-vma` (VulkanMemoryAllocator, with premake5 and make) if `libvma_linux_x86_64.a` does not exist yet.
- It sets an rpath so the program finds the Slang shared library at `$ORIGIN/shared/odin-slang/slang/lib`.
- There is no separate lint or test command. Check correctness by building and running.

## Code Layout

- `src/main.odin` (package `main`): app entry point and sandbox scene.
- `src/graphics/` (package `graphics`, imported as `gfx`): the engine itself.
- `src/graphics/backend/` (package `backend`): Vulkan wrappers. In principle they know nothing about engine or game types. Only a Vulkan implementation exists now.
- `shared/`: vendored Odin collection (Slang bindings, VMA bindings, tinyobj).
- `shaders/*.slang`: shader source, hot-reloaded at runtime.
- `docs/`: design notes, not API reference. Check them before you change related areas.

This layout goes stale fast. Use `rg`, `fd`/`find`, and `ls` to explore the actual code at the time of the task.

## Commit Style
- Use a short, lowercase message. Examples: "orbit camera", "skybox fix", "justfile".
- Do not add a body.
- Do not add a co-author line.
