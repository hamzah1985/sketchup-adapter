require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  def self.notify(*);end
  def self.call(*);raise 'Unexpected host service';end
end
class GroupMovementTest < Minitest::Test
  def setup
    Sketchup.reset_model!
    @e=Sketchup.active_model.entities
  end
  def rectangle(a,b)
    [[a,0,0],[b,0,0],[b,1,0],[a,1,0]]
  end
  def test_grouping_connected_faces_moves_all_original_edges_and_preserves_data
    f=@e.add_face(rectangle(0,1));g=@e.add_face(rectangle(1,2))
    f.set_attribute('QA','value',7);f.layer='test layer';f.hidden=true
    edge=f.edges.find { |e| e.faces.size==1 };edge.soft=true;edge.smooth=true
    selected=(f.all_connected+g.all_connected).uniq
    grouped=@e.add_group(selected.reverse)
    assert_empty @e.faces;assert_empty @e.edges
    assert_equal 2,grouped.entities.faces.length
    assert_equal 7,grouped.entities.edges.length
    copied=grouped.entities.faces.find { |x| x.get_attribute('QA','value')==7 }
    assert_equal 'test layer',copied.layer.name;assert copied.hidden?
    assert grouped.entities.edges.any? { |x| x.soft? && x.smooth? }
  end
  def test_grouping_one_face_keeps_its_shared_edge_in_parent
    first=@e.add_face(rectangle(0,1));second=@e.add_face(rectangle(1,2))
    shared=(first.edges&second.edges).first
    shared.soft=true;shared.set_attribute('QA','shared',1)
    grouped=@e.add_group(first)
    assert_equal [second],@e.faces
    assert shared.valid?;assert_includes @e.edges,shared
    assert_equal 4,@e.edges.length;assert_equal 4,grouped.entities.edges.length
    assert grouped.entities.edges.any? { |e| e.soft? && e.get_attribute('QA','shared')==1 }
    assert_in_delta 1,second.area,1e-8
  end
  def test_grouping_a_standalone_edge_moves_it
    line=@e.add_line([0,0,0],[1,0,0]);line.soft=true;line.set_attribute('QA','edge',1)
    group=@e.add_group(line)
    assert_empty @e.edges;refute line.valid?
    copy=group.entities.edges.first;assert copy.soft?;assert_equal 1,copy.get_attribute('QA','edge')
  end
  def test_abort_restores_original_geometry_and_deletes_new_group
    face=@e.add_face(rectangle(0,1));before=face.edges
    Sketchup.active_model.start_operation('group')
    group=@e.add_group(face.all_connected)
    Sketchup.active_model.abort_operation
    refute group.valid?;assert face.valid?;assert_equal [face],@e.faces
    assert_equal before.sort_by(&:entityID),@e.edges.sort_by(&:entityID)
    assert_equal 4,face.edges.length
  end
  def test_cross_context_grouping_preserves_world_geometry_from_multiple_sources
    face=@e.add_face(rectangle(0,1));face.set_attribute('QA','root',9)
    source=@e.add_group;source.transformation=Geom::Transformation.translation([4,0,0])
    other=source.entities.add_face(rectangle(0,1));other.layer='source layer'
    target=@e.add_group
    target.transformation=Geom::Transformation.translation([10,5,0]) * Geom::Transformation.rotation(ORIGIN,Z_AXIS,Math::PI/2)
    group=target.entities.add_group(face.all_connected+other.all_connected)
    world=target.transformation*group.transformation
    loops=group.entities.faces.map { |f| f.outer_loop.points.map { |p| p.transform(world).to_a.map { |n| n.round(6) } }.sort }.sort
    assert_equal [rectangle(0,1),rectangle(4,5)].map { |ring| ring.map { |p| p.map(&:to_f) }.sort }.sort,loops
    assert_empty @e.faces;assert_empty @e.edges
    assert_empty source.entities.faces;assert_empty source.entities.edges
    assert_equal 2,group.entities.faces.length
    assert group.entities.faces.any? { |f| f.get_attribute('QA','root')==9 }
    assert group.entities.faces.any? { |f| f.layer.name=='source layer' }
  end
  def test_ambiguous_shared_context_is_rejected_before_moving_geometry
    owner=@e.add_group;face=owner.entities.add_face(rectangle(0,1));owner.copy
    before_groups=@e.grep(Sketchup::Group).length
    assert_raises(ArgumentError) { @e.add_group(face) }
    assert face.valid?;assert_equal 1,owner.entities.faces.length
    assert_equal before_groups,@e.grep(Sketchup::Group).length
  end
  def test_exploding_a_unique_group_moves_nested_instance_and_preserves_identity
    parent=@e.add_group;parent.transformation=Geom::Transformation.translation([10,3,0])
    child=parent.entities.add_group;child.transformation=Geom::Transformation.translation([2,0,0])
    child.entities.add_face(rectangle(0,1))
    result=parent.explode
    assert_includes result,child;assert child.valid?;assert_same @e,child.parent_entities
    assert_equal [12.0,3.0,0.0],child.transformation.origin.to_a
    assert_equal 1,child.entities.faces.length
  end
  def test_exploding_a_shared_definition_copies_nested_instances
    parent=@e.add_group;child=parent.entities.add_group;child.entities.add_face(rectangle(0,1))
    copy=parent.copy
    result=parent.explode.grep(Sketchup::Group).first
    refute_same child,result;assert child.valid?;assert_same copy.definition.entities,child.parent_entities
    assert_same @e,result.parent_entities
    assert_equal 1,copy.entities.grep(Sketchup::Group).length
  end
  def test_exploding_a_single_component_preserves_its_reusable_definition
    definition=Sketchup.active_model.definitions.add('Reusable')
    child=definition.entities.add_group;child.entities.add_face(rectangle(0,1))
    instance=@e.add_instance(definition,IDENTITY)
    result=instance.explode.grep(Sketchup::Group).first
    refute_same child,result;assert child.valid?
    assert_same definition.entities,child.parent_entities
    assert_equal 1,definition.entities.grep(Sketchup::Group).length
    assert_equal 1,result.entities.faces.length
    again=@e.add_instance(definition,IDENTITY)
    assert_equal 1,again.definition.entities.grep(Sketchup::Group).length
  end
end
