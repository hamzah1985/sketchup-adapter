import copy
import unittest
from sketchup_adapter.surface_paint import local_uvw, merge_attrs, validate_geometry_batch


class SurfacePaintTest(unittest.TestCase):
    def test_malformed_face_geometry_rejected_before_commit(self):
        valid=[[[0,0,0],[1,0,0],[0,1,0]],[],{}]
        validate_geometry_batch([{'op':'surface_patch','faces':[valid]}])
        validate_geometry_batch([{'op':'surface_patch','faces':[]}])
        bad=[[[[0,0,0],[1,0,0],[0,1,float('nan')]],[],{}],
             [[[0,0,0],[1,0,0],[0,1,10**400]],[],{}],
             [[[0,0,0],[1,0,0]],[],{}],
             [[[0,0,0],[1,0,0],[0,1,0]],'invalid',{}]]
        for face in bad:
            with self.subTest(face=str(face)[:60]),self.assertRaises(ValueError):
                validate_geometry_batch([{'op':'surface_patch','faces':[face]}])

    def test_composes_world_uv_with_affine_owner(self):
        uvw = [2, -3, .5, 7, -1, 4, 2, -9]
        # Translation, rotation, reflection and nonuniform scaling together.
        basis = [[5, -2, 3], [0, -2, 0], [-3, 0, 0], [0, 0, .5]]
        local = local_uvw(uvw, basis)
        for xyz in ([0,0,0], [1,2,3], [-4,.5,7]):
            world = [basis[0][j] + sum(xyz[i]*basis[i+1][j] for i in range(3)) for j in range(3)]
            expected = [sum(uvw[n+j]*world[j] for j in range(3))+uvw[n+3] for n in (0,4)]
            actual = [sum(local[n+j]*xyz[j] for j in range(3))+local[n+3] for n in (0,4)]
            self.assertEqual(expected, actual)

    def test_replaces_only_explicit_side_and_deep_copies(self):
        basis = [[0,0,0],[1,0,0],[0,1,0],[0,0,1]]
        orig = {'mat':'old','color':[1,0,0], 'custom':{'x':[1]},
                'texture':{'path':'front','uvw':[1,0,0,0,0,1,0,0]},
                'back':{'mat':'back','texture':{'path':'back','uvw':[2,0,0,0,0,2,0,0]},'custom':{'deep':[7]}}}
        old = copy.deepcopy(orig)
        merged = merge_attrs(orig, {'front':{'value':None}}, basis)
        self.assertNotIn('mat', merged)
        self.assertNotIn('texture', merged)
        self.assertEqual(old['back'], merged['back'])
        merged['custom']['x'].append(2)
        self.assertEqual(old, orig)
        back_cleared = merge_attrs(orig, {'back':{'value':None}}, basis)
        self.assertEqual({'custom':{'deep':[7]}}, back_cleared['back'])
        back_cleared['back']['custom']['deep'].append(8)
        self.assertEqual([7],orig['back']['custom']['deep'])
        self.assertEqual(orig['texture'], back_cleared['texture'])

    def test_missing_invalid_uvw_fails(self):
        basis = [[0,0,0],[1,0,0],[0,1,0],[0,0,1]]
        with self.assertRaises(ValueError):
            merge_attrs({}, {'front':{'value':{'texture':{'path':'x'}}}}, basis)
        with self.assertRaises(ValueError):
            local_uvw([float('nan')]*8, basis)

if __name__ == '__main__': unittest.main()
