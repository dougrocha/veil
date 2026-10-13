package graphics

import "core:math"
import "core:math/linalg"

import "backend"

@(shader_shared)
MAX_POINT_SHADOW_LIGHTS :: 8
@(shader_shared)
SHADOW_MAP_CASCADE_COUNT :: 4
@(shader_shared)
POINT_SHADOW_MAP_SIZE :: 1024 // per cube face
@(shader_shared)
MAX_SHADOW_2D_SLOTS :: (MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT) + MAX_SPOT_LIGHTS

@(shader_shared)
GpuShadowCascadeData :: struct #max_field_align(16) {
	split: Vec4,
	bias:  Vec4,
}

@(shader_shared)
ShadowPushConstants :: struct #max_field_align(16) {
	view_proj:        Mat4x4,
	scene_data:       backend.GPUPtr(SceneData),
	vertex_buffer:    backend.GPUPtr(Vertex),
	material_buffer:  backend.GPUPtr(GpuMaterial),
	transform_buffer: backend.GPUPtr(GpuTransform),
	instance_ids:     backend.GPUPtr(u32), // see instancing.odin
	light_type:       LightType,
	light_index:      u32,
}

Shadows :: struct {
	point_atlas: ShadowAtlas, // cube array, Depth_Cube_Array slot
	atlas_2d:    ShadowAtlas, // directional + spot, Depth_2D_Array slot
	cache:       ShadowCache,
	casters:     ShadowCasters,
}

// Writes the atlases into their fixed bindless slots, so the bindless table must exist
// (texture_system_create).
shadows_create :: proc(ctx: ^backend.Context, shadows: ^Shadows) {
	shadows.point_atlas = shadow_atlas_create(ctx, POINT_SHADOW_MAP_SIZE, MAX_POINT_SHADOW_LIGHTS * 6, cube = true)
	backend.bindless_write_fixed(ctx, .Depth_Cube_Array, shadows.point_atlas.image, shadows.point_atlas.sampler)
	shadows.atlas_2d = shadow_atlas_create(ctx, SHADOW_MAP_SIZE, MAX_SHADOW_2D_SLOTS, cube = false)
	backend.bindless_write_fixed(ctx, .Depth_2D_Array, shadows.atlas_2d.image, shadows.atlas_2d.sampler)
}

shadows_destroy :: proc(ctx: ^backend.Context, shadows: ^Shadows) {
	shadow_atlas_destroy(ctx, &shadows.atlas_2d)
	shadow_atlas_destroy(ctx, &shadows.point_atlas)
	shadow_casters_destroy(&shadows.casters)
}

ShadowParams :: struct {
	aspect: f32,
}

DirectionalShadowData :: struct {
	view_proj: [SHADOW_MAP_CASCADE_COUNT]Mat4x4,
	splits:    Vec4,
	bias:      Vec4,
}

CUBE_FACE_DIRS := [6]struct {
	target, up: Vec3,
} {
	{{1, 0, 0}, {0, -1, 0}},
	{{-1, 0, 0}, {0, -1, 0}},
	{{0, 1, 0}, {0, 0, 1}},
	{{0, -1, 0}, {0, 0, -1}},
	{{0, 0, 1}, {0, -1, 0}},
	{{0, 0, -1}, {0, -1, 0}},
}

compute_point_light_view_proj :: proc(light: PointLight) -> [6]Mat4x4 {
	light_proj := matrix4_perspective_z0_f32(
		linalg.to_radians(f32(90.0)),
		1.0,
		light.shadow_near,
		light.range,
		flip_y_axis = false,
	)

	view_proj: [6]Mat4x4
	for face_dir, face_i in CUBE_FACE_DIRS {
		light_view := linalg.matrix4_look_at(light.pos, light.pos + face_dir.target, face_dir.up)
		view_proj[face_i] = light_proj * light_view
	}
	return view_proj
}

compute_directional_shadow_data :: proc(
	light: DirectionalLight,
	camera: Camera,
	params: ShadowParams,
) -> DirectionalShadowData {
	up := Vec3{0, 1, 0}
	if abs(light.direction.y) > 0.999 do up = {0, 0, 1}

	cascade_lambda: f32 = 0.5

	// Cascades are distributed over the shadow range, not the whole view range:
	// a far plane much larger than the scene would otherwise spend most of the
	// cascade budget on depth that holds no geometry.
	near := camera.near
	far := camera.far
	if light.shadow_maximum_distance > 0 {
		far = min(light.shadow_maximum_distance, camera.far)
	}
	far = max(far, near + 1e-4)
	range := far - near
	ratio := far / near

	splits: [SHADOW_MAP_CASCADE_COUNT]f32
	for i in 0 ..< SHADOW_MAP_CASCADE_COUNT {
		p := f32(i + 1) / f32(SHADOW_MAP_CASCADE_COUNT)
		log_split := near * math.pow(ratio, p)
		uniform_split := near + range * p
		splits[i] = cascade_lambda * (log_split - uniform_split) + uniform_split
	}

	data: DirectionalShadowData
	for i in 0 ..< SHADOW_MAP_CASCADE_COUNT {
		shadow_camera := camera

		cascade_near := i == 0 ? near : splits[i - 1]
		cascade_far := splits[i]
		shadow_camera.near = cascade_near
		shadow_camera.far = cascade_far

		corners := frustum_corners_from_camera(&shadow_camera, params.aspect)

		center := Vec3{0, 0, 0}
		for c in corners do center += c
		center /= 8

		radius: f32 = 0
		for c in corners do radius = max(radius, linalg.length(c - center))

		texel_size := (radius * 2) / f32(SHADOW_MAP_SIZE)
		data.bias[i] = texel_size / (radius * 2)

		snap_view := linalg.matrix4_look_at(Vec3{0, 0, 0}, light.direction, up, true)
		center_light_space := (snap_view * Vec4{center.x, center.y, center.z, 1.0}).xyz
		center_light_space.x = math.floor(center_light_space.x / texel_size) * texel_size
		center_light_space.y = math.floor(center_light_space.y / texel_size) * texel_size
		center =
			(linalg.inverse(snap_view) * Vec4{center_light_space.x, center_light_space.y, center_light_space.z, 1.0}).xyz

		eye := center - light.direction * radius
		dir_view := linalg.matrix4_look_at(eye, center, up, true)

		dir_proj := matrix4_ortho3d_z0_f32(-radius, radius, -radius, radius, 0, radius * 2)

		data.view_proj[i] = dir_proj * dir_view
	}

	#assert(SHADOW_MAP_CASCADE_COUNT <= 4, "cascade splits are packed into a Vec4")
	for split, i in splits do data.splits[i] = split
	return data
}

compute_spot_light_view_proj :: proc(light: SpotLight) -> Mat4x4 {
	up := Vec3{0, 1, 0}
	if abs(light.direction.y) > 0.999 do up = {0, 0, 1}

	// outer_cutoff is stored as a cosine; the cone's full angle is the fov
	spot_fov := 2 * math.acos(light.outer_cutoff)
	spot_view := linalg.matrix4_look_at(light.pos, light.pos + light.direction, up)
	spot_proj := matrix4_perspective_z0_f32(spot_fov, 1.0, light.shadow_near, light.range)

	return spot_proj * spot_view
}

// One shadow view and the casters it draws, filtered during preparation.
ShadowPreparedView :: struct {
	view:  ShadowView,
	draws: DrawGroups,
}

// The views for one atlas this frame. Absent when the atlas has nothing to draw.
ShadowPassPrep :: struct {
	views:    []ShadowPreparedView,
	counters: DrawCounters,
}

// Plans this frame's shadow work. Lights of a type turned off, or every light when shadows are off,
// render nothing but still have their cache entries invalidated.
shadow_prepare :: proc(
	input: PrepareInput,
	layout: ^LayoutBuilder,
) -> (
	plan: ShadowPlan,
	atlas_2d, cube: Maybe(ShadowPassPrep),
) {
	packet := input.packet
	shadow_lights := packet.settings.lights if packet.settings.shadows else LightTypes{}
	aspect := extent_aspect(input.targets.extent)
	plan = shadow_plan(packet.lights, input.history.changes[:], packet.camera, aspect, input.cache, shadow_lights)
	for kind in ShadowAtlasKind {
		views := make([dynamic]ShadowPreparedView, context.temp_allocator)
		p: ShadowPassPrep
		for view in plan.views {
			if view.atlas != kind do continue
			frustums := []Frustum{frustum_from_view_proj(view.view_proj)}
			// Directional cascades ignore the near plane, since their depth is clamped rather than clipped.
			runs := shadow_casters_filter(input.casters, frustums, view.light_type == .Directional)
			pipeline := PipelineKind.Shadow_Directional if view.light_type == .Directional else PipelineKind.Shadow
			draws, _ := layout_push_runs(layout, runs, pipeline)
			append(&views, ShadowPreparedView{view, draws})
			draw_counters_add(&p.counters, draws.counters)
		}
		if len(views) == 0 do continue
		p.views = views[:]
		if kind == .Atlas_2D {
			atlas_2d = p
		} else {
			cube = p
		}
	}
	return
}

record_shadow_2d :: proc(r: ^Recorder, f: ^PreparedFrame) {
	record_shadow_views(r, f.passes.shadow_2d.?, r.atlas_2d)
}

record_shadow_point :: proc(r: ^Recorder, f: ^PreparedFrame) {
	record_shadow_views(r, f.passes.shadow_point.?, r.atlas_cube)
}

@(private = "file")
record_shadow_views :: proc(r: ^Recorder, pass: ShadowPassPrep, atlas: backend.Image) {
	for prepared in pass.views {
		view := prepared.view
		// The executor has already put the atlas in .Depth_Write.
		encoder := backend.begin_render_pass(
			r.cmd,
			backend.PassConfig{depth = {image = atlas, layer = view.layer}, load_op = .Clear, store_depth = true},
		)
		backend.cmd_bind_index_buffer(encoder, r.geometry.index)
		backend.cmd_set_depth_bias(encoder, 1.25, 0, 1.75)
		pc := ShadowPushConstants {
			view_proj        = view.view_proj,
			scene_data       = rec_scene_data(r),
			vertex_buffer    = r.geometry.vertices,
			material_buffer  = r.geometry.materials,
			transform_buffer = backend.buffer_address(r.ctx, r.frame.transforms_buffer),
			instance_ids     = backend.buffer_address(r.ctx, r.frame.instance_ids_buffer),
			light_type       = view.light_type,
			light_index      = view.light_index,
		}
		layout_record_groups(r, encoder, prepared.draws, &pc)
		backend.end_render_pass(encoder)
	}
}
