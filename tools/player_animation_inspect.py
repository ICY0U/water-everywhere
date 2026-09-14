import bpy, json
from pathlib import Path

source = Path(r'D:\Documents\Models\Blender\WaterEVERYWHEREplayerMODEL\output\player_clean\Kotarou_Player.blend')
bpy.ops.wm.open_mainfile(filepath=str(source))
rig = bpy.data.objects['Kotarou_Rig']
report = {
    'blender': bpy.app.version_string,
    'rig_matrix': [list(row) for row in rig.matrix_world],
    'bones': {b.name: {'parent': b.parent.name if b.parent else None, 'head': list(b.head_local), 'tail': list(b.tail_local), 'matrix': [list(r) for r in b.matrix_local]} for b in rig.data.bones},
    'actions': [{'name': a.name, 'range': list(a.frame_range)} for a in bpy.data.actions],
    'objects': [{'name': o.name, 'type': o.type} for o in bpy.data.objects],
}
report['samples'] = {}
for action in bpy.data.actions:
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    bpy.context.scene.frame_set(0)
    report['samples'][action.name] = {b.name: [list(r) for r in b.matrix] for b in rig.pose.bones}
library = source.parents[2] / 'Universal Animation Library[Source]/Godot/AnimationLibrary.blend'
with bpy.data.libraries.load(str(library)) as (data_from, data_to):
    report['library_actions'] = list(data_from.actions)
out = Path.cwd() / 'artifacts/player_animations'
out.mkdir(parents=True, exist_ok=True)
(out / 'source_inspection.json').write_text(json.dumps(report, indent=2))
print('RIG_INSPECTION', json.dumps({'blender': report['blender'], 'actions': report['actions'], 'bones': list(report['bones'])}))
print('LIBRARY_ACTIONS', report['library_actions'])
