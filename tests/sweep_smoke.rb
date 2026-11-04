require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  def self.notify(*); end
  def self.call(*); nil; end
end
class SweepTest < Minitest::Test
  def setup; Sketchup.reset_model!;@entities=Sketchup.active_model.entities;end
  def prism(x)
    group=@entities.add_group
    face=group.entities.add_face([[x,-1,0],[x,1,0],[x,1,-2],[x,-1,-2]])
    path=group.entities.add_line([x,0,0],[x+10,0,0])
    assert face.followme(path)
    [group,path]
  end
  def test_path_on_surface_is_shared_by_two_faces
    group,path=prism(0)
    assert_equal 2,path.faces.length
    assert group.manifold?
    assert_in_delta 40,group.volume,1e-6
  end
  def test_volume_and_end_caps_do_not_depend_on_world_origin
    group,path=prism(5)
    assert group.manifold?
    assert_in_delta 40,group.volume,1e-6
    group.entities.faces.each do |face|
      if face.outer_loop.points.all? { |p| (p.x-5).abs<1e-7 }
        assert face.normal.x<0
      elsif face.outer_loop.points.all? { |p| (p.x-15).abs<1e-7 }
        assert face.normal.x>0
      end
    end
  end
  def test_closed_path_produces_a_manifold_ring
    group=@entities.add_group
    face=group.entities.add_face([[0,0,0],[0,1,0],[0,1,-1],[0,0,-1]])
    path=group.entities.add_edges([[0,0,0],[10,0,0],[10,10,0],[0,10,0],[0,0,0]])
    assert face.followme(path)
    assert group.manifold?
    assert_in_delta 36,group.volume,1e-6
  end
  def test_interior_guide_is_removed_but_external_context_path_is_preserved
    group=@entities.add_group
    face=group.entities.add_face([[0,-1,-1],[0,1,-1],[0,1,1],[0,-1,1]])
    path=group.entities.add_line([0,0,0],[10,0,0])
    face.followme(path)
    refute path.valid?
    assert group.manifold?
    assert_in_delta 40,group.volume,1e-6
    other=@entities.add_group
    face=other.entities.add_face([[0,-1,-1],[0,1,-1],[0,1,1],[0,-1,1]])
    external=@entities.add_line([0,0,0],[10,0,0])
    face.followme(external)
    assert external.valid?
    assert other.manifold?
    assert_in_delta 40,other.volume,1e-6
  end
end
