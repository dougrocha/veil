# How to Map the Inverted Hull Outline to Vulkan 1.3 States

To make this trick work, you do not need a new shader file. You just need to create two separate `VkPipeline` objects that look at your exact same Slang/HLSL shader code but use different fixed-function hardware configurations.

## Pipeline 1: The Opaque Object (Normal Render)

This is your current standard setup.

| State | Value |
|---|---|
| Cull Mode | `VK_CULL_MODE_BACK_BIT` |
| Depth Test | `VK_COMPARE_OP_LESS` |
| Depth Write | `VK_TRUE` |

## Pipeline 2: The Outline Shell (The Trick Render)

This pipeline renders right after the first one, using the exact same mesh data but tells the GPU hardware to invert its face logic.

| State | Value |
|---|---|
| Cull Mode | `VK_CULL_MODE_FRONT_BIT` — drops front geometry, so you're looking exclusively at the inside back-walls of the model |
| Depth Test | `VK_COMPARE_OP_LESS_OR_EQUAL` — allows the shell to draw nicely right against the borders of your normal object |
| Depth Write | `VK_TRUE` — so your outline properly blocks things behind it |

---

## Adapting Your Shader Code

You can implement this smoothly into your current Slang code by adding a single configuration flag to your `PushConstants` struct.

### 1. Update the Push Constants

Add an `is_outline` boolean (represented as a `uint` for uniform padding) and an `outline_thickness` float.

```hlsl
struct PushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Material* material_buffer;
    Transform* transform_buffer;
    uint material_index;
    uint instance_index;

    // New fields for the outline pattern
    uint is_outline;          // 1 if drawing outline, 0 if normal
    float outline_thickness;  // Small value like 0.02
};
```

### 2. Update the Vertex Shader

If the outline flag is active, push the vertex position outwards along its normal vector before calculating perspective projection.

```hlsl
[shader("vertex")]
VSOutput vertex_main(VSInput input) {
    let v = pc.vertex_buffer[input.vertex_index];
    let transform = pc.transform_buffer[pc.instance_index];

    float3 position = v.pos;
    float3 normal = normalize(mul((float3x3)transform.normal_matrix, v.normal));

    // If drawing the outline pipeline, puff the vertices out along the normals
    if (pc.is_outline == 1) {
        position += v.normal * pc.outline_thickness;
    }

    VSOutput output;
    float4 worldPos = mul(transform.model, float4(position, 1.0));
    output.fragPos = worldPos.xyz;
    output.pos = mul(pc.scene_data.proj, mul(pc.scene_data.view, worldPos));
    output.fragNormal = normal;
    output.fragColor = v.color;
    output.fragUV = v.uv;

    return output;
}
```

### 3. Update the Fragment Shader

When rendering the outline pipeline, skip all lighting calculations and texture lookups — just return a flat outline color.

```hlsl
[shader("fragment")]
float4 fragment_main(VSOutput vertIn) : SV_TARGET {
    // If this is the outline pass, short-circuit everything and return a solid color
    if (pc.is_outline == 1) {
        return float4(0.0, 0.0, 0.0, 1.0); // Solid Black Outline
    }

    // Your original lighting/texturing code stays here for normal rendering
    let mat = pc.material_buffer[pc.material_index];
    float4 texColor = textures[mat.base_color_texture].Sample(vertIn.fragUV) * float4(vertIn.fragColor, 1.0) * mat.base_color;
    // ... lighting calculations loop ...
    return float4(result * texColor.rgb, texColor.a);
}
```

---

## The Vulkan Command Buffer Loop

Within your frame loop, drawing a stylized model becomes a simple two-step process per mesh:

```cpp
// Draw Step 1: The Object
vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, normalPipeline);
pc.is_outline = 0;
vkCmdPushConstants(cmd, pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(PushConstants), &pc);
vkCmdDrawIndexed(cmd, indexCount, 1, 0, 0, 0);

// Draw Step 2: The Outline Shell
vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, outlinePipeline);
pc.is_outline = 1;
pc.outline_thickness = 0.03f; // Tweak for thickness preference
vkCmdPushConstants(cmd, pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(PushConstants), &pc);
vkCmdDrawIndexed(cmd, indexCount, 1, 0, 0, 0);
```

This pattern lets you learn how pipeline states switch in Vulkan 1.3 without having to design multiple complex shader render passes.

---

## Follow-up Topics

- Exact `VkGraphicsPipelineCreateInfo` structural edits needed to build the `outlinePipeline` (front-face culling configs).
- How to fix perspective distortion artifacts if the outline gets too thick when the camera gets close.
