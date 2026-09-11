class_name WaterImpact
extends RefCounted

## One discrete moment of something striking, entering or leaving the water.
##
## Emitted by [signal Ocean.water_impacted]. This is the event channel — the things that
## happen at an instant and are gone. Continuous presence in the water is a different shape
## of data and is read from [method Ocean.get_active_contacts] instead, because an effect
## driven by a per-frame signal would have to filter out the frames it did not care about.
##
## The payload is deliberately everything an effect needs to place itself without asking the
## body any follow-up questions: a splash needs to know not just how fast the impact was but
## which way the water is being thrown, and how wide the thing making it is.

## Where the impact met the surface, in world space.
var position: Vector3 = Vector3.ZERO

## Unit surface normal at [member position].
var normal: Vector3 = Vector3.UP

## Closing speed along [member normal], in metres per second. Never negative.
var impact_speed: float = 0.0

## Body velocity relative to the water it hit, in metres per second.
##
## The full vector rather than a magnitude: a splash is thrown ALONG this, and a glancing
## entry throws water very differently from a vertical one even at the same speed.
var relative_velocity: Vector3 = Vector3.ZERO

## Horizontal half-extent of the source at the waterline, in metres.
##
## Sets how wide the disturbance is. Volume alone cannot distinguish a dropped plate from a
## dropped pole.
var waterline_radius: float = 0.0

## Volume of water the event disturbs, in cubic metres.
var volume: float = 0.0

## Momentum transferred into the surface, in newton-seconds.
##
## Effects should scale broad displacement from this value rather than directly from speed:
## a fast pebble and a slow hull can have the same speed while moving radically different
## amounts of water.
var impulse: float = 0.0

## Kinetic energy available to become spray, foam and capillary waves, in joules.
##
## This is deliberately separate from [member impulse]. Impulse controls how wide and strong
## the displacement is; energy controls how violently it atomises into droplets.
var energy: float = 0.0

## Stable random seed chosen by the authority and copied to every peer.
##
## Particle placement is cosmetic and simulated locally, but using the same seed makes the
## silhouette and burst character agree across machines and recordings.
var seed: int = 0

## What kind of event this is. See [enum Ocean.ImpactKind].
var kind: Ocean.ImpactKind = Ocean.ImpactKind.ENTRY

## The node that caused the impact.
var source: Node3D = null
