require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  class << self
    attr_accessor :events
    def notify(op,data={}); (@events||=[]) << {'op'=>op}.merge(data); end
    def call(*); nil; end
  end
end
class NativeSurfaceTest < Minitest::Test
  def setup
    Sketchup.reset_model!
    Host.instance_variable_set(:@host_faces,{})
    Host.instance_variable_set(:@host_edges,[])
    Host.instance_variable_set(:@proxy_groups,[])
    Bridge.events=[]
  end
  def wall
    rings=[[[0,0,0],[5,0,0],[5,0,3],[0,0,3]],
      [[0,0.2,0],[0,0.2,3],[5,0.2,3],[5,0.2,0]],
      [[0,0,0],[0,0,3],[0,0.2,3],[0,0.2,0]],
      [[5,0,0],[5,0.2,0],[5,0.2,3],[5,0,3]],
      [[0,0,3],[5,0,3],[5,0.2,3],[0,0.2,3]],
      [[0,0,0],[0,0.2,0],[5,0.2,0],[5,0,0]]]
    rings.each_with_index.map { |ring,i| {'kind'=>'face','token'=>"surface#{i}",'outer'=>ring,'_context_only'=>i!=0} }
  end
  def test_context_import_and_selection_clear_are_read_only
    Host.set_selection(wall,nil)
    assert_equal 6,Sketchup.active_model.entities.faces.length
    assert_equal 1,Sketchup.active_model.selection.length
    assert_empty Host.adapter_loose_items
    Host.sync
    assert_empty Bridge.events.select { |e| %w[surface_patch upsert face_erased].include?(e['op']) }
    Host.set_selection([],nil)
    Host.sync
    assert_empty Host.adapter_loose_items
    assert_empty Bridge.events.select { |e| %w[surface_patch upsert face_erased].include?(e['op']) }
  end
  def test_changed_hole_returns_to_native_surface_without_exporting_context
    Host.set_selection(wall,nil)
    model=Sketchup.active_model
    front=model.selection.first
    ring=[[1,0,0.5],[3,0,0.5],[3,0,2],[1,0,2]].map { |p| p.map { |v| v/Host::INCH } }
    cut=model.entities.add_face(ring)
    cut.erase!
    Host.sync
    patch=Bridge.events.find { |e| e['op']=='surface_patch' && e['token']=='surface0' }
    refute_nil patch
    assert_equal 1,patch['faces'].first[1].length
    assert_empty Host.adapter_loose_items
    assert_equal 2,front.loops.length
  end
  def test_native_face_dictionary_writes_fail_without_partial_operation
    Host.set_selection(wall,nil)
    model=Sketchup.active_model
    face=model.selection.first
    model.start_operation('attribute test', true)
    group=model.entities.add_group
    group.set_attribute('test','group',1)
    group_face=group.entities.add_face([[0,0,0],[1,0,0],[1,1,0]])
    group_face.set_attribute('test','face',2)
    assert_equal 1,group.get_attribute('test','group')
    assert_equal 2,group_face.get_attribute('test','face')
    error=assert_raises(RuntimeError) { face.set_attribute('plugin','mark',1) }
    assert_match(/cannot save plugin attributes on native faces/,error.message)
    assert_raises(RuntimeError) { face.delete_attribute('plugin','mark') }
    assert_raises(RuntimeError) { face.attribute_dictionary('plugin',true) }
    face.set_attribute('_ingetrazo_bridge','internal',1)
    assert_equal 1,face.get_attribute('_ingetrazo_bridge','internal')
    model.abort_operation
    assert_empty model.entities.grep(Sketchup::Group)
    assert_nil face.get_attribute('plugin','mark')
    Bridge.events.clear
    Host.sync
    assert_empty Bridge.events.select { |e| %w[surface_patch upsert face_erased].include?(e['op']) }
  end
  def test_selected_and_context_face_materials_are_read_only_and_share_identity
    records=wall
    paint={'mat'=>'Native Brick','color'=>[0.8,0.3,0.1],
           'back'=>{'mat'=>'Native Back','color'=>[0.1,0.2,0.3]}}
    records[0]['attrs']=paint
    records[1]['attrs']=paint
    Host.set_selection(records,nil)
    front=Sketchup.active_model.selection.first
    back=Sketchup.active_model.entities.faces.find { |f| f.instance_variable_get(:@adapter_surface_token)=='surface1' }
    assert_equal 'Native Brick',front.material.name
    assert_equal 'Native Back',front.back_material.name
    assert_same front.material,back.material
    assert_same front.back_material,back.back_material
    assert_equal [204,77,26],front.material.color.to_a.first(3)
    assert_equal [26,51,77],front.back_material.color.to_a.first(3)
    Host.sync
    assert_empty Bridge.events.select { |e| %w[surface_patch upsert face_erased].include?(e['op']) }
    Host.set_selection([],nil)
    Host.sync
    assert_empty Bridge.events.select { |e| %w[surface_patch upsert face_erased].include?(e['op']) }
  end
  def test_native_materials_do_not_mutate_or_alias_different_named_finishes
    model=Sketchup.active_model
    user=model.materials.add('Shared Name'); user.color=[1,2,3]
    records=wall
    records[0]['attrs']={'mat'=>'Shared Name','color'=>[1,0,0]}
    records[1]['attrs']={'mat'=>'Shared Name','color'=>[0,0,1]}
    records[2]['attrs']={'back'=>{'mat'=>'Back Only','color'=>[0,1,0]}}
    Host.set_selection(records,nil)
    by_token=model.entities.faces.to_h { |f| [f.instance_variable_get(:@adapter_surface_token), f] }
    assert_equal [1,2,3],user.color.to_a.first(3)
    assert_equal 1,model.materials.length
    refute_same by_token['surface0'].material,by_token['surface1'].material
    assert_equal [255,0,0],by_token['surface0'].material.color.to_a.first(3)
    assert_equal [0,0,255],by_token['surface1'].material.color.to_a.first(3)
    assert_nil by_token['surface2'].material
    assert_equal [0,255,0],by_token['surface2'].back_material.color.to_a.first(3)
    Host.sync
    assert_empty Bridge.events.select { |e| %w[surface_patch upsert face_erased].include?(e['op']) }
  end
  def test_original_native_attrs_survive_a_geometry_only_change
    records=wall
    attrs={'mat'=>'Brick','color'=>[0.8,0.3,0.1], 'custom'=>'keep me',
      'texture'=>{'path'=>'not-existing.png','sw'=>1,'sh'=>1,'uvw'=>[1,0,0,0.5,0,1,0,0.25]},
      'back'=>{'mat'=>'Back','color'=>[0.1,0.2,0.3]}}
    records[0]['attrs']=attrs
    Host.set_selection(records,nil)
    model=Sketchup.active_model
    ring=[[1,0,0.5],[3,0,0.5],[3,0,2],[1,0,2]].map { |p| p.map { |v| v/Host::INCH } }
    model.entities.add_face(ring).erase!
    Host.sync
    patch=Bridge.events.find { |e| e['op']=='surface_patch' && e['token']=='surface0' }
    refute_nil patch
    assert_equal attrs,patch['faces'].first[2].reject { |k,_| k=='_sketchup_edge_properties' }
  end
  def test_cursor_context_restores_original_materials_after_abort
    data=wall.first.merge('attrs'=>{'mat'=>'Cursor Paint','color'=>[0.5,0.25,0.0], 'tag'=>'original'})
    Host.set_selection([],nil)
    model=Sketchup.active_model
    model.start_operation('cursor test',true)
    Host.import_cursor_context([data])
    assert_equal 'Cursor Paint',model.entities.faces.first.material.name
    model.abort_operation
    Host.restore_cursor_context
    restored=model.entities.faces.find { |f| f.instance_variable_get(:@adapter_surface_token)=='surface0' }
    refute_nil restored
    assert_equal 'Cursor Paint',restored.material.name
    assert_equal 'original',restored.get_attribute('_ingetrazo_bridge','face_attrs')['tag']
    Bridge.events.clear
    Host.sync
    assert_empty Bridge.events.select { |e| %w[surface_patch upsert face_erased].include?(e['op']) }
  end
end
