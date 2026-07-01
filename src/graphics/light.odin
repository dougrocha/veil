package graphics

import "core:log"

spawn_point_light :: proc(engine: ^Engine, light: PointLight) {
	if engine.scene.point_light_count >= len(engine.scene.point_lights) {
		log.errorf("max point lights reached (%d)", len(engine.scene.point_lights))
		return
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	engine.scene.point_lights[engine.scene.point_light_count] = light
	engine.scene.point_light_count += 1
}

spawn_directional_light :: proc(engine: ^Engine, light: DirectionalLight) {
	if engine.scene.directional_light_count >= len(engine.scene.directional_lights) {
		log.errorf("max directional lights reached (%d)", len(engine.scene.directional_lights))
		return
	}
	engine.scene.directional_lights[engine.scene.directional_light_count] = light
	engine.scene.directional_light_count += 1
}

spawn_spot_light :: proc(engine: ^Engine, light: SpotLight) {
	if engine.scene.spot_light_count >= len(engine.scene.spot_lights) {
		log.errorf("max spot lights reached (%d)", len(engine.scene.spot_lights))
		return
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	engine.scene.spot_lights[engine.scene.spot_light_count] = light
	engine.scene.spot_light_count += 1
}
