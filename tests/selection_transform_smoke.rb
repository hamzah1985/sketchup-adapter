require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  def self.notify(*);end
end
class SelectionTransformTest < Minitest::Test
  def setup;Sketchup.reset_model!;end
  def test_selection_collection_transforms_shared_vertices_once
    model=Sketchup.active_model
    edges=model.entities.add_edges([[0,0,0],[10,0,0],[10,10,0]])
    model.selection.add(edges)
    model.entities.transform_entities(Geom::Transformation.translation([0,0,5]),model.selection)
    assert_equal [5.0],edges.flat_map(&:vertices).map { |v| v.position.z }.uniq
  end
  def test_copied_native_proxy_groups_keep_group_type_and_enter_the_logical_parent
    model=Sketchup.active_model
    proxy=Sketchup::Entities.new(model)
    group=proxy.add_group
    group.entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    group.instance_variable_set(:@bridge_copy_parent,model.entities)
    group.set_attribute('qa','value',12)
    copied=group.copy
    assert_instance_of Sketchup::Group,copied
    assert_includes model.entities.to_a,copied
    assert_equal 1,copied.entities.faces.length
    assert_equal 12,copied.get_attribute('qa','value')
    assert_equal false,model.entities.to_a.include?(group)
  end
end
