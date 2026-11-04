"""Undoable orientation repair for previously created selected models."""
from core.history import Command
from core.group import Group
from .topology import orient_solids


class RepairFaces(Command):
    def __init__(self, states):
        self.states = states

    def do(self, scene):
        for mesh, before, after in self.states:
            mesh.restore_state(after)
        scene.version += 1

    def undo(self, scene):
        for mesh, before, after in self.states:
            mesh.restore_state(before)
        scene.version += 1


def repair_selected(app):
    meshes = {}
    def collect(group):
        meshes[id(group.mesh)] = group.mesh
        for child in group.children:
            collect(child)
    for item in app.scene.selection:
        if isinstance(item, Group):
            collect(item)
    states, count = [], 0
    for mesh in meshes.values():
        before = mesh.capture_state()
        changed = orient_solids(mesh)
        if changed:
            states.append((mesh, before, mesh.capture_state()))
            count += changed
        mesh.restore_state(before)
    if states:
        app.viewport.history.execute(RepairFaces(states))
        app.viewport.update()
        notify = getattr(app.viewport, 'notify_scene_changed', None)
        if callable(notify): notify()
    flash = getattr(app.viewport, 'flash_status', None)
    if callable(flash):
        flash(f'Repaired {count} reversed faces in closed solids.' if meshes else
              'Select a model or group to repair its face orientation.', 6000)
    return count
