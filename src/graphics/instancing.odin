package graphics

import "backend"

// FrameLayout packs the draw/material ids for each mesh run via instance_id_pack. Shaders read
// ids[SV_InstanceID + SV_StartInstanceLocation] because Slang drops the Vulkan base instance
// from SV_InstanceID. Bits 0-13 hold the material index; bits 14-28 hold the draw id.

@(shader_shared)
INSTANCE_MATERIAL_BITS :: 14
@(shader_shared)
INSTANCE_MATERIAL_MASK :: (1 << INSTANCE_MATERIAL_BITS) - 1
@(shader_shared)
INSTANCE_DRAW_ID_SHIFT :: INSTANCE_MATERIAL_BITS
@(shader_shared)
INSTANCE_DRAW_ID_BITS :: 15

// The id a shader reads per instance: draw id in the high bits, material index in the low ones.
instance_id_pack :: #force_inline proc(draw_id: u32, material: MaterialHandle) -> u32 {
	return (draw_id << u32(INSTANCE_DRAW_ID_SHIFT)) | u32(material.index)
}

@(shader_shared)
DrawIndexedIndirectCommand :: struct #max_field_align(16) {
	index_count:    u32,
	instance_count: u32,
	first_index:    u32,
	vertex_offset:  i32,
	first_instance: u32,
}

#assert(size_of(DrawIndexedIndirectCommand) == 20)

#assert(MAX_DRAWS <= 1 << INSTANCE_DRAW_ID_BITS)
#assert(MAX_MATERIALS <= 1 << INSTANCE_MATERIAL_BITS)

// Every pass in a frame appends to the same list: main, transparent and every shadow view.
// Enough for one mesh per instance in the camera and every possible shadow view.
MAX_INSTANCE_IDS :: MAX_DRAWS * (1 + MAX_SHADOW_2D_SLOTS + MAX_POINT_SHADOW_LIGHTS * 6)
// 64k commands covers several views of the maximum 32k draws while keeping each slot near 1.25 MiB.
MAX_INDIRECT_COMMANDS_PER_FRAME :: 64 * 1024
// GPU culling compacts each batch serially in one invocation, so a batch caps that scan's length.
GPU_CULL_BATCH_CANDIDATES :: 1024

@(shader_shared)
GpuCullCandidate :: struct #max_field_align(16) {
	packed_id: u32,
	run_index: u32,
}

@(shader_shared)
GpuCullRun :: struct #max_field_align(16) {
	first_candidate: u32,
	candidate_count: u32,
	first_index:     u32,
	vertex_offset:   i32,
	index_count:     u32,
	instance_count:  u32,
	first_instance:  u32,
	_reserved:       u32,
	bounds_center:   Vec4,
	bounds_extents:  Vec4,
}

@(shader_shared)
GpuCullPushConstants :: struct #max_field_align(16) {
	candidates:      backend.GPUPtr(GpuCullCandidate),
	runs:            backend.GPUPtr(GpuCullRun),
	transforms:      backend.GPUPtr(GpuTransform),
	planes:          backend.GPUPtr(Vec4),
	output_ids:      backend.GPUPtr(u32),
	commands:        backend.GPUPtr(DrawIndexedIndirectCommand),
	candidate_count: u32,
	run_count:       u32,
	init_commands:   u32,
}
