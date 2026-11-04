require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  def self.notify(*);end
  def self.call(*);raise 'Unexpected host service';end
end
class ExplodeTopologyTest < Minitest::Test
  def setup
    Sketchup.reset_model!
    @entities=Sketchup.active_model.entities
  end
  def rectangle(x=0)
    [[x,0,0],[x+10,0,0],[x+10,10,0],[x,10,0]]
  end
  def test_intersection_in_an_empty_result_context_keeps_closed_wires_unfilled
    first=@entities.add_group;second=@entities.add_group;result=@entities.add_group
    first.entities.add_face(rectangle)
    second.entities.add_face(rectangle(5))
    edges=first.entities.intersect_with(false,IDENTITY,result.entities,IDENTITY,true,second)
    assert_equal 4,edges.length
    assert_empty result.entities.faces
    assert edges.all? { |e| e.faces.empty? }
    assert_in_delta 100,first.entities.faces.sum(&:area),1e-8
  end
  def test_exploding_identical_faces_reuses_a_subdivided_boundary
    face=@entities.add_face(rectangle)
    @entities.add_line([0,0,0],[5,0,0])
    assert_equal 5,face.outer_loop.vertices.length
    group=@entities.add_group;group.entities.add_face(rectangle.reverse)
    out=group.explode
    assert_equal [face],@entities.faces
    assert_includes out,face
    assert_in_delta 100,face.area,1e-8
    assert out.all?(&:valid?)
  end
  def test_exploding_a_transformed_holed_face_twice_keeps_one_hole_and_its_flags
    group=@entities.add_group
    face=group.entities.add_face(rectangle);face.reverse! if face.normal.z<0
    face.add_hole([[2,2,0],[4,2,0],[4,4,0],[2,4,0]].map { |p| group.entities.vertex(p) })
    face.material='red';front_material=face.material;face.set_attribute('QA','retained',42)
    face.layer='QA face';face.casts_shadows=false
    edge=face.outer_loop.edges.first;edge.soft=true;edge.smooth=true;edge.casts_shadows=false
    group.transformation=Geom::Transformation.new([5,2,3])
    copy=group.copy
    first=group.explode.grep(Sketchup::Face).first
    second=copy.explode.grep(Sketchup::Face).first
    assert_same first,second
    assert_equal 1,@entities.faces.length
    assert_equal 2,first.loops.length
    assert_in_delta 96,first.area,1e-8
    assert_operator first.normal.z,:>,0
    assert_equal 42,first.get_attribute('QA','retained')
    assert_same front_material,first.material
    assert_equal [255,0,0],first.material.color.to_a.first(3)
    assert_equal 'QA face',first.layer.name
    refute first.casts_shadows?
    flagged=first.outer_loop.edges.find(&:soft?)
    assert flagged.smooth?;refute flagged.casts_shadows?
  end
  def test_vertex_endpoints_are_copied_by_position_across_contexts
    source=@entities.add_group;source.entities.add_line([1,2,3],[4,5,6])
    edge=source.entities.edges.first
    copied=@entities.add_line(edge.start,edge.end)
    assert_equal edge.vertices.map { |v| v.position.to_a },copied.vertices.map { |v| v.position.to_a }
    refute_same edge.start,copied.start
    assert_equal 1,source.entities.edges.length
  end
  def test_exploding_a_reflected_box_preserves_outward_faces
    group=@entities.add_group
    rings=[[[0,0,0],[0,1,0],[1,1,0],[1,0,0]],[[0,0,1],[1,0,1],[1,1,1],[0,1,1]],
      [[0,0,0],[1,0,0],[1,0,1],[0,0,1]],[[1,1,0],[0,1,0],[0,1,1],[1,1,1]],
      [[0,1,0],[0,0,0],[0,0,1],[0,1,1]],[[1,0,0],[1,1,0],[1,1,1],[1,0,1]]]
    rings.each { |ring| group.entities.add_face_raw(ring.map { |point| Geom::Point3d.new(point) }) }
    group.transformation=Geom::Transformation.new([1,0,0])*Geom::Transformation.scaling(-1,1,1)
    faces=group.explode.grep(Sketchup::Face)
    assert_equal 6,faces.length
    centre=Geom::Point3d.new(0.5,0.5,0.5)
    faces.each do |face|
      outward=Geom.centroid(face.outer_loop.points)-centre
      assert_operator face.normal.dot(outward),:>,0
    end
    assert @entities.edges.all? { |edge| edge.faces.length==2 }
  end
  def test_reflected_holed_face_keeps_front_and_inner_boundary
    group=@entities.add_group
    face=group.entities.add_face(rectangle);face.reverse! if face.normal.z<0
    face.add_hole([[2,2,0],[4,2,0],[4,4,0],[2,4,0]].map { |point| group.entities.vertex(point) })
    face.material='red';face.back_material='blue'
    front_material=face.material;back_material=face.back_material
    face.set_attribute('QA','value',73)
    group.transformation=Geom::Transformation.new([20,0,0])*Geom::Transformation.scaling(-2,1,0.5)
    result=group.explode.grep(Sketchup::Face).first
    assert_operator result.normal.z,:>,0
    assert_operator Geom.newell(result.loops[1].points).dot(result.normal),:<,0
    assert_in_delta 192,result.area,1e-8
    assert_same front_material,result.material;assert_same back_material,result.back_material
    assert_equal [255,0,0],result.material.color.to_a.first(3)
    assert_equal [0,0,255],result.back_material.color.to_a.first(3)
    assert_equal 73,result.get_attribute('QA','value')
  end
end
