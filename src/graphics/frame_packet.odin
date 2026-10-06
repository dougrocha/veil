package graphics

// What fills the pixels no geometry covers.
Background :: union #no_nil {
	Vec4, // clear color: the pass clears to it, no draw
	TextureHandle, // sky cube: one fullscreen draw
}

// Everything one engine_render call draws, rebuilt by the game every frame. Borrowed for the call.
FramePacket :: struct {
	time:       f32, // game time in seconds; the game decides pause, slow motion and fixed steps
	delta_time: f32, // game time since the previous packet
	draws:      []Draw,
	camera:     Camera, // world space: position, front, up and right are final
	lights:     ^LightData,
	background: Background,
}

// One model to draw. id names the same object across frames, so the renderer can tell what moved,
// appeared or went away; the game uses its entity slot. Ids are unique within a packet.
Draw :: struct {
	id:           u32, // < MAX_DRAWS
	model:        ModelHandle,
	world:        Mat4x4,
	casts_shadow: bool,
}

MAX_DRAWS :: 32768
