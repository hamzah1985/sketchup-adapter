require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
class PushpullThroughContracts < Minitest::Test
 def setup
  Sketchup.reset_model!
  @e=Sketchup.active_model.entities.add_group.entities
 end
 def rect(z,x0=0,x1=10,y0=0,y1=10)
  [[x0,y0,z],[x1,y0,z],[x1,y1,z],[x0,y1,z]]
 end
 def setup_faces(already_split: true)
  near=@e.add_face(rect(0));far=@e.add_face(rect(-2))
  far_inner=@e.add_face(rect(-2,2,8,2,8)) if already_split
  near_inner=@e.add_face(rect(0,2,8,2,8))
  [near,far,near_inner,far_inner]
 end
 def degenerate_faces
  @e.faces.select do |f|
   outer=f.outer_loop.points
   f.loops.drop(1).any? do |hole|
    ring=hole.points
    outer.length==ring.length && outer.all? { |p| ring.any? { |q| p==q } }
   end
  end
 end
 def test_existing_opposite_split_removes_inner_face_without_ghost
  near,far,inner,far_inner=setup_faces
  assert_equal far,far_inner.parent_face
  inner.pushpull(2)
  refute far_inner.valid?
  assert_equal 2,far.loops.length
  assert_empty degenerate_faces
  assert_equal 6,@e.faces.length
 end
 def test_opposite_unholed_face_gets_through_hole
  near,far,inner,_=setup_faces(already_split:false)
  inner.pushpull(2)
  assert_equal 2,far.loops.length
  assert_empty degenerate_faces
  assert_equal 6,@e.faces.length
 end
 def test_partial_depth_preserves_opposite_inner_face
  near,far,inner,far_inner=setup_faces
  inner.pushpull(1)
  assert far_inner.valid?
  assert_equal 2,far.loops.length
  assert_empty degenerate_faces
  cap=@e.faces.find { |f| f.outer_loop.points.all? { |p| (p.z+1).abs<1e-7 } }
  refute_nil cap
 end
 def test_hole_in_extruded_profile_preserves_far_island
  near,far,inner,far_inner=setup_faces
  inner.add_hole([[4,4,0],[6,4,0],[6,6,0],[4,6,0]].map { |p| @e.vertex(Geom::Point3d.new(p)) })
  inner.pushpull(2)
  refute far_inner.valid?
  island=@e.faces.find { |f| f.outer_loop.points.all? { |p| (p.z+2).abs<1e-7 } && (f.area-4).abs<1e-7 }
  refute_nil island
  assert_empty degenerate_faces
 end
 def cube_group(reverse: false, transform: nil)
  group=Sketchup.active_model.entities.add_group
  group.transformation=transform if transform
  rings=[[[0,0,0],[10,0,0],[10,0,10],[0,0,10]],
         [[0,2,0],[0,2,10],[10,2,10],[10,2,0]],
         [[0,0,0],[0,0,10],[0,2,10],[0,2,0]],
         [[10,0,0],[10,2,0],[10,2,10],[10,0,10]],
         [[0,0,10],[10,0,10],[10,2,10],[0,2,10]],
         [[0,0,0],[0,2,0],[10,2,0],[10,0,0]]]
  rings.each { |ring| f=group.entities.add_face(ring);f.reverse! if reverse }
  group
 end
 def test_closed_solid_through_cut_volume_and_orientation_both_parent_windings
  [false,true].each do |reversed|
   g=cube_group(reverse:reversed)
   far=g.entities.add_face([[2,2,2],[8,2,2],[8,2,8],[2,2,8]])
   inner=g.entities.add_face([[2,0,2],[8,0,2],[8,0,8],[2,0,8]])
   distance=Geom::Vector3d.new(0,2,0).dot(inner.normal)
   inner.pushpull(distance)
   assert g.manifold?,"nonmanifold, reversed=#{reversed}"
   assert_in_delta 128,g.volume,1e-5,"incorrect volume, reversed=#{reversed}"
   refute far.valid?
  end
 end
 def test_partial_depth_cut_produces_expected_closed_volume
  g=cube_group
  inner=g.entities.add_face([[2,0,2],[8,0,2],[8,0,8],[2,0,8]])
  inner.pushpull(Geom::Vector3d.new(0,1,0).dot(inner.normal))
  assert g.manifold?
  assert_in_delta 164,g.volume,1e-5
 end
 def test_outward_extrusion_produces_expected_closed_volume
  g=cube_group
  inner=g.entities.add_face([[2,0,2],[8,0,2],[8,0,8],[2,0,8]])
  inner.pushpull(Geom::Vector3d.new(0,-2,0).dot(inner.normal))
  assert g.manifold?
  assert_in_delta 272,g.volume,1e-5
 end
 def test_mirrored_nonuniform_container_through_cut_volume
  g=cube_group(transform:Geom::Transformation.scaling(-1,2,3))
  g.entities.add_face([[2,2,2],[8,2,2],[8,2,8],[2,2,8]])
  inner=g.entities.add_face([[2,0,2],[8,0,2],[8,0,8],[2,0,8]])
  inner.pushpull(Geom::Vector3d.new(0,2,0).dot(inner.normal))
  assert g.manifold?
  assert_in_delta 768,g.volume,1e-5
 end

 def face_signature
  @e.faces.select(&:valid?).map { |f| f.loops.map { |l| l.points.map(&:to_a) } }.sort_by(&:inspect)
 end
 def test_ambiguous_target_with_own_hole_rejects_without_partial_geometry
  near,far,inner,far_inner=setup_faces
  far_inner.add_hole([[4,4,-2],[6,4,-2],[6,6,-2],[4,6,-2]].map { |p| @e.vertex(Geom::Point3d.new(p)) })
  before=face_signature
  assert_raises(ArgumentError) { inner.pushpull(2) }
  assert_equal before,face_signature
  assert inner.valid?;assert far_inner.valid?
 end
 def test_other_parent_holes_and_parent_properties_are_preserved
  near,far,inner,far_inner=setup_faces
  material=Sketchup.active_model.materials.add('Keep Parent')
  far.material=material;far.set_attribute('QA','keep','parent value')
  far_inner.set_attribute('QA','remove','inner face')
  extra=@e.add_face(rect(-2,8.5,9.5,8.5,9.5));assert_equal far,extra.parent_face
  extra.erase!
  assert_equal 3,far.loops.length
  inner.pushpull(2)
  refute far_inner.valid?
  assert_same material,far.material
  assert_equal 'parent value',far.get_attribute('QA','keep')
  assert_equal 3,far.loops.length
  assert_empty degenerate_faces
 end
 def test_boundary_cycle_accepts_rotation_and_reversal_but_rejects_ambiguous_repeat
  probe=@e.add_face(rect(0))
  points=rect(0).map { |p| Geom::Point3d.new(p) }
  assert probe.send(:same_boundary_cycle?,points,points.rotate(2))
  assert probe.send(:same_boundary_cycle?,points,points.reverse.rotate(1))
  refute probe.send(:same_boundary_cycle?,points,points.dup.tap { |x| x[2]=Geom::Point3d.new(50,50,0) })
  assert_raises(ArgumentError) { probe.send(:same_boundary_cycle?,points,[points[0],points[1],points[0],points[3]]) }
 end

 def test_coincident_boundary_with_extra_collinear_vertex_is_rejected_atomically
  near=@e.add_face(rect(0));far=@e.add_face(rect(-2))
  far_inner=@e.add_face([[2,2,-2],[5,2,-2],[8,2,-2],[8,8,-2],[2,8,-2]])
  inner=@e.add_face(rect(0,2,8,2,8));before=face_signature
  assert_raises(ArgumentError) { inner.pushpull(2) }
  assert_equal before,face_signature
  assert far_inner.valid?;assert inner.valid?
 end
 def test_parent_front_back_materials_and_uv_survive_cut
  near,far,inner,far_inner=setup_faces
  front=Sketchup.active_model.materials.add('Front QA')
  back=Sketchup.active_model.materials.add('Back QA')
  far.material=front;far.back_material=back
  front_uv=[[0,0,-2],[0,0,1],[10,0,-2],[1,0,1],[0,10,-2],[0,1,1]].map { |p| Geom::Point3d.new(p) }
  back_uv=[[0,0,-2],[1,1,1],[10,0,-2],[2,1,1],[0,10,-2],[1,2,1]].map { |p| Geom::Point3d.new(p) }
  far.uv_mapping=front_uv;far.uv_mapping_back=back_uv
  inner.pushpull(2)
  assert_same front,far.material;assert_same back,far.back_material
  assert_equal front_uv.map(&:to_a),far.uv_mapping.map(&:to_a)
  assert_equal back_uv.map(&:to_a),far.uv_mapping_back.map(&:to_a)
  refute far_inner.valid?
 end

 def test_same_count_but_differently_split_boundaries_reject_atomically
  near=@e.add_face(rect(0));far=@e.add_face(rect(-2))
  far_inner=@e.add_face([[2,2,-2],[5,2,-2],[8,2,-2],[8,8,-2],[2,8,-2]])
  inner=@e.add_face([[2,2,0],[4,2,0],[8,2,0],[8,8,0],[2,8,0]])
  before=face_signature
  assert_raises(ArgumentError) { inner.pushpull(2) }
  assert_equal before,face_signature
  assert far_inner.valid?;assert inner.valid?
 end

 def test_near_coincident_boundary_rejected_before_mutating_solid
  g=cube_group;e=g.entities
  far=e.add_face([[2,2,2],[5,2,2],[8,2,2],[8,2,8],[2,2,8]])
  inner=e.add_face([[2,0,2],[5,0,2.0015],[8,0,2],[8,0,8],[2,0,8]])
  before=e.faces.map { |f| f.loops.map { |l| l.points.map(&:to_a) } }.sort_by(&:inspect)
  assert g.manifold?
  assert_raises(ArgumentError) { inner.pushpull(Geom::Vector3d.new(0,2,0).dot(inner.normal)) }
  after=e.faces.map { |f| f.loops.map { |l| l.points.map(&:to_a) } }.sort_by(&:inspect)
  assert_equal before,after
  assert g.manifold?;assert far.valid?;assert inner.valid?
 end

 def test_dense_curved_ring_is_not_misclassified_as_degenerate
  square=lambda { |z| [[-2000,-2000,z],[2000,-2000,z],[2000,2000,z],[-2000,2000,z]] }
  @e.add_face(square.call(0));@e.add_face(square.call(-2))
  ring=lambda { |z| Array.new(2500) { |i| a=2*Math::PI*i/2500;[1000*Math.cos(a),1000*Math.sin(a),z] } }
  far_inner=@e.add_face(ring.call(-2));near_inner=@e.add_face(ring.call(0))
  near_inner.pushpull(2)
  refute far_inner.valid?
  assert_equal 2502,@e.faces.length
 end

 def test_two_disjoint_through_openings_preserve_closed_volume
  g=cube_group;e=g.entities
  first=e.add_face([[1,0,2],[3,0,2],[3,0,8],[1,0,8]])
  first.pushpull(Geom::Vector3d.new(0,2,0).dot(first.normal))
  assert g.manifold?;assert_in_delta 176,g.volume,1e-5
  second=e.add_face([[6,0,2],[8,0,2],[8,0,8],[6,0,8]])
  second.pushpull(Geom::Vector3d.new(0,2,0).dot(second.normal))
  assert g.manifold?;assert_in_delta 152,g.volume,1e-5
 end
 def test_concave_through_target_with_crossing_cap_is_rejected_before_mutation
  e=@e
  e.add_face([[0,0,0],[10,0,0],[10,0,10],[0,0,10]])
  e.add_face([[0,2,0],[10,2,0],[10,2,4],[4,2,4],[4,2,10],[0,2,10]])
  inner=e.add_face([[2,0,8],[8,0,2],[2,0,2]])
  before=face_signature
  assert_raises(ArgumentError) { inner.pushpull(Geom::Vector3d.new(0,2,0).dot(inner.normal)) }
  assert_equal before,face_signature
  assert inner.valid?
 end
 def test_existing_holes_must_be_disjoint_from_new_cap
  face=@e.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
  face.add_hole([[2,2,0],[4,2,0],[4,8,0],[2,8,0]].map { |p| @e.vertex(Geom::Point3d.new(p)) })
  disjoint=[[6,2,0],[8,2,0],[8,8,0],[6,8,0]].map { |p| Geom::Point3d.new(p) }
  crosses=[[1,4,0],[5,4,0],[5,6,0],[1,6,0]].map { |p| Geom::Point3d.new(p) }
  encloses=[[1,1,0],[5,1,0],[5,9,0],[1,9,0]].map { |p| Geom::Point3d.new(p) }
  assert face.send(:safe_pushpull_target?,face,disjoint)
  refute face.send(:safe_pushpull_target?,face,crosses)
  refute face.send(:safe_pushpull_target?,face,encloses)
 end

 def group_faces_signature(ents)
  ents.faces.select(&:valid?).map { |f| f.loops.map { |l| l.points.map(&:to_a) } }.sort_by(&:inspect)
 end
 def test_existing_open_far_hole_is_rejected_without_partial_geometry
  g=cube_group;e=g.entities
  far=e.add_face([[2,2,2],[8,2,2],[8,2,8],[2,2,8]]);far.erase!
  near=e.add_face([[2,0,2],[8,0,2],[8,0,8],[2,0,8]])
  before=group_faces_signature(e)
  assert_raises(ArgumentError) { near.pushpull(Geom::Vector3d.new(0,2,0).dot(near.normal)) }
  assert_equal before,group_faces_signature(e);assert near.valid?
 end
 def test_overlapping_existing_far_hole_is_rejected_without_partial_geometry
  g=cube_group;e=g.entities
  far=e.add_face([[2,2,2],[5,2,2],[5,2,8],[2,2,8]]);far.erase!
  near=e.add_face([[4,0,2],[8,0,2],[8,0,8],[4,0,8]])
  before=group_faces_signature(e)
  assert_raises(ArgumentError) { near.pushpull(Geom::Vector3d.new(0,2,0).dot(near.normal)) }
  assert_equal before,group_faces_signature(e);assert near.valid?
 end
 def test_far_split_seam_is_rejected_without_partial_geometry
  g=Sketchup.active_model.entities.add_group;e=g.entities
  rings=[[[0,0,0],[10,0,0],[10,0,10],[0,0,10]],[[0,2,0],[0,2,10],[5,2,10],[5,2,0]],[[5,2,0],[5,2,10],[10,2,10],[10,2,0]],[[0,0,0],[0,0,10],[0,2,10],[0,2,0]],[[10,0,0],[10,2,0],[10,2,10],[10,0,10]],[[0,0,10],[10,0,10],[10,2,10],[5,2,10],[0,2,10]],[[0,0,0],[0,2,0],[5,2,0],[10,2,0],[10,0,0]]]
  rings.each { |ring| e.add_face(ring) }
  inner=e.add_face([[2,0,2],[8,0,2],[8,0,8],[2,0,8]])
  before=group_faces_signature(e);assert g.manifold?
  assert_raises(ArgumentError) { inner.pushpull(Geom::Vector3d.new(0,2,0).dot(inner.normal)) }
  assert_equal before,group_faces_signature(e);assert g.manifold?
 end
 def test_repeated_nonaligned_vertex_rejected_without_geometry_changes
  points=[[0,0,0],[10,0,0],[10,10,0],[10,0,0],[0,10,0]].map { |p| Geom::Point3d.new(p) }
  face=@e.add_face_raw(points);refute_nil face
  before=face_signature
  assert_raises(ArgumentError) { face.pushpull(1) }
  assert_equal before,face_signature;assert face.valid?
 end

end
