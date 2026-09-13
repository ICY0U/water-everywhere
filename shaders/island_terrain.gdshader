shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec3 sand_color : source_color = vec3(0.76, 0.66, 0.46);
uniform vec3 earth_color : source_color = vec3(0.48, 0.43, 0.31);
uniform vec3 rock_color : source_color = vec3(0.38, 0.41, 0.46);
uniform vec3 summit_color : source_color = vec3(0.62, 0.64, 0.64);
uniform float beach_height = 6.0;
uniform float rock_height = 28.0;
uniform float texture_strength = 0.065;
varying vec3 world_position;
varying vec3 world_normal;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(cell), hash(cell + vec2(1, 0)), f.x),
		mix(hash(cell + vec2(0, 1)), hash(cell + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	float broad = noise(world_position.xz * 0.055);
	float slope = 1.0 - clamp(normalize(world_normal).y, 0.0, 1.0);
	float height = world_position.y + (broad - 0.5) * 3.0;
	float beach = smoothstep(beach_height - 1.8, beach_height + 2.0, height);
	vec3 ground = mix(sand_color, earth_color, beach);
	float rock = max(smoothstep(rock_height, rock_height + 22.0, height),
		smoothstep(0.10, 0.32, slope)) * beach;
	ground = mix(ground, rock_color, rock);
	ground = mix(ground, summit_color, smoothstep(92.0, 130.0, height) * 0.7);
	// Deep shelf rock stays dark, so finite terrain edges cannot read as bright sand
	// streaks through the ocean's screen-space refraction at a grazing angle.
	ground = mix(vec3(0.12, 0.18, 0.21), ground, smoothstep(-18.0, -3.0, height));
	// Sparse broad mottling and rock strata; no photoreal normals or vegetation.
	float grain = floor(noise(world_position.xz * 1.2) * 3.0) / 3.0;
	float strata = step(0.82, fract((height + broad) * 0.24)) * rock;
	ALBEDO = ground * (1.0 + (broad - 0.5) * 0.12
		+ (grain - 0.5) * texture_strength - strata * 0.045);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float wrapped = dot(normalize(NORMAL), normalize(LIGHT)) * 0.5 + 0.5;
	float bands = floor(clamp(wrapped, 0.0, 1.0) * 3.0 + 0.5) / 3.0;
	bands = min(bands, smoothstep(0.19, 0.25, ATTENUATION));
	vec3 tint = mix(vec3(0.53, 0.63, 0.79), vec3(1.0), bands);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * tint * mix(0.45, 1.0, bands);
}
