package graphics

import "core:fmt"

// Lights live in fixed arrays on Scene, so they are addressed by index.
PointLightIndex :: distinct u32
SpotLightIndex :: distinct u32
DirectionalLightIndex :: distinct u32

// nil means nothing is selected.
Selection :: union {
	InstanceHandle,
	PointLightIndex,
	SpotLightIndex,
	DirectionalLightIndex,
}

// The selected instance, or INVALID_INSTANCE when nothing or a light is selected.
selected_instance :: proc(scene: ^Scene) -> InstanceHandle {
	handle, ok := scene.selection.(InstanceHandle)
	return handle if ok else INVALID_INSTANCE
}

// A texture tied to an entity, ready to pass to debug_view_draw.
EntityTexture :: struct {
	label: string,
	view:  DebugViewPushConstants,
}

// Lists the textures tied to an entity: material textures for an instance (once per distinct
// material), shadow-map views for a light. Labels are allocated with `allocator`.
entity_textures :: proc(
	engine: ^Engine,
	selection: Selection,
	allocator := context.temp_allocator,
) -> []EntityTexture {
	out := make([dynamic]EntityTexture, allocator)
	scene := &engine.scene

	switch s in selection {
	case InstanceHandle:
		if s == INVALID_INSTANCE do break
		model := pool_get(&engine.model_system.models, instance_get(engine, s).model)
		seen := make(map[MaterialHandle]struct{}, allocator = context.temp_allocator)
		for mesh in model.meshes {
			if mesh.material in seen do continue
			seen[mesh.material] = {}

			material := pool_get(&engine.material_system.materials, mesh.material)
			name := material.name if material.name != "" else fmt.tprintf("material %d", mesh.material.index)
			slots := [4]struct {
				label:   string,
				texture: TextureHandle,
			} {
				{"base_color", material.base_color_texture},
				{"normal", material.normal_map_texture},
				{"metallic_roughness", material.metallic_roughness_texture},
				{"occlusion", material.occlusion_texture},
			}
			for slot in slots {
				if slot.texture == INVALID_TEXTURE do continue
				append(
					&out,
					EntityTexture {
						label = fmt.aprintf("%s %s", name, slot.label, allocator = allocator),
						view = {mode = .Texture_2D, index = u32(slot.texture.index)},
					},
				)
			}
		}
	case PointLightIndex:
		if u32(s) >= scene.point_light_count do break
		for face in 0 ..< u32(6) {
			append(
				&out,
				EntityTexture {
					label = fmt.aprintf("point %d shadow face %d", s, face, allocator = allocator),
					view = {mode = .Shadow_Cube_Face, index = u32(s), face = face},
				},
			)
		}
	case SpotLightIndex:
		if u32(s) >= scene.spot_light_count do break
		append(
			&out,
			EntityTexture {
				label = fmt.aprintf("spot %d shadow", s, allocator = allocator),
				view = {mode = .Shadow_2D, index = SPOT_SHADOW_SLOT_BASE + u32(s)},
			},
		)
	case DirectionalLightIndex:
		if u32(s) >= scene.directional_light_count do break
		for cascade in 0 ..< u32(SHADOW_MAP_CASCADE_COUNT) {
			append(
				&out,
				EntityTexture {
					label = fmt.aprintf("directional %d cascade %d", s, cascade, allocator = allocator),
					view = {mode = .Shadow_2D, index = u32(s) * SHADOW_MAP_CASCADE_COUNT + cascade},
				},
			)
		}
	}
	return out[:]
}
