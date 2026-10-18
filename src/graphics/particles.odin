package graphics

import "backend"

// One frame's simulation step.
ParticlesPass :: struct {
	delta_time: f32,
}

// Not ok when particles are off, so the pass is not in the list.
particles_pass_build :: proc(packet: ^FramePacket) -> (p: ParticlesPass, ok: bool) {
	if !packet.settings.particles do return {}, false
	return {delta_time = packet.delta_time}, true
}

record_particles :: proc(r: ^Recorder, p: ^ParticlesPass) {
	pc := ParticlePushConstants {
		particles_in  = backend.buffer_address(r.ctx, r.prev_frame.particle_buffer),
		particles_out = backend.buffer_address(r.ctx, r.frame.particle_buffer),
		delta_time    = p.delta_time,
	}
	encoder := backend.begin_compute_pass(r.cmd)
	// particles_in was written by the previous frame's dispatch in an earlier submission.
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	backend.pipeline_bind_compute(encoder, rec_pipeline(r, .Particle_Simulate))
	backend.pipeline_push_compute(encoder, &pc)
	#assert(PARTICLE_COUNT % PARTICLE_GROUP_SIZE == 0)
	backend.cmd_dispatch(encoder, PARTICLE_COUNT / PARTICLE_GROUP_SIZE, 1, 1)
	backend.cmd_barrier_compute_write_to_vertex_read(encoder)
	backend.end_compute_pass(encoder)
}
