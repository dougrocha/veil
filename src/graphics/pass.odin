package graphics

import "backend"

bloom_downsample_pass :: proc(
	cmd: backend.CommandBuffer,
	img: ^backend.GpuImage,
	src_mip, dst_mip: u32,
	extent: Extent2D,
) {
	backend.image_barrier(
		cmd,
		img,
		.Shader_Read,
		backend.ImageAspectFlags{.COLOR},
		base_mip_level = src_mip,
		level_count = 1,
	)
	// bind compute pipeline
	// bind descriptor set with img.mip_views[src_mip] (read) and img.mip_views[dst_mip] (write/storage)
	// vk.CmdDispatch(vk.CommandBuffer(cmd), group_x, group_y, 1)
}
