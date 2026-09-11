class_name WaterContact
extends RefCounted

## A snapshot of something continuously present in the water.
##
## Returned by [method Ocean.get_active_contacts]. This is the polled counterpart to
## [WaterImpact]: bow spray, hull churn and wake foam all depend on a body's ongoing state
## rather than on an instant, and polling them on the render clock avoids the strobing that
## comes of consuming physics-clock events on a frame that physics did not step.
##
## Snapshots are copies. Holding one will not see it change underneath, and mutating one
## affects nothing.

## Where the body meets the surface, in world space.
var position: Vector3 = Vector3.ZERO

## Horizontal half-extent of the body at the waterline, in metres.
var waterline_radius: float = 0.0

## Body velocity relative to the water around it, in metres per second.
var relative_velocity: Vector3 = Vector3.ZERO

## How much of the body is under water, from 0 to 1.
var submersion: float = 0.0

## The node in the water.
var source: Node3D = null
