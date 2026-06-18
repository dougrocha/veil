package graphics

create_plane :: proc(
	engine: ^Engine,
	name: string,
	material: MaterialHandle = INVALID_MATERIAL,
	half_size: Vec2 = {0.5, 0.5},
	subdivisions: u32 = 0,
) -> ModelHandle {
	if handle, ok := engine.model_system.model_map[name]; ok {
		return handle
	}

	cols := subdivisions + 2
	rows := subdivisions + 2
	size := half_size * 2

	vertices := make([]Vertex, cols * rows)
	defer delete(vertices)

	for z in 0 ..< rows {
		for x in 0 ..< cols {
			tx := f32(x) / f32(cols - 1)
			tz := f32(z) / f32(rows - 1)
			vertices[z * cols + x] = Vertex {
				pos    = {(-0.5 + tx) * size.x, 0, (-0.5 + tz) * size.y},
				uv     = {tx, tz},
				color  = {1, 1, 1},
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

	return register_model(engine, name, vertices, indices, material)
}

create_cube :: proc(
	engine: ^Engine,
	name: string,
	material: MaterialHandle = INVALID_MATERIAL,
	half_size: Vec3 = {0.5, 0.5, 0.5},
) -> ModelHandle {
	if handle, ok := engine.model_system.model_map[name]; ok {
		return handle
	}

	min := -half_size
	max := half_size

	vertices := []Vertex {
		// front (+Z)
		{pos = {min.x, min.y, max.z}, uv = {0, 0}, color = {1, 1, 1}, normal = {0, 0, 1}},
		{pos = {max.x, min.y, max.z}, uv = {1, 0}, color = {1, 1, 1}, normal = {0, 0, 1}},
		{pos = {max.x, max.y, max.z}, uv = {1, 1}, color = {1, 1, 1}, normal = {0, 0, 1}},
		{pos = {min.x, max.y, max.z}, uv = {0, 1}, color = {1, 1, 1}, normal = {0, 0, 1}},
		// back (-Z)
		{pos = {max.x, min.y, min.z}, uv = {0, 0}, color = {1, 1, 1}, normal = {0, 0, -1}},
		{pos = {min.x, min.y, min.z}, uv = {1, 0}, color = {1, 1, 1}, normal = {0, 0, -1}},
		{pos = {min.x, max.y, min.z}, uv = {1, 1}, color = {1, 1, 1}, normal = {0, 0, -1}},
		{pos = {max.x, max.y, min.z}, uv = {0, 1}, color = {1, 1, 1}, normal = {0, 0, -1}},
		// right (+X)
		{pos = {max.x, min.y, min.z}, uv = {0, 0}, color = {1, 1, 1}, normal = {1, 0, 0}},
		{pos = {max.x, max.y, min.z}, uv = {1, 0}, color = {1, 1, 1}, normal = {1, 0, 0}},
		{pos = {max.x, max.y, max.z}, uv = {1, 1}, color = {1, 1, 1}, normal = {1, 0, 0}},
		{pos = {max.x, min.y, max.z}, uv = {0, 1}, color = {1, 1, 1}, normal = {1, 0, 0}},
		// left (-X)
		{pos = {min.x, min.y, max.z}, uv = {1, 0}, color = {1, 1, 1}, normal = {-1, 0, 0}},
		{pos = {min.x, max.y, max.z}, uv = {0, 0}, color = {1, 1, 1}, normal = {-1, 0, 0}},
		{pos = {min.x, max.y, min.z}, uv = {0, 1}, color = {1, 1, 1}, normal = {-1, 0, 0}},
		{pos = {min.x, min.y, min.z}, uv = {1, 1}, color = {1, 1, 1}, normal = {-1, 0, 0}},
		// top (+Y)
		{pos = {max.x, max.y, min.z}, uv = {1, 0}, color = {1, 1, 1}, normal = {0, 1, 0}},
		{pos = {min.x, max.y, min.z}, uv = {0, 0}, color = {1, 1, 1}, normal = {0, 1, 0}},
		{pos = {min.x, max.y, max.z}, uv = {0, 1}, color = {1, 1, 1}, normal = {0, 1, 0}},
		{pos = {max.x, max.y, max.z}, uv = {1, 1}, color = {1, 1, 1}, normal = {0, 1, 0}},
		// bottom (-Y)
		{pos = {max.x, min.y, max.z}, uv = {0, 0}, color = {1, 1, 1}, normal = {0, -1, 0}},
		{pos = {min.x, min.y, max.z}, uv = {1, 0}, color = {1, 1, 1}, normal = {0, -1, 0}},
		{pos = {min.x, min.y, min.z}, uv = {1, 1}, color = {1, 1, 1}, normal = {0, -1, 0}},
		{pos = {max.x, min.y, min.z}, uv = {0, 1}, color = {1, 1, 1}, normal = {0, -1, 0}},
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

	return register_model(engine, name, vertices, indices, material)
}
