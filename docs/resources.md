# Resources

(DOOM Eternal - Graphics Study)[https://simoncoenen.com/blog/programming/graphics/DoomEternalStudy.html]

(Destiny's Multithreaded Rendering Architecture)[https://www.youtube.com/watch?v=0nTDFLMLX9k]

## Rendering stuff

### Sobel rendering stuff

With this we can do edge detection and drawing borders/stencils

This method comes with a performance penalty because it needs a post processing pass.

### Post Processing / Input Attachments

(Vulkan Input Attachments and Sub-passes)[https://www.saschawillems.de/blog/2018/07/19/vulkan-input-attachments-and-sub-passes/]

Render scene to offscreen attachment in subpass 1, read it in subpass 2 to apply effects. `subpassLoad()` is more efficient than texture sampling on tile-based GPUs. Relevant for any post processing (bloom, color grading, etc.) regardless of forward vs deferred rendering.
