class_name AudioDirector
extends Node

## Everything the voyage sounds like: sea, wind and rain beds, splashes, the menus and music.
##
## [b]Presentation only, derived on every peer.[/b] Like the wakes and the spray, sound is
## reconstructed locally from state each peer already has — the weather preset, the raft's
## replicated [member Raft.stroke_serial] and [member Raft.push_serial], and the impacts
## [signal Ocean.water_impacted] already raises on every peer — so nothing about audio crosses
## the network, and a client hears the stroke its crewmate made at the moment it sees it.
##
## The sounds themselves are synthesised by [code]tools/generate_audio.py[/code]; see there.

## Buses the mix is split into, each sent to Master, so settings can turn music down alone.
const BUS_MUSIC: StringName = &"Music"
const BUS_EFFECTS: StringName = &"Effects"
const BUS_AMBIENCE: StringName = &"Ambience"

## Wind speed, in metres per second, below which the wind bed is silent. The sunny preset's
## breeze sits a little above it, so calm weather has a whisper of wind and a storm roars.
const WIND_FLOOR: float = 6.0

## Wind speed at which the wind bed reaches full level: the stormy preset's gale.
const WIND_FULL: float = 19.0

## Seconds a bed takes to cross most of the way to a new level, so weather changes fade.
const BED_RESPONSE: float = 1.5

## Seconds music takes to fade when a menu opens or closes.
const MUSIC_RESPONSE: float = 1.2

## Least time between two splashes from impacts, so a hull slapping every wave does not rattle.
const IMPACT_COOLDOWN: float = 0.25

## Impact energy, in joules, below which a touch of the water makes no sound.
##
## Measured: a swimmer's surface ripples register 70 J or so and are inaudible in reality too;
## a real entry is thousands.
const IMPACT_MIN_ENERGY: float = 400.0

## Level every bed and cue is mixed at when "full", in decibels. Beds sit under the effects.
const LEVELS: Dictionary = {
	"ocean": -9.0, "wind": -12.0, "rain": -10.0, "music": -8.0,
	"paddle": -4.0, "splash": -2.0, "ui": -12.0, "arrival": -5.0,
}

## The game whose world this scores. Assigned before the node enters the tree.
var game: VoyageGame

var _ocean: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _rain: AudioStreamPlayer
var _music: AudioStreamPlayer
var _ui: AudioStreamPlayer
var _arrival: AudioStreamPlayer
var _splashes: Array[AudioStreamPlayer3D] = []
var _next_splash: int = 0
var _paddles: Array[AudioStream] = []
var _big_splash: AudioStream
var _strokes_heard: int = -1
var _pushes_heard: int = -1
var _impact_cooldown: float = 0.0
var _music_wanted: bool = true


func _ready() -> void:
	# Menus pause the world; music and the menu's own clicks must carry on regardless.
	process_mode = Node.PROCESS_MODE_ALWAYS
	for bus in [BUS_MUSIC, BUS_EFFECTS, BUS_AMBIENCE]:
		_ensure_bus(bus)
	_ocean = _one_shot("ocean_loop", BUS_AMBIENCE)
	_wind = _one_shot("wind_loop", BUS_AMBIENCE)
	_rain = _one_shot("rain_loop", BUS_AMBIENCE)
	_music = _one_shot("title_music", BUS_MUSIC)
	_music.process_mode = Node.PROCESS_MODE_ALWAYS
	_ui = _one_shot("ui_click", BUS_EFFECTS)
	_ui.process_mode = Node.PROCESS_MODE_ALWAYS
	_arrival = _one_shot("arrival", BUS_EFFECTS)
	_arrival.process_mode = Node.PROCESS_MODE_ALWAYS
	for index in 3:
		_paddles.append(load("res://assets/audio/paddle_%d.wav" % (index + 1)))
	_big_splash = load("res://assets/audio/splash_big.wav")
	for index in 6:
		var player := AudioStreamPlayer3D.new()
		player.bus = BUS_EFFECTS
		player.unit_size = 12.0
		player.max_distance = 160.0
		add_child(player)
		_splashes.append(player)
	# The beds start silent and fade to the weather, so the scene does not open with a thump.
	for bed in [_ocean, _wind, _rain, _music]:
		bed.volume_db = -60.0
		bed.play()
	if game.ocean != null:
		game.ocean.water_impacted.connect(_on_water_impacted)


## Stops every loop, so the audio server can release their playbacks before the game exits.
##
## A stream still playing at shutdown is held by the server's playback list until its next mix,
## which never comes once the engine is tearing down, and it is reported as a leak. Stopping
## here and letting a frame or two pass first — see [method VoyageGame._quit_game] — is what
## lets a quit end cleanly. Called from [method Node._exit_tree] as well, as a backstop.
func silence() -> void:
	for bed in [_ocean, _wind, _rain, _music]:
		if bed != null:
			bed.stop()
			bed.stream = null


func _exit_tree() -> void:
	silence()


func _process(delta: float) -> void:
	_impact_cooldown = maxf(0.0, _impact_cooldown - delta)
	_fade(_music, LEVELS["music"] if _music_wanted else -60.0, MUSIC_RESPONSE, delta)
	# While the world is paused the beds hold still rather than fading, as the sea does.
	if get_tree().paused:
		return
	var wind := 8.0
	if game.ocean != null and game.ocean.wave_field != null:
		wind = game.ocean.wave_field.wind_speed
	var rain := 0.0
	if game.weather != null and game.weather.current_preset() != null:
		rain = game.weather.current_preset().rain_intensity
	var gale := clampf(inverse_lerp(WIND_FLOOR, WIND_FULL, wind), 0.0, 1.0)
	_fade(_ocean, LEVELS["ocean"] + lerpf(-3.0, 3.0, gale), BED_RESPONSE, delta)
	_fade(_wind, _level(LEVELS["wind"], gale), BED_RESPONSE, delta)
	_fade(_rain, _level(LEVELS["rain"], rain), BED_RESPONSE, delta)
	_listen_to_raft()


## Plays the menus' click. Called by [GameMenu] for every button.
func play_ui() -> void:
	_ui.play()


## Plays the arrival sting, once per crossing.
func play_arrival() -> void:
	_arrival.play()


## Asks for the music to fade in or out. The menus want it; open water has the sea instead.
func set_music(wanted: bool) -> void:
	_music_wanted = wanted


## Hears every stroke and shove the raft replicates, including a crewmate's, as a splash at the
## raft. Counted from the serials rather than from a signal because the serials are what reach
## a client; the first reading only sets the baseline, so joining mid-voyage plays nothing.
func _listen_to_raft() -> void:
	var raft := game.raft
	if raft == null:
		return
	if _strokes_heard < 0:
		_strokes_heard = raft.stroke_serial
		_pushes_heard = raft.push_serial
		return
	if raft.stroke_serial != _strokes_heard:
		_strokes_heard = raft.stroke_serial
		_splash_at(raft.global_position, _paddles.pick_random(), LEVELS["paddle"],
			randf_range(0.9, 1.1))
	if raft.push_serial != _pushes_heard:
		_pushes_heard = raft.push_serial
		_splash_at(raft.global_position, _big_splash, LEVELS["paddle"], 0.8)


func _on_water_impacted(impact: WaterImpact) -> void:
	if impact == null or impact.energy < IMPACT_MIN_ENERGY or _impact_cooldown > 0.0:
		return
	if impact.kind == Ocean.ImpactKind.EXIT:
		return
	_impact_cooldown = IMPACT_COOLDOWN
	# Louder with energy, on a log scale because energy spans decades. The ends are measured: a
	# swimmer bobbing back in lands around 10^3.5 J, a player dropped 3 m into the sea 10^5.1 J.
	var loudness := clampf(inverse_lerp(3.5, 5.3, log(impact.energy) / log(10.0)), 0.0, 1.0)
	_splash_at(impact.position, _big_splash, LEVELS["splash"] + lerpf(-14.0, 0.0, loudness),
		randf_range(0.85, 1.05))


func _splash_at(where: Vector3, stream: AudioStream, level: float, pitch: float) -> void:
	var player := _splashes[_next_splash]
	_next_splash = (_next_splash + 1) % _splashes.size()
	player.stream = stream
	player.volume_db = level
	player.pitch_scale = pitch
	player.global_position = where
	player.play()


func _one_shot(sound: String, bus: StringName) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = sound.to_pascal_case()
	player.stream = load("res://assets/audio/%s.wav" % sound)
	player.bus = bus
	player.volume_db = LEVELS.get(sound.get_slice("_", 0), 0.0)
	add_child(player)
	return player


## Returns [param full] scaled by [param amount] in 0..1, as decibels, silent at zero.
func _level(full: float, amount: float) -> float:
	return full + linear_to_db(maxf(amount, 0.001))


func _fade(player: AudioStreamPlayer, target_db: float, response: float, delta: float) -> void:
	var weight := 1.0 - exp(-delta * 3.0 / response)
	player.volume_db = lerpf(player.volume_db, maxf(target_db, -60.0), weight)


static func _ensure_bus(bus: StringName) -> void:
	if AudioServer.get_bus_index(bus) != -1:
		return
	AudioServer.add_bus()
	var index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus)
	AudioServer.set_bus_send(index, &"Master")


## Sets a bus's level from a 0..1 slider, silent at zero.
static func set_bus_level(bus: StringName, amount: float) -> void:
	_ensure_bus(bus)
	var index := AudioServer.get_bus_index(bus)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(amount, 0.0001)))
	AudioServer.set_bus_mute(index, amount <= 0.001)
