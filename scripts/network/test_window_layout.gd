class_name TestWindowLayout
extends Object

## Places a debug instance's window so two of them sit side by side on one screen.
##
## Purely a development convenience for the two-window local test: with Debug > Customize Run
## Instances set to two, one instance is launched with [code]--server[/code] and the other with
## [code]--client[/code], and each positions itself from its own arguments. Without this both
## windows open in the same place and the top one has to be dragged off the other every run.
##
## Does nothing unless a role argument is present, so a normal launch, an export and a headless
## run are all unaffected.

## Fraction of the screen's working area each test window occupies horizontally.
const WINDOW_WIDTH_FRACTION: float = 0.5

## Fraction of the screen's working area each test window occupies vertically.
const WINDOW_HEIGHT_FRACTION: float = 0.86

## Inset from the screen edges, in pixels, so window borders are not clipped.
const SCREEN_MARGIN: int = 8


## Arranges this instance's window according to its launch role.
##
## [param role] is a [code]NetworkSession.Role[/code] value: the server takes the left half of
## the screen, a client the right. Any other role leaves the window alone.
##
## Typed as [int] rather than as the enum because [code]NetworkSession[/code] is an autoload
## rather than a global class, so its enum cannot be named in a static signature.
static func apply(role: int) -> void:
	if role == NetworkSession.Role.NONE:
		return
	if DisplayServer.get_name() == "headless":
		return

	var screen := DisplayServer.window_get_current_screen()
	# The usable area rather than the raw resolution, so the window is not placed under the
	# taskbar.
	var usable := DisplayServer.screen_get_usable_rect(screen)

	var width := int(usable.size.x * WINDOW_WIDTH_FRACTION) - SCREEN_MARGIN * 2
	var height := int(usable.size.y * WINDOW_HEIGHT_FRACTION)
	var top := usable.position.y + SCREEN_MARGIN
	var left := usable.position.x + SCREEN_MARGIN
	var is_client: bool = role == NetworkSession.Role.CLIENT
	if is_client:
		left = usable.position.x + int(usable.size.x * WINDOW_WIDTH_FRACTION) + SCREEN_MARGIN

	DisplayServer.window_set_size(Vector2i(width, height))
	DisplayServer.window_set_position(Vector2i(left, top))
	DisplayServer.window_set_title(
		"WaterEVERYWHERE — CLIENT" if is_client else "WaterEVERYWHERE — SERVER"
	)
