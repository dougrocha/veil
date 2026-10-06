package graphics

import "core:math"
import "core:math/linalg"

primitive_plane :: proc(
	engine: ^Engine,
	name: string,
	material: MaterialHandle = INVALID_MATERIAL,
	half_size: Vec2 = {0.5, 0.5},
	subdivisions: u32 = 0,
	with_tangents := false,
) -> ModelHandle {
	if handle, ok := engine.model_system.model_map[name]; ok {
		return handle
	}

	cols := subdivisions + 2
	rows := subdivisions + 2
	size := half_size * 2

	vertices := make([]MeshVertex, cols * rows)
	defer delete(vertices)

	for z in 0 ..< rows {
		for x in 0 ..< cols {
			tx := f32(x) / f32(cols - 1)
			tz := f32(z) / f32(rows - 1)
			vertices[z * cols + x] = MeshVertex {
				pos    = {(-0.5 + tx) * size.x, 0, (-0.5 + tz) * size.y},
				uv     = {tx, tz},
				normal = {0, 1, 0},
			}
		}
	}

	indices := make([]u32, (cols - 1) * (rows - 1) * 6)
	defer delete(indices)

	i := 0
	for z in 0 ..< rows - 1 {
		for x in 0 ..< cols - 1 {
			quad := z * cols + x
			indices[i + 0] = quad + cols + 1
			indices[i + 1] = quad + 1
			indices[i + 2] = quad + cols
			indices[i + 3] = quad
			indices[i + 4] = quad + cols
			indices[i + 5] = quad + 1
			i += 6
		}
	}

	if with_tangents do compute_tangents(vertices[:], indices[:])

	return model_register(engine, name, vertices, indices, material)
}

primitive_cube :: proc(
	engine: ^Engine,
	name: string,
	material: MaterialHandle = INVALID_MATERIAL,
	half_size: Vec3 = {0.5, 0.5, 0.5},
	with_tangents := false,
) -> ModelHandle {
	if handle, ok := engine.model_system.model_map[name]; ok {
		return handle
	}

	min := -half_size
	max := half_size

	vertices := []MeshVertex {
		// front (+Z)
		{pos = {min.x, min.y, max.z}, uv = {0, 0}, normal = {0, 0, 1}},
		{pos = {max.x, min.y, max.z}, uv = {1, 0}, normal = {0, 0, 1}},
		{pos = {max.x, max.y, max.z}, uv = {1, 1}, normal = {0, 0, 1}},
		{pos = {min.x, max.y, max.z}, uv = {0, 1}, normal = {0, 0, 1}},
		// back (-Z)
		{pos = {max.x, min.y, min.z}, uv = {0, 0}, normal = {0, 0, -1}},
		{pos = {min.x, min.y, min.z}, uv = {1, 0}, normal = {0, 0, -1}},
		{pos = {min.x, max.y, min.z}, uv = {1, 1}, normal = {0, 0, -1}},
		{pos = {max.x, max.y, min.z}, uv = {0, 1}, normal = {0, 0, -1}},
		// right (+X)
		{pos = {max.x, min.y, min.z}, uv = {0, 0}, normal = {1, 0, 0}},
		{pos = {max.x, max.y, min.z}, uv = {1, 0}, normal = {1, 0, 0}},
		{pos = {max.x, max.y, max.z}, uv = {1, 1}, normal = {1, 0, 0}},
		{pos = {max.x, min.y, max.z}, uv = {0, 1}, normal = {1, 0, 0}},
		// left (-X)
		{pos = {min.x, min.y, max.z}, uv = {1, 0}, normal = {-1, 0, 0}},
		{pos = {min.x, max.y, max.z}, uv = {0, 0}, normal = {-1, 0, 0}},
		{pos = {min.x, max.y, min.z}, uv = {0, 1}, normal = {-1, 0, 0}},
		{pos = {min.x, min.y, min.z}, uv = {1, 1}, normal = {-1, 0, 0}},
		// top (+Y)
		{pos = {max.x, max.y, min.z}, uv = {1, 0}, normal = {0, 1, 0}},
		{pos = {min.x, max.y, min.z}, uv = {0, 0}, normal = {0, 1, 0}},
		{pos = {min.x, max.y, max.z}, uv = {0, 1}, normal = {0, 1, 0}},
		{pos = {max.x, max.y, max.z}, uv = {1, 1}, normal = {0, 1, 0}},
		// bottom (-Y)
		{pos = {max.x, min.y, max.z}, uv = {0, 0}, normal = {0, -1, 0}},
		{pos = {min.x, min.y, max.z}, uv = {1, 0}, normal = {0, -1, 0}},
		{pos = {min.x, min.y, min.z}, uv = {1, 1}, normal = {0, -1, 0}},
		{pos = {max.x, min.y, min.z}, uv = {0, 1}, normal = {0, -1, 0}},
	}
	indices := []u32 {
		0,
		1,
		2,
		2,
		3,
		0, // front
		4,
		5,
		6,
		6,
		7,
		4, // back
		8,
		9,
		10,
		10,
		11,
		8, // right
		12,
		13,
		14,
		14,
		15,
		12, // left
		16,
		17,
		18,
		18,
		19,
		16, // top
		20,
		21,
		22,
		22,
		23,
		20, // bottom
	}

	if with_tangents do compute_tangents(vertices[:], indices[:])

	return model_register(engine, name, vertices, indices, material)
}

primitive_sphere :: proc(
	engine: ^Engine,
	name: string,
	material: MaterialHandle = INVALID_MATERIAL,
	radius: f32 = 0.5,
	sectors: u32 = 32, // number of longitudinal sectors, horizontal resolution
	stacks: u32 = 18, // number of latitudinal stacks, vertical resolution
	with_tangents := false,
) -> ModelHandle {
	// from bevy: https://www.songho.ca/opengl/gl_sphere.html#sphere
	if handle, ok := engine.model_system.model_map[name]; ok {
		return handle
	}

	vertices_count := stacks * sectors
	vertices := make([dynamic]MeshVertex, 0, vertices_count, context.temp_allocator)
	indices := make([dynamic]u32, 0, vertices_count * 6, context.temp_allocator)

	length_inv := 1.0 / radius
	sector_step := 2 * math.PI / f32(sectors)
	stack_step := math.PI / f32(stacks)

	for i in 0 ..= stacks {
		stack_angle := math.PI / 2 - f32(i) * stack_step

		xy := radius * math.cos(stack_angle)
		z := radius * math.sin(stack_angle)

		for j in 0 ..= sectors {
			sector_angle := f32(j) * sector_step

			x := xy * math.cos(sector_angle)
			y := xy * math.sin(sector_angle)

			nx := x * length_inv
			ny := y * length_inv
			nz := z * length_inv

			s := f32(j) / f32(sectors)
			t := f32(i) / f32(stacks)

			append(&vertices, MeshVertex{pos = {x, y, z}, uv = {s, t}, normal = {nx, ny, nz}})
		}
	}

	// indices
	//  k1--k1+1
	//  |  / |
	//  | /  |
	//  k2--k2+1
	for i in 0 ..< stacks {
		k1 := i * (sectors + 1) // beginning of the current stack
		k2 := k1 + sectors + 1 // beginning of the next stack

		for _ in 0 ..< sectors {
			if i != 0 {
				append(&indices, k1)
				append(&indices, k2)
				append(&indices, k1 + 1)
			}

			if i != stacks - 1 {
				append(&indices, k1 + 1)
				append(&indices, k2)
				append(&indices, k2 + 1)
			}

			k1 += 1
			k2 += 1

		}
	}

	if with_tangents do compute_tangents(vertices[:], indices[:])

	return model_register(engine, name, vertices[:], indices[:], material)
}

// Computes per-vertex tangents from positions, UVs and normals, matching the
// convention mesh.slang expects: xyz is the tangent direction, w is the
// bitangent handedness. Primitives ship without tangents (a zero tangent makes
// the shader fall back to the geometric normal), so this is opt-in per mesh,
// the same way Bevy's with_computed_tangents works.
//
// Degenerate UVs (a zero-area triangle in UV space, or a seam) contribute
// nothing rather than a NaN, and any vertex left without a usable tangent keeps
// its zero so the fallback still applies.
compute_tangents :: proc(vertices: []MeshVertex, indices: []u32) {
	tangents := make([]Vec3, len(vertices), context.temp_allocator)
	bitangents := make([]Vec3, len(vertices), context.temp_allocator)

	for tri := 0; tri + 2 < len(indices); tri += 3 {
		i0, i1, i2 := indices[tri], indices[tri + 1], indices[tri + 2]
		v0, v1, v2 := vertices[i0], vertices[i1], vertices[i2]

		edge1 := v1.pos - v0.pos
		edge2 := v2.pos - v0.pos
		duv1 := v1.uv - v0.uv
		duv2 := v2.uv - v0.uv

		det := duv1.x * duv2.y - duv2.x * duv1.y
		if abs(det) < 1e-12 do continue // degenerate in UV space
		inv_det := 1 / det

		tangent := (edge1 * duv2.y - edge2 * duv1.y) * inv_det
		bitangent := (edge2 * duv1.x - edge1 * duv2.x) * inv_det

		for index in ([3]u32{i0, i1, i2}) {
			tangents[index] += tangent
			bitangents[index] += bitangent
		}
	}

	for &vertex, i in vertices {
		n := vertex.normal
		t := tangents[i]

		// Gram-Schmidt against the normal, then reject anything that collapsed.
		t -= n * linalg.dot(n, t)
		if linalg.dot(t, t) < 1e-12 {
			vertex.tangent = {}
			continue
		}
		t = linalg.normalize(t)

		handedness: f32 = linalg.dot(linalg.cross(n, t), bitangents[i]) < 0 ? -1 : 1
		vertex.tangent = {t.x, t.y, t.z, handedness}
	}
}
