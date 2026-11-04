import importlib.util,unittest
from pathlib import Path
from types import SimpleNamespace
spec=importlib.util.spec_from_file_location('orientation_under_test',Path(__file__).resolve().parents[1]/'sketchup_adapter/topology.py')
orientation=importlib.util.module_from_spec(spec);spec.loader.exec_module(orientation)
class Point:
    def __init__(self,p):self.p=tuple(p)
    def toTuple(self):return self.p
class Face:
    def __init__(self,vertices):self.loop=vertices;self.hole_loops=[]
    def triangulate(self):
        return [(self.loop[0].position,self.loop[i].position,self.loop[i+1].position) for i in range(1,len(self.loop)-1)]
def box(lo,hi,reverse=False):
    a,b,c=lo;x,y,z=hi
    corners=[(a,b,c),(x,b,c),(x,y,c),(a,y,c),(a,b,z),(x,b,z),(x,y,z),(a,y,z)]
    vertices=[SimpleNamespace(position=Point(p)) for p in corners]
    rings=[(0,3,2,1),(4,5,6,7),(0,1,5,4),(2,3,7,6),(3,0,4,7),(1,2,6,5)]
    return [Face([vertices[i] for i in (ring[::-1] if reverse else ring)]) for ring in rings]
def volume(faces):
    result=0
    for face in faces:
        for points in face.triangulate():
            a,b,c=[p.toTuple() for p in points]
            result+=sum(a[k]*(b[(k+1)%3]*c[(k+2)%3]-b[(k+2)%3]*c[(k+1)%3]) for k in range(3))/6
    return result
class ShellOrientationTests(unittest.TestCase):
    def mesh(self,faces):return SimpleNamespace(faces=faces,_chunk_dirty=False)
    def test_a_closed_cavity_subtracts_its_volume_and_stays_idempotent(self):
        faces=box((0,0,0),(1,1,1))+box((.25,.25,.25),(.75,.75,.75))
        mesh=self.mesh(faces)
        self.assertEqual(6,orientation.orient_solids(mesh))
        self.assertAlmostEqual(.875,volume(faces))
        self.assertEqual(0,orientation.orient_solids(mesh))
    def test_three_nested_shells_alternate_cavity_and_island(self):
        faces=box((0,0,0),(4,4,4),True)+box((1,1,1),(3,3,3))+box((1.5,1.5,1.5),(2.5,2.5,2.5),True)
        orientation.orient_solids(self.mesh(faces))
        self.assertAlmostEqual(57,volume(faces))
    def test_disjoint_shells_keep_positive_volumes(self):
        # A tube-like enclosure of four closed bars has an empty centre.
        faces=box((0,0,0),(1,4,1),True)+box((3,0,0),(4,4,1))
        faces+=box((1,0,0),(3,1,1))+box((1,3,0),(3,4,1),True)
        faces+=box((1.5,1.5,.25),(2.5,2.5,.75),True)
        orientation.orient_solids(self.mesh(faces))
        self.assertAlmostEqual(12.5,volume(faces))
    def test_a_box_in_the_notch_of_one_concave_shell_is_not_a_cavity(self):
        ring=[(0,0),(4,0),(4,1),(1,1),(1,4),(0,4)]
        vertices=[SimpleNamespace(position=Point((x,y,z))) for z in [0,1] for x,y in ring]
        faces=[Face(vertices[:6][::-1]),Face(vertices[6:])]
        faces.extend(Face([vertices[i],vertices[(i+1)%6],vertices[(i+1)%6+6],vertices[i+6]]) for i in range(6))
        faces+=box((2,2,.25),(3,3,.75),True)
        orientation.orient_solids(self.mesh(faces))
        self.assertAlmostEqual(7.5,volume(faces))
    def test_open_surfaces_keep_their_original_winding(self):
        faces=box((0,0,0),(1,1,1),True)[:-1]
        before=[list(face.loop) for face in faces]
        self.assertEqual(0,orientation.orient_solids(self.mesh(faces)))
        self.assertEqual(before,[face.loop for face in faces])
    def test_an_inconsistent_closed_shell_is_repaired(self):
        faces=box((0,0,0),(2,3,4));faces[2].loop.reverse()
        orientation.orient_solids(self.mesh(faces))
        self.assertAlmostEqual(24,volume(faces))
    def test_many_disjoint_shells_remain_independent(self):
        faces=[]
        for i in range(300):faces+=box((0,0,i*2),(1,1,i*2+1),i%2==0)
        orientation.orient_solids(self.mesh(faces))
        self.assertAlmostEqual(300,volume(faces))
    def test_containment_candidates_include_all_nested_shells(self):
        faces=box((0,0,0),(10,10,10))+box((1,1,1),(9,9,9))+box((2,2,2),(8,8,8))
        orientation.orient_solids(self.mesh(faces))
        self.assertAlmostEqual(704,volume(faces))
if __name__=='__main__':unittest.main()
