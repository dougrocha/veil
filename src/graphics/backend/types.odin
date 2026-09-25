package backend

VEIL_METAL :: ODIN_OS == .Darwin
VEIL_VULKAN :: ODIN_OS == .Linux

#assert(VEIL_METAL || VEIL_VULKAN, "supported targets are Darwin (Metal) and Linux (Vulkan)")

MAX_FRAMES_IN_FLIGHT :: 2

// Validation layers cost CPU on every command; release builds pass -define:VEIL_VALIDATION=false.
VEIL_VALIDATION :: #config(VEIL_VALIDATION, true)

// Timestamp queries per frame slot (GpuTimer).
MAX_GPU_TIMESTAMPS :: 64

BufferAccess :: enum {
	Read,
	Write,
}

BufferAccessFlags :: bit_set[BufferAccess]

ImageUsage :: enum {
	TransferSrc,
	TransferDst,
	Sampled,
	Storage,
	ColorAttachment,
	DepthStencilAttachment,
	Transient,
}

ImageUsageFlags :: bit_set[ImageUsage]

ImageAspect :: enum {
	Color,
	Depth,
	Stencil,
}

ImageAspectFlags :: bit_set[ImageAspect]

ImageStateKind :: enum {
	Undefined,
	Depth_Write,
	Depth_Read,
	Color_Write,
	Transfer_Src,
	Transfer_Dst,
	Present,
	Shader_Read,
}

BorderColor :: enum {
	TransparentBlack,
	OpaqueBlack,
	OpaqueWhite,
}

CompareOp :: enum {
	Never,
	Less,
	Equal,
	LessOrEqual,
	Greater,
	NotEqual,
	GreaterOrEqual,
	Always,
}

LoadOp :: enum u8 {
	Clear,
	Load,
	Dont_Care,
}
