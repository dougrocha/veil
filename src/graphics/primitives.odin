package graphics

create_plane :: proc(engine: ^Engine, name: string, texture: TextureHandle = INVALID_TEXTURE) -> ModelHandle {
	if handle, ok := engine.model_system.model_map[name]; ok {
		return handle
	}

	vertices := []Vertex {
		{pos = {-0.5, 0, -0.5}, uv = {0, 0}, color = {1, 1, 1}, normal = {0, 1, 0}},
		{pos = {0.5, 0, -0.5}, uv = {1, 0}, color = {1, 1, 1}, normal = {0, 1, 0}},
		{pos = {0.5, 0, 0.5}, uv = {1, 1}, color = {1, 1, 1}, normal = {0, 1, 0}},
		{pos = {-0.5, 0, 0.5}, uv = {0, 1}, color = {1, 1, 1}, normal = {0, 1, 0}},
	}
	indices := []u32{0, 2, 1, 2, 0, 3}

	return register_model(engine, name, vertices, indices, texture)
}

create_cube :: proc(engine: ^Engine, name: string, texture: TextureHandle = INVALID_TEXTURE) -> ModelHandle {
	if handle, ok := engine.model_system.model_map[name]; ok {
		return handle
	}

	vertices := []Vertex {
		// +Y (top)
		{pos = {-0.5, 0.5, -0.5}, uv = {1, 0}, color = {1, 1, 1}, normal = {0, 1, 0}},
		{pos = {0.5, 0.5, -0.5}, uv = {0, 0}, color = {1, 1, 1}, normal = {0, 1, 0}},
		{pos = {0.5, 0.5, 0.5}, uv = {0, 1}, color = {1, 1, 1}, normal = {0, 1, 0}},
		{pos = {-0.5, 0.5, 0.5}, uv = {1, 1}, color = {1, 1, 1}, normal = {0, 1, 0}},
		// -Y (bottom)
		{pos = {-0.5, -0.5, 0.5}, uv = {1, 0}, color = {1, 1, 1}, normal = {0, -1, 0}},
		{pos = {0.5, -0.5, 0.5}, uv = {0, 0}, color = {1, 1, 1}, normal = {0, -1, 0}},
		{pos = {0.5, -0.5, -0.5}, uv = {0, 1}, color = {1, 1, 1}, normal = {0, -1, 0}},
		{pos = {-0.5, -0.5, -0.5}, uv = {1, 1}, color = {1, 1, 1}, normal = {0, -1, 0}},
		// +Z (front)
		{pos = {-0.5, -0.5, 0.5}, uv = {0, 1}, color = {1, 1, 1}, normal = {0, 0, 1}},
		{pos = {0.5, -0.5, 0.5}, uv = {1, 1}, color = {1, 1, 1}, normal = {0, 0, 1}},
		{pos = {0.5, 0.5, 0.5}, uv = {1, 0}, color = {1, 1, 1}, normal = {0, 0, 1}},
		{pos = {-0.5, 0.5, 0.5}, uv = {0, 0}, color = {1, 1, 1}, normal = {0, 0, 1}},
		// -Z (back)
		{pos = {0.5, -0.5, -0.5}, uv = {0, 1}, color = {1, 1, 1}, normal = {0, 0, -1}},
		{pos = {-0.5, -0.5, -0.5}, uv = {1, 1}, color = {1, 1, 1}, normal = {0, 0, -1}},
		{pos = {-0.5, 0.5, -0.5}, uv = {1, 0}, color = {1, 1, 1}, normal = {0, 0, -1}},
		{pos = {0.5, 0.5, -0.5}, uv = {0, 0}, color = {1, 1, 1}, normal = {0, 0, -1}},
		// +X (right)
		{pos = {0.5, -0.5, 0.5}, uv = {0, 1}, color = {1, 1, 1}, normal = {1, 0, 0}},
		{pos = {0.5, -0.5, -0.5}, uv = {1, 1}, color = {1, 1, 1}, normal = {1, 0, 0}},
		{pos = {0.5, 0.5, -0.5}, uv = {1, 0}, color = {1, 1, 1}, normal = {1, 0, 0}},
		{pos = {0.5, 0.5, 0.5}, uv = {0, 0}, color = {1, 1, 1}, normal = {1, 0, 0}},
		// -X (left)
		{pos = {-0.5, -0.5, -0.5}, uv = {0, 1}, color = {1, 1, 1}, normal = {-1, 0, 0}},
		{pos = {-0.5, -0.5, 0.5}, uv = {1, 1}, color = {1, 1, 1}, normal = {-1, 0, 0}},
		{pos = {-0.5, 0.5, 0.5}, uv = {1, 0}, color = {1, 1, 1}, normal = {-1, 0, 0}},
		{pos = {-0.5, 0.5, -0.5}, uv = {0, 0}, color = {1, 1, 1}, normal = {-1, 0, 0}},
	}
	indices := []u32 {
		// +Y top (reversed)
		0,
		2,
		1,
		2,
		0,
		3,
		// -Y bottom (reversed)
		4,
		6,
		5,
		6,
		4,
		7,
		// +Z front
		8,
		9,
		10,
		10,
		11,
		8,
		// -Z back
		12,
		13,
		14,
		14,
		15,
		12,
		// +X right
		16,
		17,
		18,
		18,
		19,
		16,
		// -X left
		20,
		21,
		22,
		22,
		23,
		20,
	}

	return register_model(engine, name, vertices, indices, texture)
}
