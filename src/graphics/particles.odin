package graphics

import "backend"

// One frame's simulation step.
ParticlesPrep :: struct {
	delta_time: f32,
}

// Nil when particles are off, so the pass is skipped.
particles_prepare :: proc(packet: ^FramePacket) -> Maybe(ParticlesPrep) {
	if !packet.settings.particles do return nil
	return ParticlesPrep{delta_time = packet.delta_time}
}

record_particles :: proc(r: ^Recorder, f: ^PreparedFrame) {
	pc := ParticlePushConstants {
		particles_in  = backend.buffer_address(r.ctx, r.prev_frame.particle_buffer),
		particles_out = backend.buffer_address(r.ctx, r.frame.particle_buffer),
		delta_time    = f.passes.particles.?.delta_time,
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
