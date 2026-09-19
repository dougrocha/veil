#+build darwin

package backend

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

Extent3D :: MTL.Size

extent3d :: proc(width, height, depth: u32) -> Extent3D {
	return {NS.Integer(width), NS.Integer(height), NS.Integer(depth)}
}

image_barrier :: proc(
	cmd: CommandBuffer,
	img: ^GpuImage,
	dst: ImageStateKind,
	aspect_mask: ImageAspectFlags,
	base_mip_level: u32 = 0,
	level_count: u32 = 1,
	base_array_layer: u32 = 0,
	layer_count: u32 = 1,
) {
}

GpuImage :: struct {
	texture:      ^MTL.Texture,
	extent:       MTL.Size,
	format:       MTL.PixelFormat,
	mip_levels:   u32,
	array_layers: u32,
	usage:        ImageUsageFlags,
}

ImageDesc :: struct {
	extent:       MTL.Size,
	format:       MTL.PixelFormat,
	usage:        ImageUsageFlags,
	mip_levels:   u32,
	array_layers: u32,
	samples:      u32,
	texture_type: MTL.TextureType,
}

image_usage_to_mtl :: proc(usage: ImageUsageFlags) -> MTL.TextureUsage {
	flags: MTL.TextureUsage
	if .Sampled in usage || .TransferSrc in usage do flags += {.ShaderRead}
	if .Storage in usage do flags += {.ShaderWrite}
	if .ColorAttachment in usage || .DepthStencilAttachment in usage do flags += {.RenderTarget}
	return flags
}

image_desc_default :: proc(extent: MTL.Size, format: MTL.PixelFormat, usage: ImageUsageFlags) -> ImageDesc {
	return ImageDesc {
		extent = extent,
		format = format,
		usage = usage,
		mip_levels = 1,
		array_layers = 1,
		samples = 1,
		texture_type = .Type2D,
	}
}

image_create :: proc(ctx: ^Context, desc: ImageDesc) -> GpuImage {
	tex_desc := MTL.TextureDescriptor.alloc()->init()
	defer tex_desc->release()
	texture_type := desc.texture_type
	if desc.samples > 1 && texture_type == .Type2D {
		texture_type = .Type2DMultisample
	} else if desc.array_layers > 1 && texture_type == .Type2D {
		texture_type = .Type2DArray
	}
	tex_desc->setTextureType(texture_type)
	tex_desc->setPixelFormat(desc.format)
	tex_desc->setWidth(NS.UInteger(desc.extent.width))
	tex_desc->setHeight(NS.UInteger(desc.extent.height))
	tex_desc->setMipmapLevelCount(NS.UInteger(desc.mip_levels))
	array_length := desc.array_layers
	if texture_type == .TypeCube {
		assert(desc.array_layers == 6)
		array_length = 1
	} else if texture_type == .TypeCubeArray {
		assert(desc.array_layers % 6 == 0)
		array_length = desc.array_layers / 6
	}
	tex_desc->setArrayLength(NS.UInteger(array_length))
	tex_desc->setSampleCount(NS.UInteger(desc.samples))
	tex_desc->setUsage(image_usage_to_mtl(desc.usage))
	tex_desc->setStorageMode(.Memoryless if .Transient in desc.usage else .Private)

	texture := ctx.device->newTextureWithDescriptor(tex_desc)

	return GpuImage {
		texture = texture,
		extent = desc.extent,
		format = desc.format,
		mip_levels = desc.mip_levels,
		array_layers = desc.array_layers,
		usage = desc.usage,
	}
}

image_desc_set_cube_array :: proc(desc: ^ImageDesc) {
	desc.texture_type = .TypeCube if desc.array_layers == 6 else .TypeCubeArray
}

image_create_default_view :: proc(ctx: ^Context, img: ^GpuImage, cube: bool, layers: u32) {
}

image_view_create_default :: proc(ctx: ^Context, img: ^GpuImage) {
}

image_view_create_cubemap :: proc(ctx: ^Context, img: ^GpuImage) {
}

device_max_anisotropy :: proc(ctx: ^Context) -> f32 {
	return 16.0
}

image_destroy :: proc(ctx: ^Context, img: GpuImage) {
	img.texture->release()
}

generate_mipmaps :: proc(ctx: ^Context, img: ^GpuImage) {
	if img.mip_levels <= 1 {
		return
	}

	pool := autorelease_pool_begin()
	defer autorelease_pool_end(pool)

	cmd_buffer := ctx.command_queue->commandBuffer()
	encoder := cmd_buffer->blitCommandEncoder()
	encoder->generateMipmapsForTexture(img.texture)
	encoder->endEncoding()
	cmd_buffer->commit()
}

copy_image_to_image :: proc(ctx: ^Context, src, dst: ^MTL.Texture) {
	pool := autorelease_pool_begin()
	defer autorelease_pool_end(pool)

	cmd_buffer := ctx.command_queue->commandBuffer()
	encoder := cmd_buffer->blitCommandEncoder()
	encoder->copyFromTexture(src, dst)
	encoder->endEncoding()
	cmd_buffer->commit()
}

copy_buffer_to_image :: proc(cmd: CommandBuffer, buffer: ^MTL.Buffer, img: ^GpuImage, width, height: u32) {
	cmd_buffer := (^MTL.CommandBuffer)(cmd)
	encoder := cmd_buffer->blitCommandEncoder()
	bytes_per_row := width * pixel_format_bytes_per_pixel(img.format)
	encoder->copyFromBufferEx(
		buffer,
		0,
		NS.UInteger(bytes_per_row),
		0,
		MTL.Size{NS.Integer(width), NS.Integer(height), 1},
		img.texture,
		0,
		0,
		MTL.Origin{0, 0, 0},
	)
	encoder->endEncoding()
}

copy_buffer_to_cubemap :: proc(
	cmd: CommandBuffer,
	buffer: ^MTL.Buffer,
	img: ^GpuImage,
	face_w, face_h: u32,
	face_size: u32,
) {
	cmd_buffer := (^MTL.CommandBuffer)(cmd)
	encoder := cmd_buffer->blitCommandEncoder()
	for i in 0 ..< 6 {
		encoder->copyFromBufferEx(
			buffer,
			NS.UInteger(u32(i) * face_size),
			NS.UInteger(face_w) * 4,
			0,
			MTL.Size{NS.Integer(face_w), NS.Integer(face_h), 1},
			img.texture,
			NS.UInteger(i),
			0,
			MTL.Origin{0, 0, 0},
		)
	}
	encoder->endEncoding()
}

LOD_CLAMP_NONE :: 1000.0

SamplerDesc :: struct {
	min_filter, mag_filter:   TextureFilter,
	mipmap_mode:              MTL.SamplerMipFilter,
	address_mode_u:           TextureRepeat,
	address_mode_v:           TextureRepeat,
	address_mode_w:           TextureRepeat,
	mip_lod_bias:             f32,
	anisotropy_enable:        bool,
	max_anisotropy:           f32,
	compare_enable:           bool,
	compare_op:               CompareOp,
	min_lod, max_lod:         f32,
	border_color:             BorderColor,
	unnormalized_coordinates: bool,
}

border_color_to_mtl :: proc(color: BorderColor) -> MTL.SamplerBorderColor {
	switch color {
	case .TransparentBlack:
		return .TransparentBlack
	case .OpaqueBlack:
		return .OpaqueBlack
	case .OpaqueWhite:
		return .OpaqueWhite
	}
	return .OpaqueWhite
}

sampler_desc_default :: proc() -> SamplerDesc {
	return SamplerDesc {
		min_filter = .Linear,
		mag_filter = .Linear,
		mipmap_mode = .Linear,
		address_mode_u = .Clamp_To_Edge,
		address_mode_v = .Clamp_To_Edge,
		address_mode_w = .Clamp_To_Edge,
		max_anisotropy = 1,
		compare_op = .Never,
		max_lod = 1.0,
		border_color = .OpaqueWhite,
	}
}

sampler_create :: proc(ctx: ^Context, desc: SamplerDesc) -> Sampler {
	sampler_desc := MTL.SamplerDescriptor.alloc()->init()
	defer sampler_desc->release()
	sampler_desc->setSupportArgumentBuffers(true)
	sampler_desc->setMinFilter(texture_filter_to_backend(desc.min_filter))
	sampler_desc->setMagFilter(texture_filter_to_backend(desc.mag_filter))
	sampler_desc->setMipFilter(desc.mipmap_mode)
	sampler_desc->setSAddressMode(texture_repeat_to_backend(desc.address_mode_u))
	sampler_desc->setTAddressMode(texture_repeat_to_backend(desc.address_mode_v))
	sampler_desc->setRAddressMode(texture_repeat_to_backend(desc.address_mode_w))
	sampler_desc->setMaxAnisotropy(NS.UInteger(desc.max_anisotropy) if desc.anisotropy_enable else 1)
	sampler_desc->setLodMinClamp(desc.min_lod)
	sampler_desc->setLodMaxClamp(desc.max_lod)
	sampler_desc->setBorderColor(border_color_to_mtl(desc.border_color))
	sampler_desc->setNormalizedCoordinates(!desc.unnormalized_coordinates)
	if desc.compare_enable {
		sampler_desc->setCompareFunction(compare_op_to_mtl(desc.compare_op))
	}

	return Sampler(ctx.device->newSamplerState(sampler_desc))
}

sampler_destroy :: proc(ctx: ^Context, sampler: Sampler) {
	(^MTL.SamplerState)(sampler)->release()
}
