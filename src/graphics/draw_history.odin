package graphics

import "base:intrinsics"
import "core:log"
import "core:math/linalg"

import "backend"

// The previous packet's draws, kept so each new packet can be diffed against it. The diff drives
// the partial transform uploads and the shadow cache invalidation; nothing else is retained.
DrawHistory :: struct {
	records: []DrawRecord, // MAX_DRAWS, indexed by draw id
	high:    int, // one past the highest id ever drawn; records[high:] are all free
	seen:    []u64, // scratch for draw_history_sync: the ids in this packet
	// Since the last recorded frame. A skipped frame keeps them, so the shadow cache still sees them.
	changes: [dynamic]DrawChange,
	// Per frame slot: draw ids changed since that slot's transforms buffer was written. Each slot's
	// bits clear only when that slot submits.
	dirty:   [backend.MAX_FRAMES_IN_FLIGHT][MAX_DRAWS / 64]u64,
}

// One id's draw as of the previous packet. model is INVALID_MODEL for a free id.
DrawRecord :: struct {
	model:        ModelHandle,
	bounds:       BoundingSphere, // model space, copied from the model
	world:        Mat4x4,
	casts_shadow: bool,
}

// What a change needs to know about a draw on one side of it.
DrawState :: struct {
	bounds:       BoundingSphere, // world space
	casts_shadow: bool,
}

DrawChangeKind :: enum {
	Spawn, // old is unused
	Update, // same model: moved or casts_shadow toggled
	Replace, // same id, different model: old and new bounds differ in shape, not just place
	Despawn, // new is unused
}

// One id whose draw differs from the previous packet's.
DrawChange :: struct {
	kind: DrawChangeKind,
	id:   u32,
	old:  DrawState,
	new:  DrawState,
}

draw_history_create :: proc(history: ^DrawHistory) {
	history.records = make([]DrawRecord, MAX_DRAWS)
	history.seen = make([]u64, MAX_DRAWS / 64)
}

draw_history_destroy :: proc(history: ^DrawHistory) {
	delete(history.records)
	delete(history.seen)
	delete(history.changes)
}

// The records that can be live, for loops that skip free ones.
draw_history_live :: proc(history: ^DrawHistory) -> []DrawRecord {
	return history.records[:history.high]
}

// Diffs packet's draws against the previous ones: records a change for each id that appeared,
// moved, swapped its model, toggled casts_shadow or went away, and marks it dirty in every frame's
// transforms buffer.
// TODO: O(draws) per frame, comparing every draw's matrix even when nothing moved. See the
// matching TODO on world_update in src/world.odin.
draw_history_sync :: proc(engine: ^Engine, packet: ^FramePacket) {
	history := &engine.prev_draws
	for &word in history.seen do word = 0
	for draw in packet.draws {
		if draw.id >= MAX_DRAWS || draw.model == INVALID_MODEL {
			log.errorf("draw %d: id out of range or no model; skipped", draw.id)
			continue
		}
		word, bit := draw.id / 64, draw.id % 64
		assert(history.seen[word] & (1 << bit) == 0, "draw id appears twice in one packet")
		history.seen[word] |= 1 << bit

		prev := &history.records[draw.id]
		if prev.model == draw.model && prev.world == draw.world && prev.casts_shadow == draw.casts_shadow do continue
		next := DrawRecord {
			model        = draw.model,
			bounds       = prev.bounds,
			world        = draw.world,
			casts_shadow = draw.casts_shadow,
		}
		if prev.model != draw.model do next.bounds = pool_get(&engine.model_system.models, draw.model).bounds
		kind: DrawChangeKind
		switch {
		case prev.model == INVALID_MODEL:
			kind = .Spawn
		case prev.model != draw.model:
			kind = .Replace
		case:
			kind = .Update
		}
		draw_change(engine, kind, draw.id, prev^, next)
		prev^ = next
		history.high = max(history.high, int(draw.id) + 1)
	}
	for &prev, id in draw_history_live(history) {
		if prev.model == INVALID_MODEL || history.seen[id / 64] & (1 << (uint(id) % 64)) != 0 do continue
		draw_change(engine, .Despawn, u32(id), prev, {})
		prev = {}
	}
}

@(private = "file")
draw_change :: proc(engine: ^Engine, kind: DrawChangeKind, id: u32, old, new: DrawRecord) {
	change := DrawChange {
		kind = kind,
		id   = id,
	}
	if kind != .Spawn do change.old = {draw_world_sphere(old), old.casts_shadow}
	if kind != .Despawn do change.new = {draw_world_sphere(new), new.casts_shadow}
	append(&engine.prev_draws.changes, change)
	for &slot in engine.prev_draws.dirty do slot[id / 64] |= 1 << (id % 64)
}

// World-space bounding sphere: the model's sphere moved by the world matrix, radius scaled by the
// largest axis scale.
draw_world_sphere :: proc(record: DrawRecord) -> BoundingSphere {
	return sphere_to_global(record.bounds, record.world)
}

// One draw's GPU transform, keyed by its id.
TransformWrite :: struct {
	id:    u32,
	value: GpuTransform,
}

// This slot's dirty ids as GPU transforms, in id order. Skips a free id: nothing draws it, and
// reusing it records a Spawn change.
transform_writes :: proc(history: ^DrawHistory, slot: int) -> []TransformWrite {
	writes := make([dynamic]TransformWrite, context.temp_allocator)
	for word, word_i in history.dirty[slot] {
		remaining := word
		for remaining != 0 {
			bit := int(intrinsics.count_trailing_zeros(remaining))
			remaining &= remaining - 1
			id := word_i * 64 + bit
			record := history.records[id]
			if record.model == INVALID_MODEL do continue
			normal3 := linalg.transpose(linalg.inverse(linalg.matrix3_from_matrix4(record.world)))
			append(
				&writes,
				TransformWrite {
					id = u32(id),
					value = {model = record.world, normal_matrix = linalg.matrix4_from_matrix3(normal3)},
				},
			)
		}
	}
	return writes[:]
}

// Submission is the acknowledgement of both this slot's uploads and the consumed scene changes.
draw_history_commit :: proc(history: ^DrawHistory, slot: int) {
	history.dirty[slot] = {}
	clear(&history.changes)
}
