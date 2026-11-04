require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  def self.notify(*); end
  def self.call(*); raise 'Unexpected host service'; end
end
class FragmentPropertiesContracts < Minitest::Test
  def setup
    Sketchup.reset_model!
    @entities=Sketchup.active_model.entities
  end
  def decorate(face, native=false)
    face.layer='fragment-layer';face.hidden=true
    face.casts_shadows=false;face.receives_shadows=false
    face.set_attribute(native ? '_ingetrazo_bridge' : 'QA', 'nested', {'items'=>[1,{'s'=>'original'}]})
    face.instance_variable_set(:@adapter_surface_token,'native-token') if native
  end
  def assert_inherited(faces, native=false)
    assert_equal 2,faces.length
    key=native ? '_ingetrazo_bridge' : 'QA'
    faces.each do |face|
      assert_equal 'fragment-layer',face.layer.name
      assert face.hidden?
      refute face.casts_shadows?
      refute face.receives_shadows?
      assert_equal({'items'=>[1,{'s'=>'original'}]},face.get_attribute(key,'nested'))
      assert_equal 'native-token',face.instance_variable_get(:@adapter_surface_token) if native
    end
    faces[1].get_attribute(key,'nested')['items'][1]['s'].replace('changed')
    assert_equal 'original',faces[0].get_attribute(key,'nested')['items'][1]['s']
  end
  def test_wire_split_preserves_fragment_state_without_aliasing
    face=@entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    decorate(face)
    @entities.add_line([0,0,0],[10,10,0])
    assert_inherited(@entities.faces)
  end
  def test_holed_wire_split_preserves_fragment_state_without_aliasing
    face=@entities.add_face([[0,0,0],[20,0,0],[20,10,0],[0,10,0]])
    [[2,4],[10,12]].each { |a,b| @entities.add_face([[a,2,0],[b,2,0],[b,4,0],[a,4,0]]).erase! }
    decorate(face)
    @entities.add_line([0,0,0],[2,2,0]);@entities.add_line([0,10,0],[2,4,0])
    assert_inherited(@entities.faces)
  end
  def test_native_proxy_internal_bookkeeping_is_copied_and_user_writes_remain_guarded
    face=@entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    decorate(face,true)
    @entities.add_line([0,0,0],[10,10,0])
    assert_inherited(@entities.faces,true)
    assert_raises(RuntimeError) { @entities.faces.last.set_attribute('QA','new',1) }
  end
  def test_face_partition_path_preserves_nested_state_without_aliasing
    face=@entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    decorate(face)
    @entities.add_face([[0,0,0],[10,0,0],[0,10,0]])
    assert_inherited(@entities.faces)
  end
  def test_mutable_point_and_uv_mappings_are_independent
    face=@entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    face.set_attribute('QA','point',Geom::Point3d.new(1,2,3))
    face.uv_mapping=[Geom::Point3d.new(1,2,3),Geom::Point3d.new(4,5,6)]
    @entities.add_line([0,0,0],[10,10,0])
    first,second=@entities.faces
    second.get_attribute('QA','point')[0]=99
    second.uv_mapping[0][0]=88
    assert_equal 1.0,first.get_attribute('QA','point')[0]
    assert_equal 1.0,first.uv_mapping[0][0]
  end
end
