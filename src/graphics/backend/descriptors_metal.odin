#+build darwin

package backend

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

DescriptorSetHandle :: struct {
	buffer:           ^MTL.Buffer,
	textures:         []^MTL.Texture,
	samplers:         []^MTL.SamplerState,
	bindless:         bool,
	argument_encoder: ^MTL.ArgumentEncoder,
}

DescriptorSet :: struct {
	sets:  [MAX_FRAMES_IN_FLIGHT]DescriptorSetHandle,
	count: u32,
}

descriptor_set_create_sampler_array :: proc(
	ctx: ^Context,
	slot_count: u32,
	count: u32 = MAX_FRAMES_IN_FLIGHT,
) -> DescriptorSet {
	set: DescriptorSet
	set.count = count
	for i in 0 ..< count {
		set.sets[i].textures = make([]^MTL.Texture, slot_count)
		set.sets[i].samplers = make([]^MTL.SamplerState, slot_count)
	}
	return set
}

descriptor_set_create_bindless_array :: proc(
	ctx: ^Context,
	texture_count: u32,
	sampler_count: u32,
	count: u32 = MAX_FRAMES_IN_FLIGHT,
) -> DescriptorSet {
	set: DescriptorSet
	set.count = count
	for i in 0 ..< count {
		set.sets[i].textures = make([]^MTL.Texture, texture_count)
		set.sets[i].samplers = make([]^MTL.SamplerState, sampler_count)
	}
	texture_arg := MTL.ArgumentDescriptor.alloc()->init()
	defer texture_arg->release()
	texture_arg->setDataType(.Texture)
	texture_arg->setIndex(0)
	texture_arg->setArrayLength(NS.UInteger(texture_count))
	texture_arg->setAccess(.ReadOnly)
	texture_arg->setTextureType(.Type2D)

	sampler_arg := MTL.ArgumentDescriptor.alloc()->init()
	defer sampler_arg->release()
	sampler_arg->setDataType(.Sampler)
	sampler_arg->setIndex(NS.UInteger(texture_count))
	sampler_arg->setArrayLength(NS.UInteger(sampler_count))

	objects := [2]^NS.Object{(^NS.Object)(texture_arg), (^NS.Object)(sampler_arg)}
	arguments := NS.Array.alloc()->initWithObjects(&objects[0], NS.UInteger(len(objects)))
	defer arguments->release()
	argument_encoder := ctx.device->newArgumentEncoderWithArguments(arguments)
	encoded_length := argument_encoder->encodedLength()
	for i in 0 ..< count {
		set.sets[i].argument_encoder = argument_encoder
		set.sets[i].buffer = ctx.device->newBufferWithLength(encoded_length, {})
		set.sets[i].bindless = true
	}
	return set
}

descriptor_set_destroy :: proc(ctx: ^Context, desc: ^DescriptorSet) {
	if desc.count > 0 && desc.sets[0].argument_encoder != nil do desc.sets[0].argument_encoder->release()
	for i in 0 ..< desc.count {
		if desc.sets[i].buffer != nil do desc.sets[i].buffer->release()
		delete(desc.sets[i].textures)
		delete(desc.sets[i].samplers)
	}
}
descriptor_write_image_view :: proc(
	ctx: ^Context,
	set: ^DescriptorSet,
	binding: u32,
	img: ^GpuImage,
	sampler: Sampler,
	state: ImageStateKind = .Shader_Read,
	array_element: u32 = 0,
) {
	slot := binding + array_element
	mtl_sampler := (^MTL.SamplerState)(sampler)
	for i in 0 ..< set.count {
		set.sets[i].textures[slot] = img.texture
		set.sets[i].samplers[slot] = mtl_sampler
	}
}

// Writes one texture slot of the bindless set (see descriptor_set_create_bindless_array).
descriptor_write_bindless_texture :: proc(
	ctx: ^Context,
	desc: ^DescriptorSet,
	array_element: u32,
	img: ^GpuImage,
	state: ImageStateKind = .Shader_Read,
) {
	for i in 0 ..< desc.count {
		set := &desc.sets[i]
		set.textures[array_element] = img.texture
		set.argument_encoder->setArgumentBufferWithOffset(set.buffer, 0)
		set.argument_encoder->setTexture(img.texture, NS.UInteger(array_element))
	}
}

// Writes one sampler slot of the bindless set. Samplers follow the texture array
// in the argument buffer, so their ids start at len(textures).
descriptor_write_bindless_sampler :: proc(ctx: ^Context, desc: ^DescriptorSet, array_element: u32, sampler: Sampler) {
	mtl_sampler := (^MTL.SamplerState)(sampler)
	for i in 0 ..< desc.count {
		set := &desc.sets[i]
		set.samplers[array_element] = mtl_sampler
		set.argument_encoder->setArgumentBufferWithOffset(set.buffer, 0)
		set.argument_encoder->setSamplerState(mtl_sampler, NS.UInteger(len(set.textures)) + NS.UInteger(array_element))
	}
}

descriptor_bind_image :: proc(cmd: RenderEncoder, handle: DescriptorSetHandle, binding, target_index: u32) {
	encoder := (^MTL.RenderCommandEncoder)(cmd)
	texture := handle.textures[binding]
	sampler := handle.samplers[binding]
	if texture != nil do encoder->setFragmentTexture(texture, NS.UInteger(target_index))
	if sampler != nil do encoder->setFragmentSamplerState(sampler, NS.UInteger(target_index))
}
