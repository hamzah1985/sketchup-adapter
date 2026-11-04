require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'

class PickHelperContracts < Minitest::Test
  FakeView = Struct.new(:native_hits)

  def setup
    Sketchup.reset_model!
    model=Sketchup.active_model
    @owner=model.entities.add_group
    @face=@owner.entities.add_face([[0,0,0],[4,0,0],[4,4,0],[0,4,0]])
    @edge=@face.edges.first
    @transform=Geom::Transformation.new
  end

  def helper(records)
    view=FakeView.new(records)
    pick=Sketchup::PickHelper.new(nil,nil,nil,view)
    pick.do_pick(10,10)
    [pick,view]
  end

  def record(entity,path)
    {entity:entity,path:path,transform:@transform,distance:0,depth:3.8}
  end

  def test_face_and_edge_paths_preserve_duplicate_active_group
    pick,view=helper([record(@edge,[@owner,@edge]),record(@face,[@owner,@face])])
    assert_equal 2,pick.count
    assert_same @owner,pick.element_at(0)
    assert_same @owner,pick.element_at(1)
    assert_equal [@owner,@owner],pick.all_picked
    assert_same @edge,pick.leaf_at(0)
    assert_same @face,pick.leaf_at(1)
    assert_same view,pick.view
    assert_nil pick.picked_element
    assert_equal 2,pick.depth_at(0)
  end

  def test_loose_edges_and_faces_are_not_picked_elements
    pick,_view=helper([record(@edge,[@edge]),record(@face,[@face])])
    assert_same @edge,pick.picked_edge
    assert_same @face,pick.picked_face
    assert_nil pick.picked_element
    assert_same @edge,pick.element_at(0)
    assert_same @face,pick.element_at(1)
    assert_equal 1,pick.depth_at(0)
  end

  def test_empty_pick_is_empty_and_view_remains_accessible
    pick,view=helper([])
    assert_equal 0,pick.count
    assert_equal [],pick.all_picked
    assert_nil pick.element_at(0)
    assert_nil pick.picked_element
    assert_nil pick.depth_at(0)
    assert_same view,pick.view
  end

  def test_non_face_or_edge_leaf_is_picked_element
    point=@owner.entities.add_cpoint([1,1,0])
    pick,_view=helper([record(@edge,[@owner,@edge]),record(point,[@owner,point])])
    assert_same point,pick.picked_element
    assert_equal 2,pick.depth_at(1)
  end
end
