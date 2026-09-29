extends Node

## Every sound the game makes goes through here: music, stings, interface clicks, positional
## effects and the ambient beds of sea, wind and rain.
##
## Registered as the [code]Audio[/code] autoload, without a [code]class_name[/code] for the same
## reason as [code]NetworkSession[/code]. It outlives scene changes, so the title music does not
## restart when a scene reloads, and it keeps running while a solo game is paused, so the pause
## menu sits over the sound of the sea rather than over silence.
##
## [b]Presentation only.[/b] No sound is replicated. Every peer decides what to play from state
## it already has — a raft's stroke serial rising, a player's replicated stance, an impact the
## server already forwards for the splash particles — so the sound of a stroke arrives with the
## stroke itself and can never disagree with what is on screen.
##
## The streams are synthesised by [code]tools/generate_audio.py[/code]; see that file for what
## each one is made of.

## Seconds a music crossfade takes by default.
const MUSIC_FADE: float = 1.8

## Level music sits at under a sting, in decibels, while the sting plays.
const DUCK_DB: float = -14.0

## How many positional one-shots may sound at once. A stroke, a creak, a gull and a few footsteps
## is the busy case; beyond this the oldest is reused rather than a new player created.
const POOL_SIZE: int = 20

## Seconds the ambient beds take to follow a change in the weather.
const AMBIENCE_GLIDE: float = 2.5

## Cutoff the ambience bus drops to when the listener's head is under water.
const UNDERWATER_CUTOFF: float = 650.0

## Music tracks, by name.
const MUSIC: Dictionary = {
	&"title": preload("res://assets/audio/music/title.ogg"),
	&"voyage": preload("res://assets/audio/music/voyage.ogg"),
}

## One-shot musical stings, by name.
const STINGS: Dictionary = {
	&"arrival": preload("res://assets/audio/music/arrival.ogg"),
	&"castoff": preload("res://assets/audio/music/castoff.ogg"),
}

## Interface sounds, by name.
const UI_SOUNDS: Dictionary = {
	&"hover": preload("res://assets/audio/ui/hover.ogg"),
	&"click": preload("res://assets/audio/ui/click.ogg"),
	&"back": preload("res://assets/audio/ui/back.ogg"),
	&"toggle": preload("res://assets/audio/ui/toggle.ogg"),
	&"start": preload("res://assets/audio/ui/start.ogg"),
}

## Positional effects, by name. Each entry is a list of variants; one is picked at random so a
## repeated action does not sound mechanical.
const EFFECTS: Dictionary = {
	&"paddle": [
		preload("res://assets/audio/sfx/paddle_1.ogg"),
		preload("res://assets/audio/sfx/paddle_2.ogg"),
		preload("res://assets/audio/sfx/paddle_3.ogg"),
	],
	&"splash_small": [preload("res://assets/audio/sfx/splash_small.ogg")],
	&"splash_big": [preload("res://assets/audio/sfx/splash_big.ogg")],
	&"thud": [preload("res://assets/audio/sfx/wood_thud.ogg")],
	&"creak": [
		preload("res://assets/audio/sfx/creak_1.ogg"),
		preload("res://assets/audio/sfx/creak_2.ogg"),
		preload("res://assets/audio/sfx/creak_3.ogg"),
	],
	&"push": [preload("res://assets/audio/sfx/push.ogg")],
	&"step_sand": [
		preload("res://assets/audio/sfx/step_sand_1.ogg"),
		preload("res://assets/audio/sfx/step_sand_2.ogg"),
		preload("res://assets/audio/sfx/step_sand_3.ogg"),
	],
	&"step_wood": [
		preload("res://assets/audio/sfx/step_wood_1.ogg"),
		preload("res://assets/audio/sfx/step_wood_2.ogg"),
		preload("res://assets/audio/sfx/step_wood_3.ogg"),
	],
	&"swim": [
		preload("res://assets/audio/sfx/swim_1.ogg"),
		preload("res://assets/audio/sfx/swim_2.ogg"),
	],
	&"gull": [
		preload("res://assets/audio/sfx/gull_1.ogg"),
		preload("res://assets/audio/sfx/gull_2.ogg"),
		preload("res://assets/audio/sfx/gull_3.ogg"),
	],
	&"bell": [preload("res://assets/audio/sfx/bell.ogg")],
}

## Ambient beds, by name, and the level each plays at when fully up.
const BEDS: Dictionary = {
	&"ocean": [preload("res://assets/audio/ambience/ocean_loop.ogg"), -6.0],
	&"wind": [preload("res://assets/audio/ambience/wind_loop.ogg"), -8.0],
	&"rain": [preload("res://assets/audio/ambience/rain_loop.ogg"), -7.0],
}

var _music: Array[AudioStreamPlayer] = []
var _music_index: int = 0
var _music_name: StringName = &""
var _sting: AudioStreamPlayer
var _ui: AudioStreamPlayer
var _pool: Array[AudioStreamPlayer3D] = []
var _pool_next: int = 0
var _beds: Dictionary = {}
var _bed_targets: Dictionary = {}
var _underwater: bool = false
## Level the current track plays at, so a sting's duck can be undone to the right level.
var _music_volume: float = 0.0
var _rng := RandomNumberGenerator.new()

## Whether anything is played at all. See [method _ready].
var _enabled: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	# Headless runs are the verification suites and dedicated tooling. Nothing can hear them, and
	# a suite quits the moment its checks are done — with every loop still playing, which the
	# engine then reports as leaked objects at exit. Silent there, everything else unchanged.
	_enabled = DisplayServer.get_name() != "headless"
	for index in 2:
		var player := AudioStreamPlayer.new()
		player.name = "Music%d" % index
		player.bus = &"Music"
		player.volume_db = -80.0
		add_child(player)
		_music.append(player)
	_sting = AudioStreamPlayer.new()
	_sting.name = "Sting"
	_sting.bus = &"Music"
	add_child(_sting)
	_sting.finished.connect(_on_sting_finished)
	_ui = AudioStreamPlayer.new()
	_ui.name = "Interface"
	_ui.bus = &"SFX"
	_ui.max_polyphony = 4
	add_child(_ui)
	for index in POOL_SIZE:
		var player := AudioStreamPlayer3D.new()
		player.name = "Effect%d" % index
		player.bus = &"SFX"
		player.unit_size = 12.0
		player.max_distance = 160.0
		player.attenuation_filter_cutoff_hz = 6000.0
		player.attenuation_filter_db = -12.0
		add_child(player)
		_pool.append(player)
	for bed: StringName in BEDS:
		var player := AudioStreamPlayer.new()
		player.name = "Bed_%s" % bed
		player.bus = &"Ambience"
		player.stream = BEDS[bed][0]
		player.volume_db = -80.0
		add_child(player)
		_beds[bed] = player
		_bed_targets[bed] = 0.0
	UiStyle.sound_player = play_ui


## Stops every sound and waits for the mixer to let go of them. Awaitable.
##
## A stream still playing when the engine shuts down leaves its playback registered with the audio
## server, and each one is reported as a leaked object at exit. The server only releases a stopped
## playback on its next mix, so stopping is not enough on its own: quitting waits a few frames
## after it.
##
## Every player in the tree, not only this node's: the voyage's surf and lighthouse bell live in
## the scene, and each would leak the same way.
func silence() -> void:
	_enabled = false
	_stop_all(get_tree().root)
	for _frame in 3:
		await get_tree().process_frame


func _stop_all(node: Node) -> void:
	for child in node.get_children():
		if child is AudioStreamPlayer:
			(child as AudioStreamPlayer).stop()
		elif child is AudioStreamPlayer3D:
			(child as AudioStreamPlayer3D).stop()
		elif child is AudioStreamPlayer2D:
			(child as AudioStreamPlayer2D).stop()
		_stop_all(child)


func _process(delta: float) -> void:
	# Beds glide toward their targets rather than jumping, so a change of weather swells in.
	var step := delta / AMBIENCE_GLIDE
	for bed: StringName in _beds:
		var player: AudioStreamPlayer = _beds[bed]
		var target: float = _bed_targets[bed]
		var current := db_to_linear(player.volume_db) / db_to_linear(BEDS[bed][1])
		current = move_toward(current, target, step)
		if current <= 0.001:
			if player.playing:
				player.stop()
			player.volume_db = -80.0
			continue
		player.volume_db = linear_to_db(current) + float(BEDS[bed][1])
		if not player.playing and _enabled:
			# Started at a random point so two beds never lock their loop points together.
			player.play(_rng.randf() * player.stream.get_length())


## Plays an interface sound.
func play_ui(sound: StringName) -> void:
	if not _enabled or not UI_SOUNDS.has(sound):
		return
	_ui.stream = UI_SOUNDS[sound]
	_ui.pitch_scale = 1.0 if sound != &"hover" else _rng.randf_range(0.96, 1.04)
	_ui.play()


## Plays a positional effect at [param where], with a little pitch variation.
##
## [param volume_db] trims the effect; [param pitch] centres its pitch, and [param spread]
## scatters it either side so repeats do not sound identical.
func play_at(
	sound: StringName, where: Vector3, volume_db: float = 0.0, pitch: float = 1.0,
	spread: float = 0.06,
) -> void:
	if not _enabled or not EFFECTS.has(sound) or not is_inside_tree():
		return
	var variants: Array = EFFECTS[sound]
	var player := _pool[_pool_next]
	_pool_next = (_pool_next + 1) % _pool.size()
	player.stop()
	player.stream = variants[_rng.randi() % variants.size()]
	player.global_position = where
	player.volume_db = volume_db
	player.pitch_scale = maxf(0.2, pitch + _rng.randf_range(-spread, spread))
	player.play()


## Crossfades to music [param track], or keeps playing it if it already is.
func play_music(track: StringName, fade: float = MUSIC_FADE, volume_db: float = 0.0) -> void:
	if not _enabled or not MUSIC.has(track):
		return
	_music_volume = volume_db
	if track == _music_name and _music[_music_index].playing:
		_fade_player(_music[_music_index], volume_db, fade)
		return
	_music_name = track
	var outgoing := _music[_music_index]
	_music_index = 1 - _music_index
	var incoming := _music[_music_index]
	incoming.stream = MUSIC[track]
	incoming.volume_db = -40.0
	incoming.play()
	_fade_player(incoming, volume_db, fade)
	_fade_player(outgoing, -60.0, fade, true)


## Fades the music out.
func stop_music(fade: float = MUSIC_FADE) -> void:
	_music_name = &""
	for player in _music:
		_fade_player(player, -60.0, fade, true)


## Plays a musical sting over the music, ducking the music beneath it.
func play_sting(sting: StringName) -> void:
	if not _enabled or not STINGS.has(sting):
		return
	_sting.stream = STINGS[sting]
	_sting.play()
	var current := _music[_music_index]
	if current.playing:
		_fade_player(current, DUCK_DB, 0.3)


## Sets how strongly each ambient bed plays, from 0 to 1.
func set_ambience(ocean: float, wind: float, rain: float) -> void:
	_bed_targets[&"ocean"] = clampf(ocean, 0.0, 1.0)
	_bed_targets[&"wind"] = clampf(wind, 0.0, 1.0)
	_bed_targets[&"rain"] = clampf(rain, 0.0, 1.0)


## Muffles the ambience, as heard from under the surface.
func set_underwater(underwater: bool) -> void:
	if underwater == _underwater:
		return
	_underwater = underwater
	var bus := AudioServer.get_bus_index(&"Ambience")
	if bus < 0 or AudioServer.get_bus_effect_count(bus) == 0:
		return
	var filter := AudioServer.get_bus_effect(bus, 0) as AudioEffectLowPassFilter
	if filter != null:
		filter.cutoff_hz = UNDERWATER_CUTOFF if underwater else 20000.0


func _fade_player(player: AudioStreamPlayer, to_db: float, seconds: float, stop: bool = false) -> void:
	var tween := create_tween()
	tween.tween_property(player, "volume_db", to_db, maxf(seconds, 0.01))
	if stop:
		tween.tween_callback(player.stop)


func _on_sting_finished() -> void:
	var current := _music[_music_index]
	if current.playing:
		_fade_player(current, _music_volume, 2.0)
