#+build darwin

package backend

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

// Copies a color image back to CPU memory as tightly packed RGBA8. The caller
// owns the returned slice. Only used by the frame dump, so it takes the simple
// route: a shared staging buffer and a blocking blit.
image_read_rgba8 :: proc(ctx: ^Context, img: ^GpuImage, allocator := context.allocator) -> []u8 {
	width := int(img.extent.width)
	height := int(img.extent.height)
	row_pitch := width * 4
	size := row_pitch * height

	staging := ctx.device->newBufferWithLength(NS.UInteger(size), {})
	defer staging->release()

	{
		cmd := immediate_submit(ctx)
		encoder := (^MTL.CommandBuffer)(cmd)->blitCommandEncoder()
		encoder->copyFromTextureEx(
			img.texture,
			0,
			0,
			MTL.Origin{0, 0, 0},
			MTL.Size{NS.Integer(width), NS.Integer(height), 1},
			staging,
			0,
			NS.UInteger(row_pitch),
			NS.UInteger(size),
		)
		encoder->endEncoding()
	}

	out := make([]u8, size, allocator)
	src := staging->contents()
	copy(out, src[:size])

	// The draw target is BGRA8; stb writes channels in memory order.
	if img.format == .BGRA8Unorm || img.format == .BGRA8Unorm_sRGB {
		for i := 0; i < size; i += 4 {
			out[i], out[i + 2] = out[i + 2], out[i]
		}
	}
	return out
}
