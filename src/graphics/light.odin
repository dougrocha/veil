package graphics

import "core:log"

spawn_point_light :: proc(engine: ^Engine, light: PointLight) {
	if engine.point_light_count >= len(engine.point_lights) {
		log.errorf("max point lights reached (%d)", len(engine.point_lights))
		return
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	engine.point_lights[engine.point_light_count] = light
	engine.point_light_count += 1
}

spawn_directional_light :: proc(engine: ^Engine, light: DirectionalLight) {
	if engine.directional_light_count >= len(engine.directional_lights) {
		log.errorf("max directional lights reached (%d)", len(engine.directional_lights))
		return
	}
	engine.directional_lights[engine.directional_light_count] = light
	engine.directional_light_count += 1
}

spawn_spot_light :: proc(engine: ^Engine, light: SpotLight) {
	if engine.spot_light_count >= len(engine.spot_lights) {
		log.errorf("max spot lights reached (%d)", len(engine.spot_lights))
		return
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	engine.spot_lights[engine.spot_light_count] = light
	engine.spot_light_count += 1
}
