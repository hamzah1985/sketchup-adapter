require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  class << self
    attr_accessor :events
    def notify(op, data={}); (@events ||= []) << {'op'=>op}.merge(data); end
    def call(*); nil; end
  end
end
class SurfacePaintContracts < Minitest::Test
  def setup
    Sketchup.reset_model!
    Host.instance_variable_set(:@host_faces,{})
    Host.instance_variable_set(:@host_edges,[])
    Host.instance_variable_set(:@proxy_groups,[])
    Bridge.events=[]
    record={'kind'=>'face','token'=>'surface', 'outer'=>[[0,0,0],[4,0,0],[4,3,0],[0,3,0]],
      'attrs'=>{'mat'=>'original', 'color'=>[1,0,0], 'back'=>{'mat'=>'original back','color'=>[0,0,1]}, 'unknown'=>{'nested'=>[1]}}}
    Host.set_selection([record],nil)
    @face=Sketchup.active_model.selection.first
  end
  def paint_edits
    patch=Bridge.events.find { |e| e['op']=='surface_patch' }
    refute_nil patch
    patch['faces'].first[2].fetch('_adapter_paint_edits')
  end
  def test_import_does_not_send_changes
    Host.sync
    assert_empty Bridge.events.select { |e| e['op']=='surface_patch' }
  end
  def test_clearing_front_preserves_untouched_back
    @face.material=nil
    Host.sync
    edits=paint_edits
    assert_equal({'value'=>nil,'preserve_uvw'=>false}, edits['front'])
    refute edits.key?('back')
  end
  def test_assign_front_and_clear_back_independently
    @face.material='green'
    @face.back_material=nil
    Host.sync
    edits=paint_edits
    assert_equal [0,128.0/255,0],edits['front']['value']['color']
    assert_nil edits['back']['value']
  end
  def test_assigning_the_same_material_is_read_only
    @face.material=@face.material
    Host.sync
    assert_empty Bridge.events.select { |e| e['op']=='surface_patch' }
  end
  def test_reverting_to_original_paint_still_emits_a_change
    original=@face.material
    @face.material='green'
    Host.sync
    patch=Bridge.events.find { |e| e['op']=='surface_patch' }
    assert_equal true,patch['identity_preserved']
    Bridge.events.clear
    Host.sync
    assert_empty Bridge.events.select { |e| e['op']=='surface_patch' }
    @face.material=original
    Host.sync
    assert_equal 'original',paint_edits['front']['value']['mat']
  end
  def test_multiple_fragments_do_not_claim_a_surviving_identity
    extra=Sketchup.active_model.entities.add_face_raw([[10,0,0],[11,0,0],[11,1,0],[10,1,0]])
    extra.instance_variable_set(:@adapter_surface_token,'surface')
    Host.sync
    patch=Bridge.events.find { |e| e['op']=='surface_patch' }
    refute_nil patch
    assert_equal 2,patch['faces'].length
    assert_equal false,patch['identity_preserved']
  end
end
