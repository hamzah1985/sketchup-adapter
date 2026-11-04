import unittest
from types import SimpleNamespace

from sketchup_adapter.surface_preflight import StaleSurfaceEdit, validate, validate_edge_transforms


class SurfacePreflightTests(unittest.TestCase):
    def setUp(self):
        self.a, self.b = object(), object()
        self.mesh = SimpleNamespace(faces=[self.a, self.b])
        self.scene = SimpleNamespace(loose_mesh=self.mesh, mesh=self.mesh, groups=[])
        self.targets = {'a': (self.mesh, self.a, None), 'b': (self.mesh, self.b, None)}
        self.erases = {'a': (self.mesh, self.a), 'b': (self.mesh, self.b)}

    def check_batch(self, batch):
        def placements(group):
            yield group, getattr(group, 'xform', None)
            for child in getattr(group, 'children', ()):
                yield from placements(child)
        return validate(batch, self.targets, self.erases, self.scene, placements)

    def test_distinct_live_faces_and_unrelated_upsert_pass(self):
        batch = [{'op':'surface_patch', 'token':'a', 'faces':[]},
                 {'op':'surface_patch', 'token':'b', 'faces':[]},
                 {'op':'upsert', 'rid':42, 'payload':{}}]
        self.assertEqual(batch, self.check_batch(batch))

    def test_obsolete_target_rejects_the_whole_mixed_batch(self):
        self.mesh.faces.remove(self.a)
        batch = [{'op':'upsert', 'rid':42, 'payload':{}},
                 {'op':'surface_patch', 'token':'a', 'faces':[]}]
        with self.assertRaises(StaleSurfaceEdit):
            self.check_batch(batch)
        self.assertEqual([self.b], self.mesh.faces)

    def test_missing_or_detached_mesh_and_stale_erase_rejected(self):
        with self.assertRaises(StaleSurfaceEdit):
            self.check_batch([{'op':'surface_patch', 'token':'missing', 'faces':[]}])
        self.scene.loose_mesh = self.scene.mesh = SimpleNamespace(faces=[])
        with self.assertRaises(StaleSurfaceEdit):
            self.check_batch([{'op':'face_erased', 'token':'a'}])

    def test_duplicate_and_alias_patches_are_rejected(self):
        patch = {'op':'surface_patch', 'token':'a', 'faces':[]}
        with self.assertRaises(StaleSurfaceEdit):
            self.check_batch([patch, patch.copy()])
        self.targets['alias'] = self.targets['a']
        with self.assertRaises(StaleSurfaceEdit):
            self.check_batch([patch, {'op':'surface_patch','token':'alias','faces':[]}])

    def test_uncopyable_face_metadata_rejects_the_whole_batch(self):
        class Uncopyable:
            def __deepcopy__(self, memo): raise TypeError('unsupported native value')
        face=SimpleNamespace(attrs={'user':Uncopyable()})
        self.mesh.faces.append(face)
        self.targets['unsafe']=(self.mesh,face,None)
        batch=[{'op':'upsert','rid':42,'payload':{}},
               {'op':'surface_patch','token':'unsafe','faces':[]}]
        with self.assertRaisesRegex(StaleSurfaceEdit,'cannot be safely copied'):
            self.check_batch(batch)
        self.erases['unsafe']=(self.mesh,face)
        with self.assertRaisesRegex(StaleSurfaceEdit,'cannot be safely copied'):
            self.check_batch([{'op':'face_erased','token':'unsafe'}])
        self.assertIn(face,self.mesh.faces)

    def test_erasure_of_the_patched_original_is_redundant(self):
        patch = {'op':'surface_patch', 'token':'a', 'faces':[[[], [], {}]]}
        erase = {'op':'face_erased', 'token':'a'}
        self.assertEqual([patch], self.check_batch([patch, erase]))
        self.assertEqual([patch], self.check_batch([erase, patch]))
        with self.assertRaises(StaleSurfaceEdit):
            self.check_batch([patch, erase, erase.copy()])

    def test_distinct_erasure_and_nested_live_owner(self):
        group_mesh = SimpleNamespace(faces=[self.a])
        self.scene.groups = [SimpleNamespace(mesh=None, children=[SimpleNamespace(mesh=group_mesh,children=[])])]
        self.targets['nested'] = (group_mesh, self.a, None)
        self.erases['nested'] = (group_mesh, self.a)
        batch = [{'op':'face_erased','token':'nested'}, {'op':'surface_patch','token':'b','faces':[]}]
        self.assertEqual(batch,self.check_batch(batch))

    def test_moved_or_shared_placement_is_rejected(self):
        class Matrix:
            def __init__(self, translation): self.translation = translation
            def data(self): return (1,0,0,0,0,1,0,0,0,0,1,0,self.translation,0,0,1)
            def isAffine(self): return True
            def inverted(self): return self, True
        group_mesh = SimpleNamespace(faces=[self.a])
        group = SimpleNamespace(mesh=group_mesh, children=[], xform=Matrix(2))
        self.scene.groups = [group]
        self.targets['nested'] = (group_mesh, self.a, Matrix(2))
        self.erases['nested'] = (group_mesh, self.a)
        patch = {'op':'surface_patch','token':'nested','faces':[]}
        self.assertEqual([patch],self.check_batch([patch]))
        group.xform = Matrix(3)
        with self.assertRaises(StaleSurfaceEdit): self.check_batch([patch])
        group.xform = Matrix(2)
        self.scene.groups.append(SimpleNamespace(mesh=group_mesh, children=[], xform=Matrix(2)))
        with self.assertRaises(StaleSurfaceEdit): self.check_batch([patch])

    def test_patch_transform_must_be_finite_affine_and_invertible(self):
        class Matrix:
            def __init__(self, values, affine=True, valid=True, inverse=None):
                self.values, self.affine, self.valid, self.inverse = values, affine, valid, inverse
            def data(self): return self.values
            def isAffine(self): return self.affine
            def inverted(self): return self.inverse or self, self.valid
        ident=(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1)
        mirrored=(-2,0,0,0,0,3,0,0,0,0,.5,0,4,5,6,1)
        mesh=SimpleNamespace(faces=[self.a])
        group=SimpleNamespace(mesh=mesh,children=[],xform=None)
        self.scene.groups=[group]
        patch={'op':'surface_patch','token':'nested','faces':[[[],[],{}]]}
        self.erases['nested']=(mesh,self.a)
        def check(matrix):
            group.xform=matrix;self.targets['nested']=(mesh,self.a,matrix)
            return self.check_batch([{'op':'upsert','rid':42,'payload':{}},patch])
        self.assertEqual(2,len(check(Matrix(mirrored))))
        for matrix in (Matrix(ident,valid=False), Matrix(ident,affine=False), Matrix((float('inf'),)+ident[1:]),
                       Matrix(ident,inverse=Matrix((float('inf'),)+ident[1:]))):
            with self.subTest(matrix=matrix), self.assertRaisesRegex(StaleSurfaceEdit,'transform'):
                check(matrix)
        self.assertEqual([self.a],mesh.faces)

    def test_edge_movement_requires_a_valid_affine_transform(self):
        class Matrix:
            def __init__(self, values, affine=True, valid=True, inverse=None):
                self.values,self.affine,self.valid,self.inverse=values,affine,valid,inverse
            def data(self): return self.values
            def isAffine(self): return self.affine
            def inverted(self): return self.inverse or self,self.valid
        ident=(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1)
        mirrored=(-2,0,0,0,0,3,0,0,0,0,.5,0,4,5,6,1)
        batch=[{'op':'upsert','rid':42,'payload':{}},
               {'op':'edge_patch','token':'e','points':[[0,0,0],[1,0,0]]}]
        self.assertEqual(batch,validate_edge_transforms(batch,{'e':(self.mesh,self.a,Matrix(mirrored))}))
        self.assertEqual(batch,validate_edge_transforms(batch,{'e':(self.mesh,self.a,None)}))
        for matrix in (Matrix(ident,valid=False),Matrix(ident,affine=False),
                       Matrix((float('inf'),)+ident[1:]),Matrix(ident,inverse=Matrix((float('inf'),)+ident[1:]))):
            with self.subTest(matrix=matrix), self.assertRaisesRegex(StaleSurfaceEdit,'edge owner.*transform'):
                validate_edge_transforms(batch,{'e':(self.mesh,self.a,matrix)})
        with self.assertRaisesRegex(StaleSurfaceEdit,'edge edit.*target'):
            validate_edge_transforms(batch,{})
        deletion=[{'op':'edge_patch','token':'e','points':None}]
        self.assertEqual(deletion,validate_edge_transforms(deletion,{'e':(self.mesh,self.a,Matrix(ident,valid=False))}))

    def test_edge_movement_rejects_malformed_and_nonfinite_endpoints(self):
        targets={'e':(self.mesh,self.a,None)}
        for points in ([],[[0,0,0]],[[0,0,0],[1,0]],[[0,0,0],[1,0,0,0]],
                       [[0,0,0],[float('nan'),0,0]],[[0,0,0],[float('inf'),0,0]],
                       [[0,0,0],[1e100,0,0]],[[0,0,0],[True,0,0]],[[0,0,0],['1',0,0]]):
            batch=[{'op':'upsert','rid':42,'payload':{}},{'op':'edge_patch','token':'e','points':points}]
            with self.subTest(points=points),self.assertRaisesRegex(StaleSurfaceEdit,'invalid endpoints'):
                validate_edge_transforms(batch,targets)

    def test_edge_movement_rejects_deleted_moved_and_shared_owners(self):
        class Matrix:
            def __init__(self, x): self.x=x
            def data(self): return (1,0,0,0,0,1,0,0,0,0,1,0,self.x,0,0,1)
            def isAffine(self): return True
            def inverted(self): return self,True
        edge=object(); mesh=SimpleNamespace(edges=[edge]); group=SimpleNamespace(mesh=mesh,xform=Matrix(2))
        scene=SimpleNamespace(loose_mesh=SimpleNamespace(edges=[]),groups=[group])
        placements=lambda g:[(g,g.xform)]
        targets={'e':(mesh,edge,Matrix(2))}
        batch=[{'op':'upsert','rid':42,'payload':{}},{'op':'edge_patch','token':'e','points':[[0,0,0],[1,0,0]]}]
        self.assertEqual(batch,validate_edge_transforms(batch,targets,scene,placements))
        mesh.edges.clear()
        with self.assertRaisesRegex(StaleSurfaceEdit,'edge or its owner'): validate_edge_transforms(batch,targets,scene,placements)
        mesh.edges.append(edge);group.xform=Matrix(3)
        with self.assertRaisesRegex(StaleSurfaceEdit,'edge or its owner'): validate_edge_transforms(batch,targets,scene,placements)
        group.xform=Matrix(2);scene.groups.append(SimpleNamespace(mesh=mesh,xform=Matrix(2)))
        with self.assertRaisesRegex(StaleSurfaceEdit,'edge or its owner'): validate_edge_transforms(batch,targets,scene,placements)
        scene.groups.clear()
        with self.assertRaisesRegex(StaleSurfaceEdit,'edge or its owner'): validate_edge_transforms(batch,targets,scene,placements)


if __name__ == '__main__':
    unittest.main()
