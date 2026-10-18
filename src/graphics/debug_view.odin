package graphics

import "backend"

@(shader_shared)
DebugViewMode :: enum u32 {
	Texture_2D,
	Shadow_Cube_Face,
	Shadow_2D,
	Cluster_Heatmap,
}

@(shader_shared)
DebugViewPushConstants :: struct #max_field_align(16) {
	mode:       DebugViewMode,
	index:      u32, // bindless texture index (Texture_2D) or light_index (Shadow_Cube_Face / Shadow_2D)
	face:       u32, // cube face_index (Shadow_Cube_Face only)
	scene_data: backend.GPUPtr(SceneData),
}

MAX_DEBUG_VIEWS :: 64

// A game request for a debug view; overlay_pass_build clips it, and record_overlay fills in scene_data.
DebugViewRequest :: struct {
	mode:  DebugViewMode,
	index: u32,
	face:  u32,
	rect:  Rect2D,
}
