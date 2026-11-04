require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  def self.notify(*); end
  def self.call(*); raise 'Unexpected host service in local topology test'; end
end
class TopologyTest < Minitest::Test
  def setup
    Sketchup.reset_model!
    @entities=Sketchup.active_model.entities
    @identity=Geom::Transformation.new
  end
  def test_crossing_faces_split_both_sides_and_share_topology
    @entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    @entities.add_face([[5,0,-5],[5,10,-5],[5,10,5],[5,0,5]])
    edges=@entities.intersect_with(false,@identity,@entities,@identity,true,@entities.to_a)
    assert_equal 4,@entities.faces.length
    assert_equal 1,edges.length
    assert_equal 4,edges.first.faces.length
    assert_in_delta 200,@entities.faces.sum(&:area),1e-7
    assert_empty @entities.intersect_with(false,@identity,@entities,@identity,true,[])
  end
  def test_corner_wires_partition_an_annulus_without_overlapping_faces
    face=@entities.add_face([[-1,-1,0],[11,-1,0],[11,9,0],[-1,9,0]])
    @entities.add_face([[0,0,0],[10,0,0],[10,8,0],[0,8,0]]).erase!
    [[[-1,-1,0],[0,0,0]],[[11,-1,0],[10,0,0]],[[11,9,0],[10,8,0]],[[-1,9,0],[0,8,0]]].each do |a,b|
      @entities.add_line(a,b)
    end
    assert_equal 4,@entities.faces.length
    assert_equal [9.0,9.0,11.0,11.0],@entities.faces.map(&:area).sort
    assert @entities.faces.all? { |f| f.loops.length==1 }
    assert_in_delta 40,@entities.faces.sum(&:area),1e-7
    assert_equal 4,@entities.edges.count { |e| e.faces.length==2 }
  end
  def test_partition_preserves_an_unconnected_hole
    face=@entities.add_face([[0,0,0],[20,0,0],[20,10,0],[0,10,0]])
    [[2,4],[10,12]].each { |a,b| @entities.add_face([[a,2,0],[b,2,0],[b,4,0],[a,4,0]]).erase! }
    @entities.add_line([0,0,0],[2,2,0])
    @entities.add_line([0,10,0],[2,4,0])
    assert_equal 2,@entities.faces.length
    assert_in_delta 192,@entities.faces.sum(&:area),1e-7
    assert_equal 1,@entities.faces.sum { |f| f.loops.length-1 }
  end
  def test_two_crossing_wires_subdivide_face_into_four_regions
    @entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    @entities.add_line([0,0,0],[10,10,0])
    @entities.add_line([10,0,0],[0,10,0])
    assert_equal 4,@entities.faces.length
    assert_in_delta 100,@entities.faces.sum(&:area),1e-7
    center=@entities.find_vertex(Geom::Point3d.new(5,5,0))
    assert_equal 4,center.faces.length
  end
  def test_add_face_partitions_an_existing_convex_face_along_boundary_chords
    original=@entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    material=Sketchup.active_model.materials.add('surface-test');original.material=material
    original.layer='test-layer';original.hidden=true;original.casts_shadows=false;original.set_attribute('QA','test',42)
    first=@entities.add_face([[0,0,0],[10,0,0],[0,10,0]])
    assert_equal 2,@entities.faces.length
    assert_in_delta 100,@entities.faces.sum(&:area),1e-8
    assert_in_delta 50,first.area,1e-8
    assert @entities.faces.all? { |f| f.material==material }
    assert @entities.faces.all? { |f| f.layer.name=='test-layer' && f.hidden? && !f.casts_shadows? && f.get_attribute('QA','test')==42 }
    diagonal=@entities.edges.find { |e| e.faces.length==2 }
    refute_nil diagonal
    second=@entities.add_face([[10,0,0],[10,10,0],[0,10,0]])
    assert_equal 2,@entities.faces.length
    assert_in_delta 50,second.area,1e-8
    assert_equal 2,diagonal.faces.length
  end
  def test_face_partition_leaves_an_unrelated_holed_surface_untouched
    @entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    other=@entities.add_face([[20,0,0],[30,0,0],[30,10,0],[20,10,0]])
    @entities.add_face([[22,2,0],[24,2,0],[24,4,0],[22,4,0]]).erase!
    assert_equal 2,other.loops.length
    @entities.add_face([[0,0,0],[10,0,0],[0,10,0]])
    assert other.valid?
    assert_equal 2,other.loops.length
    assert_equal 3,@entities.faces.length
    assert_in_delta 196,@entities.faces.sum(&:area),1e-8
  end
  def test_face_partition_preserves_a_hole_in_the_other_fragment
    original=@entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    @entities.add_face([[7,7,0],[9,7,0],[9,9,0],[7,9,0]]).erase!
    assert_equal 2,original.loops.length
    triangle=@entities.add_face([[0,0,0],[10,0,0],[0,10,0]])
    assert_equal 2,@entities.faces.length
    assert_in_delta 96,@entities.faces.sum(&:area),1e-8
    assert_in_delta 50,triangle.area,1e-8
    assert_equal 1,@entities.faces.sum { |f| f.loops.length-1 }
  end
  def test_partition_accepts_an_existing_unconnected_vertex_on_a_boundary
    @entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    other=@entities.add_face_raw([[5,0,0],[5,0,-1],[5,-1,0]].map { |p| Geom::Point3d.new(p) })
    triangle=@entities.add_face([[5,0,0],[10,10,0],[0,10,0]])
    assert other.valid?
    assert_in_delta 50,triangle.area,1e-8
    assert_equal 4,@entities.faces.length
    assert_in_delta 100.5,@entities.faces.sum(&:area),1e-8
  end
  def test_grid_cuts_do_not_enumerate_exponentially_many_wire_paths
    @entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    (1...10).each { |i| @entities.add_line([0,i,0],[10,i,0]) }
    (1...10).each { |i| @entities.add_line([i,0,0],[i,10,0]) }
    assert_equal 100,@entities.faces.length
    assert_in_delta 100,@entities.faces.sum(&:area),1e-7
    assert_equal 180,@entities.edges.count { |edge| edge.faces.length==2 }
  end
  def test_common_space_transforms_and_finite_cut_do_not_modify_inputs
    source=@entities.add_group; cutter=@entities.add_group; result=@entities.add_group
    source.entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    cutter.entities.add_face([[15,2,-5],[15,8,-5],[15,8,5],[15,2,5]])
    translation=Geom::Transformation.new([10,0,0])
    output=source.entities.intersect_with(false,translation,result.entities,translation,true,cutter)
    assert_equal 1,output.length
    assert_equal [[5.0,2.0,0.0],[5.0,8.0,0.0]],output.first.vertices.map { |v| v.position.to_a }.sort
    assert_equal 1,source.entities.faces.length
    assert_equal 1,cutter.entities.faces.length
  end
  def test_hole_limits_intersection_to_two_finite_segments
    receiver=@entities.add_group; cutter=@entities.add_group; output=@entities.add_group
    face=receiver.entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    face.add_hole([[4,4,0],[6,4,0],[6,6,0],[4,6,0]].map { |p| receiver.entities.vertex(p) })
    cutter.entities.add_face([[5,-1,-1],[5,11,-1],[5,11,1],[5,-1,1]])
    edges=receiver.entities.intersect_with(false,@identity,output.entities,@identity,true,cutter)
    assert_equal [4.0,4.0],edges.map(&:length).sort
  end
  def test_coplanar_finite_edges_respect_holes_and_their_boundaries
    receiver=@entities.add_group; cutter=@entities.add_group; output=@entities.add_group
    face=receiver.entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    face.add_hole([[4,4,0],[6,4,0],[6,6,0],[4,6,0]].map { |p| receiver.entities.vertex(p) })
    cutter.entities.add_line([1,5,0],[9,5,0])
    edges=receiver.entities.intersect_with(false,@identity,output.entities,@identity,true,cutter)
    assert_equal [3.0,3.0],edges.map(&:length).sort
    inside=@entities.add_group
    inside.entities.add_line([4.5,5,0],[5.5,5,0])
    assert_empty receiver.entities.intersect_with(false,@identity,output.entities,@identity,true,inside)
    border=@entities.add_group
    border.entities.add_line([4,4,0],[6,4,0])
    result=receiver.entities.intersect_with(false,@identity,output.entities,@identity,true,border)
    assert_equal [2.0],result.map(&:length)
  end
  def test_closed_internal_cuts_create_removable_faces_and_extrudable_holes
    group=@entities.add_group;cutter=@entities.add_group
    face=group.entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    [[2,4],[6,8]].each do |a,b|
      cutter.entities.add_face([[a,2,0],[b,2,0],[b,4,0],[a,4,0]])
    end
    group.entities.intersect_with(false,@identity,group.entities,@identity,true,cutter)
    assert_equal 3,group.entities.faces.length
    assert_equal 3,face.loops.length
    assert_in_delta 92,face.area,1e-7
    (group.entities.faces-[face]).each(&:erase!)
    face.pushpull(-2)
    assert group.manifold?
    assert_in_delta 184,group.volume,1e-7
  end
  def test_recursive_self_intersection_does_not_copy_child_boundaries_into_parent
    parent=@entities.add_group
    child=parent.entities.add_group
    child.entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]]).pushpull(-5)
    edges=parent.entities.intersect_with(true,@identity,parent.entities,@identity,true,parent)
    assert_empty edges
    assert_empty parent.entities.faces
    assert_equal 6,child.entities.faces.length
  end
  def test_hidden_faces_and_recursion
    group=@entities.add_group
    face=group.entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    face.hidden=true
    cutter=@entities.add_group
    cutter.entities.add_face([[5,-1,-1],[5,11,-1],[5,11,1],[5,-1,1]])
    output=@entities.add_group
    assert_empty @entities.intersect_with(false,@identity,output.entities,@identity,true,cutter)
    assert_empty group.entities.intersect_with(false,@identity,output.entities,@identity,false,cutter)
    assert_equal 1,group.entities.intersect_with(false,@identity,output.entities,@identity,true,cutter).length
  end
  def test_find_faces_and_connectivity_exclude_unrelated_geometry
    square=@entities.add_edges([[0,0,0],[10,0,0],[10,10,0],[0,10,0],[0,0,0]])
    unrelated=@entities.add_line([30,0,0],[40,0,0])
    assert_equal 1,square.first.find_faces
    assert_equal 0,square.first.find_faces
    assert_equal 5,square.first.all_connected.length
    refute_includes square.first.all_connected,unrelated
    assert_equal [unrelated],unrelated.all_connected
  end
end
